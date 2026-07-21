import Capacitor
import CoreBluetooth
import Foundation

@objc(SkyBluetoothPlugin)
public final class SkyBluetoothPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "SkyBluetoothPlugin"
    public let jsName = "SkyBluetooth"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "getStatus", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "connect", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "disconnect", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "read", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "write", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startNotifications", returnType: CAPPluginReturnPromise)
    ]

    private enum CharacteristicName: String {
        case pair
        case command
        case notify
    }

    private let serviceUUID = CBUUID(string: "00010203-0405-0607-0809-0A0B0C0D1910")
    private let notifyUUID = CBUUID(string: "00010203-0405-0607-0809-0A0B0C0D1911")
    private let commandUUID = CBUUID(string: "00010203-0405-0607-0809-0A0B0C0D1912")
    private let pairUUID = CBUUID(string: "00010203-0405-0607-0809-0A0B0C0D1914")
    private let rememberedPeripheralKey = "skyRemotePeripheralIdentifier"

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var pairCharacteristic: CBCharacteristic?
    private var commandCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var pendingConnect: CAPPluginCall?
    private var pendingNotificationStart: CAPPluginCall?
    private var pendingReads: [CBUUID: [CAPPluginCall]] = [:]
    private var pendingWrites: [CBUUID: [CAPPluginCall]] = [:]
    private var connectTimeout: DispatchWorkItem?
    private var connectionReady = false
    private var intentionalDisconnect = false

    @objc public func getStatus(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            call.resolve([
                "platform": "ios",
                "authorization": self.authorizationLabel(),
                "bluetoothState": self.stateLabel(self.central?.state ?? .unknown),
                "nativeBluetooth": true,
                "connected": self.connectionReady && self.peripheral?.state == .connected,
                "remembered": UserDefaults.standard.string(forKey: self.rememberedPeripheralKey) != nil
            ])
        }
    }

    @objc public func connect(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard self.pendingConnect == nil else {
                call.reject("A Bluetooth connection attempt is already running.")
                return
            }
            if self.connectionReady, let peripheral = self.peripheral, peripheral.state == .connected {
                call.resolve(self.connectionResult(peripheral, source: "existing"))
                return
            }

            self.intentionalDisconnect = false
            self.connectionReady = false
            self.pendingConnect = call
            self.armConnectTimeout()

            if self.central == nil {
                self.central = CBCentralManager(delegate: self, queue: .main)
            } else {
                self.beginConnectionIfPossible()
            }
        }
    }

    @objc public func disconnect(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.intentionalDisconnect = true
            self.cancelConnectTimeout()
            if let pending = self.pendingConnect {
                self.pendingConnect = nil
                pending.reject("Connection cancelled.")
            }
            self.rejectPendingOperations("Bluetooth disconnected.")
            if let peripheral = self.peripheral, peripheral.state != .disconnected {
                self.central?.cancelPeripheralConnection(peripheral)
            }
            self.clearConnection()
            call.resolve()
        }
    }

    @objc public func read(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard let characteristic = self.characteristic(named: call.getString("characteristic")) else {
                call.reject("Unknown or unavailable Bluetooth characteristic.")
                return
            }
            guard self.peripheral?.state == .connected else {
                call.reject("Bluetooth is disconnected.")
                return
            }
            self.pendingReads[characteristic.uuid, default: []].append(call)
            self.peripheral?.readValue(for: characteristic)
        }
    }

    @objc public func write(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard let characteristic = self.characteristic(named: call.getString("characteristic")) else {
                call.reject("Unknown or unavailable Bluetooth characteristic.")
                return
            }
            guard let hex = call.getString("hex"), let data = Data(hexString: hex) else {
                call.reject("The Bluetooth write payload is not valid hexadecimal.")
                return
            }
            guard let peripheral = self.peripheral, peripheral.state == .connected else {
                call.reject("Bluetooth is disconnected.")
                return
            }

            let withoutResponse = call.getBool("withoutResponse") ?? false
            let writeType: CBCharacteristicWriteType = withoutResponse ? .withoutResponse : .withResponse
            guard characteristic.properties.supports(writeType) else {
                call.reject(withoutResponse
                    ? "This characteristic does not support write without response."
                    : "This characteristic does not support write with response.")
                return
            }

            if writeType == .withResponse {
                self.pendingWrites[characteristic.uuid, default: []].append(call)
            }
            peripheral.writeValue(data, for: characteristic, type: writeType)
            if writeType == .withoutResponse {
                call.resolve(["bytes": data.count])
            }
        }
    }

    @objc public func startNotifications(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard self.pendingNotificationStart == nil else {
                call.reject("Notification setup is already running.")
                return
            }
            guard let peripheral = self.peripheral,
                  peripheral.state == .connected,
                  let characteristic = self.notifyCharacteristic else {
                call.reject("The notification characteristic is unavailable.")
                return
            }
            if characteristic.isNotifying {
                call.resolve()
                return
            }
            self.pendingNotificationStart = call
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    private func authorizationLabel() -> String {
        switch CBManager.authorization {
        case .allowedAlways: return "allowed"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    private func stateLabel(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn: return "poweredOn"
        case .poweredOff: return "poweredOff"
        case .resetting: return "resetting"
        case .unauthorized: return "unauthorized"
        case .unsupported: return "unsupported"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }

    private func beginConnectionIfPossible() {
        guard pendingConnect != nil, let central else { return }
        switch central.state {
        case .poweredOn:
            if let saved = UserDefaults.standard.string(forKey: rememberedPeripheralKey),
               let identifier = UUID(uuidString: saved),
               let remembered = central.retrievePeripherals(withIdentifiers: [identifier]).first {
                connect(to: remembered, source: "remembered")
            } else {
                central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
                notifyListeners("nativeLog", data: ["event": "SCAN_STARTED"])
            }
        case .poweredOff:
            failConnection("Bluetooth is turned off.")
        case .unauthorized:
            failConnection("Bluetooth permission was denied.")
        case .unsupported:
            failConnection("Bluetooth Low Energy is not supported on this device.")
        case .resetting, .unknown:
            break
        @unknown default:
            failConnection("Bluetooth is unavailable.")
        }
    }

    private func connect(to peripheral: CBPeripheral, source: String) {
        guard pendingConnect != nil, let central else { return }
        // stopScan() can still leave a queued discovery callback. Never let a
        // second advertisement replace the peripheral already connecting.
        if let activePeripheral = self.peripheral,
           activePeripheral.identifier != peripheral.identifier,
           activePeripheral.state != .disconnected {
            return
        }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        connectionReady = false
        notifyListeners("nativeLog", data: [
            "event": "PERIPHERAL_CONNECT_START",
            "source": source,
            "name": peripheral.name ?? "BlissLights"
        ])
        central.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ])
    }

    private func armConnectTimeout() {
        connectTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.failConnection("Bluetooth connection timed out.")
        }
        connectTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 18, execute: work)
    }

    private func cancelConnectTimeout() {
        connectTimeout?.cancel()
        connectTimeout = nil
    }

    private func finishConnection() {
        guard let call = pendingConnect, let peripheral else { return }
        guard pairCharacteristic != nil, commandCharacteristic != nil, notifyCharacteristic != nil else {
            failConnection("The projector did not expose all required Telink characteristics.")
            return
        }
        cancelConnectTimeout()
        pendingConnect = nil
        connectionReady = true
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: rememberedPeripheralKey)
        notifyListeners("nativeLog", data: ["event": "GATT_READY", "name": peripheral.name ?? "BlissLights"])
        call.resolve(connectionResult(peripheral, source: "connected"))
    }

    private func connectionResult(_ peripheral: CBPeripheral, source: String) -> JSObject {
        [
            "name": peripheral.name ?? "BlissLights",
            "identifier": peripheral.identifier.uuidString,
            "source": source
        ]
    }

    private func failConnection(_ message: String, error: Error? = nil) {
        central?.stopScan()
        cancelConnectTimeout()
        if let peripheral, peripheral.state != .disconnected {
            central?.cancelPeripheralConnection(peripheral)
        }
        let call = pendingConnect
        pendingConnect = nil
        clearConnection()
        if let error {
            call?.reject(message, nil, error)
        } else {
            call?.reject(message)
        }
        notifyListeners("nativeLog", data: ["event": "CONNECT_FAILED", "message": message])
    }

    private func clearConnection() {
        connectionReady = false
        peripheral?.delegate = nil
        peripheral = nil
        pairCharacteristic = nil
        commandCharacteristic = nil
        notifyCharacteristic = nil
        pendingNotificationStart = nil
    }

    private func rejectPendingOperations(_ message: String) {
        pendingNotificationStart?.reject(message)
        pendingNotificationStart = nil
        pendingReads.values.flatMap { $0 }.forEach { $0.reject(message) }
        pendingWrites.values.flatMap { $0 }.forEach { $0.reject(message) }
        pendingReads.removeAll()
        pendingWrites.removeAll()
    }

    private func characteristic(named rawName: String?) -> CBCharacteristic? {
        guard let rawName, let name = CharacteristicName(rawValue: rawName) else { return nil }
        switch name {
        case .pair: return pairCharacteristic
        case .command: return commandCharacteristic
        case .notify: return notifyCharacteristic
        }
    }
}

extension SkyBluetoothPlugin: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        notifyListeners("stateChanged", data: [
            "bluetoothState": stateLabel(central.state),
            "authorization": authorizationLabel()
        ])
        beginConnectionIfPossible()
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advertisedName ?? ""
        guard name.localizedCaseInsensitiveContains("BlissLights") else { return }
        connect(to: peripheral, source: "scan")
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        notifyListeners("nativeLog", data: ["event": "GATT_CONNECTED", "name": peripheral.name ?? "BlissLights"])
        peripheral.discoverServices([serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        failConnection("Could not connect to the projector.", error: error)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let wasIntentional = intentionalDisconnect
        rejectPendingOperations("Bluetooth disconnected.")
        clearConnection()
        notifyListeners("disconnected", data: [
            "intentional": wasIntentional,
            "message": error?.localizedDescription ?? (wasIntentional ? "Disconnected" : "Connection lost")
        ])
        intentionalDisconnect = false
    }
}

extension SkyBluetoothPlugin: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            failConnection("Could not discover projector services.", error: error)
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            failConnection("The Telink projector service was not found.")
            return
        }
        peripheral.discoverCharacteristics([pairUUID, commandUUID, notifyUUID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            failConnection("Could not discover projector characteristics.", error: error)
            return
        }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case pairUUID: pairCharacteristic = characteristic
            case commandUUID: commandCharacteristic = characteristic
            case notifyUUID: notifyCharacteristic = characteristic
            default: break
            }
        }
        finishConnection()
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if var queue = pendingReads[characteristic.uuid], !queue.isEmpty {
            let call = queue.removeFirst()
            pendingReads[characteristic.uuid] = queue.isEmpty ? nil : queue
            if let error {
                call.reject("Bluetooth read failed.", nil, error)
            } else {
                call.resolve(["hex": characteristic.value?.hexString ?? ""])
            }
            return
        }

        guard characteristic.uuid == notifyUUID else { return }
        if let error {
            notifyListeners("nativeLog", data: ["event": "NOTIFICATION_ERROR", "message": error.localizedDescription])
            return
        }
        notifyListeners("notification", data: ["hex": characteristic.value?.hexString ?? ""])
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard var queue = pendingWrites[characteristic.uuid], !queue.isEmpty else { return }
        let call = queue.removeFirst()
        pendingWrites[characteristic.uuid] = queue.isEmpty ? nil : queue
        if let error {
            call.reject("Bluetooth write failed.", nil, error)
        } else {
            call.resolve()
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == notifyUUID, let call = pendingNotificationStart else { return }
        pendingNotificationStart = nil
        if let error {
            call.reject("Could not start projector notifications.", nil, error)
        } else if characteristic.isNotifying {
            call.resolve()
        } else {
            call.reject("The projector did not enable notifications.")
        }
    }
}

private extension CBCharacteristicProperties {
    func supports(_ writeType: CBCharacteristicWriteType) -> Bool {
        switch writeType {
        case .withResponse: return contains(.write)
        case .withoutResponse: return contains(.writeWithoutResponse)
        @unknown default: return false
        }
    }
}

private extension Data {
    init?(hexString: String) {
        let clean = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

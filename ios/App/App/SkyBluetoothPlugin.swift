import Capacitor
import CommonCrypto
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
        CAPPluginMethod(name: "startNotifications", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startAnimation", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopAnimation", returnType: CAPPluginReturnPromise)
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
    private var animationTimer: DispatchSourceTimer?
    private var animationPresetID: Int?
    private var animationFrameIndex = 0
    private var animationSequence = 1
    private var animationSessionKey = Data()
    private var animationMacReversed = Data()
    private var animationDestination = 0xFFFF
    private var animationCycleCount = 0

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
            self.stopAnimationEngine(reason: "disconnect")
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

    @objc public func startAnimation(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard self.connectionReady,
                  self.peripheral?.state == .connected,
                  self.commandCharacteristic != nil else {
                call.reject("Bluetooth is disconnected.")
                return
            }
            guard let presetID = call.getInt("presetId"),
                  [100, 101, 102].contains(presetID),
                  let sessionKeyHex = call.getString("sessionKey"),
                  let sessionKey = Data(hexString: sessionKeyHex), sessionKey.count == 16,
                  let macHex = call.getString("macReversed"),
                  let macReversed = Data(hexString: macHex), macReversed.count >= 4,
                  let destination = call.getInt("destination"),
                  let sequence = call.getInt("sequence") else {
                call.reject("The native animation configuration is invalid.")
                return
            }

            self.stopAnimationEngine(reason: "replace")
            self.animationPresetID = presetID
            self.animationFrameIndex = max(0, call.getInt("frameIndex") ?? 0)
            self.animationSequence = max(1, min(0xFFFFFF, sequence))
            self.animationSessionKey = sessionKey
            self.animationMacReversed = macReversed
            self.animationDestination = destination & 0xFFFF
            self.animationCycleCount = 0

            let interval = self.animationDelay(for: presetID)
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(8))
            timer.setEventHandler { [weak self] in self?.sendNextAnimationFrame() }
            self.animationTimer = timer
            timer.resume()
            self.notifyListeners("nativeLog", data: [
                "event": "BACKGROUND_ANIMATION_STARTED",
                "presetId": presetID,
                "delayMs": Int(interval * 1000),
                "frameIndex": self.animationFrameIndex
            ])
            call.resolve(["native": true])
        }
    }

    @objc public func stopAnimation(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let wasRunning = self.animationTimer != nil
            self.stopAnimationEngine(reason: call.getString("reason") ?? "JavaScript request")
            call.resolve(["wasRunning": wasRunning])
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
        stopAnimationEngine(reason: "connection cleared")
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

    private func stopAnimationEngine(reason: String) {
        guard animationTimer != nil || animationPresetID != nil else { return }
        animationTimer?.setEventHandler {}
        animationTimer?.cancel()
        animationTimer = nil
        let stoppedPreset = animationPresetID
        animationPresetID = nil
        animationSessionKey = Data()
        animationMacReversed = Data()
        notifyListeners("nativeLog", data: [
            "event": "BACKGROUND_ANIMATION_STOPPED",
            "presetId": stoppedPreset ?? -1,
            "reason": reason
        ])
    }

    private func sendNextAnimationFrame() {
        guard let presetID = animationPresetID,
              connectionReady,
              let peripheral,
              peripheral.state == .connected,
              let commandCharacteristic,
              commandCharacteristic.properties.contains(.writeWithoutResponse) else {
            stopAnimationEngine(reason: "Bluetooth transport unavailable")
            notifyListeners("nativeLog", data: ["event": "BACKGROUND_ANIMATION_FAILED", "message": "Bluetooth transport unavailable"])
            return
        }
        let frame = animationFrame(for: presetID, index: animationFrameIndex)
        let control = Data([0x47, frame.0, frame.1, frame.2, frame.3, 0xFF, 0x03, 0x00])
        guard let packet = buildTelinkPacket(command: 0xF0, data: control) else {
            stopAnimationEngine(reason: "packet encryption failed")
            notifyListeners("nativeLog", data: ["event": "BACKGROUND_ANIMATION_FAILED", "message": "Packet encryption failed"])
            return
        }
        peripheral.writeValue(packet, for: commandCharacteristic, type: .withoutResponse)
        animationFrameIndex = (animationFrameIndex + 1) % animationFrameCount(for: presetID)
        if animationFrameIndex == 0 {
            animationCycleCount += 1
            if animationCycleCount == 1 || animationCycleCount.isMultiple(of: 5) {
                notifyListeners("nativeLog", data: [
                    "event": "BACKGROUND_ANIMATION_HEARTBEAT",
                    "presetId": presetID,
                    "completedCycles": animationCycleCount
                ])
            }
        }
    }

    private func animationDelay(for presetID: Int) -> TimeInterval {
        switch presetID {
        case 101: return 0.100
        case 102: return 0.220
        default: return 0.085
        }
    }

    private func animationFrameCount(for presetID: Int) -> Int {
        switch presetID {
        case 101: return 432
        case 102: return 48
        default: return 96
        }
    }

    private func animationFrame(for presetID: Int, index: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        if presetID == 100 {
            let wave = smoothPulse(index: index, steps: 96)
            let laser = UInt8(clamping: Int((32.0 + (255.0 - 32.0) * wave).rounded()))
            return (255, 0, 255, laser)
        }
        if presetID == 102 {
            let wave = smoothPulse(index: index, steps: 48)
            let blue = UInt8(clamping: Int((64.0 + (255.0 - 64.0) * wave).rounded()))
            let laser = UInt8(clamping: Int((16.0 + (255.0 - 16.0) * (1.0 - wave)).rounded()))
            return (0, 0, blue, laser)
        }

        let colors: [(Double, Double, Double)] = [(255, 0, 0), (0, 0, 255), (0, 255, 0)]
        let transitionSteps = 144
        let phase = (index / transitionSteps) % colors.count
        let step = index % transitionSteps
        let from = colors[phase]
        let to = colors[(phase + 1) % colors.count]
        let t = Double(step) / Double(transitionSteps)
        let eased = (1.0 - cos(.pi * t)) / 2.0
        let fadeOut = cos(eased * .pi / 2.0)
        let fadeIn = sin(eased * .pi / 2.0)
        let pulseWave = cos(.pi * t)
        let intensity = 0.55 + (1.0 - 0.55) * pulseWave * pulseWave
        return (
            UInt8(clamping: Int(((from.0 * fadeOut + to.0 * fadeIn) * intensity).rounded())),
            UInt8(clamping: Int(((from.1 * fadeOut + to.1 * fadeIn) * intensity).rounded())),
            UInt8(clamping: Int(((from.2 * fadeOut + to.2 * fadeIn) * intensity).rounded())),
            0
        )
    }

    private func smoothPulse(index: Int, steps: Int) -> Double {
        let phase = Double(index % steps) / Double(steps)
        return (1.0 + cos(2.0 * .pi * phase)) / 2.0
    }

    private func buildTelinkPacket(command: UInt8, data: Data) -> Data? {
        guard animationSessionKey.count == 16, animationMacReversed.count >= 4 else { return nil }
        var packet = [UInt8](repeating: 0, count: 20)
        packet[0] = UInt8(animationSequence & 0xFF)
        packet[1] = UInt8((animationSequence >> 8) & 0xFF)
        packet[2] = UInt8((animationSequence >> 16) & 0xFF)
        animationSequence = animationSequence >= 0xFFFFFF ? 1 : animationSequence + 1
        packet[5] = UInt8(animationDestination & 0xFF)
        packet[6] = UInt8((animationDestination >> 8) & 0xFF)
        packet[7] = command
        packet[8] = 0x11
        packet[9] = 0x02
        for (offset, byte) in data.prefix(10).enumerated() { packet[10 + offset] = byte }

        let mac = [UInt8](animationMacReversed)
        var authNonce = [UInt8](repeating: 0, count: 16)
        authNonce.replaceSubrange(0..<4, with: mac.prefix(4))
        authNonce[4] = 1
        authNonce[5] = packet[0]
        authNonce[6] = packet[1]
        authNonce[7] = packet[2]
        authNonce[8] = 0x0F
        guard var auth = aesAtt(key: animationSessionKey, input: Data(authNonce)) else { return nil }
        for index in 0..<15 { auth[index] ^= packet[index + 5] }
        guard let authentication = aesAtt(key: animationSessionKey, input: auth) else { return nil }
        packet[3] = authentication[0]
        packet[4] = authentication[1]

        var initializationVector = [UInt8](repeating: 0, count: 16)
        initializationVector.replaceSubrange(1..<5, with: mac.prefix(4))
        initializationVector[5] = 1
        initializationVector[6] = packet[0]
        initializationVector[7] = packet[1]
        initializationVector[8] = packet[2]
        guard let stream = aesAtt(key: animationSessionKey, input: Data(initializationVector)) else { return nil }
        for index in 0..<15 { packet[index + 5] ^= stream[index] }
        return Data(packet)
    }

    private func aesAtt(key: Data, input: Data) -> Data? {
        guard key.count == kCCKeySizeAES128, input.count == kCCBlockSizeAES128 else { return nil }
        let reversedKey = Data(key.reversed())
        let reversedInput = Data(input.reversed())
        guard let encrypted = aesECBEncrypt(key: reversedKey, input: reversedInput) else { return nil }
        return Data(encrypted.reversed())
    }

    private func aesECBEncrypt(key: Data, input: Data) -> Data? {
        var output = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        var outputLength = 0
        let status = key.withUnsafeBytes { keyBytes in
            input.withUnsafeBytes { inputBytes in
                CCCrypt(
                    CCOperation(kCCEncrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionECBMode),
                    keyBytes.baseAddress,
                    kCCKeySizeAES128,
                    nil,
                    inputBytes.baseAddress,
                    kCCBlockSizeAES128,
                    &output,
                    output.count,
                    &outputLength
                )
            }
        }
        guard status == kCCSuccess, outputLength == kCCBlockSizeAES128 else { return nil }
        return Data(output)
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

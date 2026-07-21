import Capacitor

final class SkyBridgeViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(SkyBluetoothPlugin())
        bridge?.registerPluginInstance(SkySharePlugin())
    }
}

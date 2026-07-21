import Capacitor
import UIKit

@objc(SkySharePlugin)
public final class SkySharePlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "SkySharePlugin"
    public let jsName = "SkyShare"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "shareReport", returnType: CAPPluginReturnPromise)
    ]

    @objc public func shareReport(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard let text = call.getString("text"), !text.isEmpty else {
                call.reject("The diagnostic report is empty.")
                return
            }
            guard let presenter = self.bridge?.viewController else {
                call.reject("The native share sheet is unavailable.")
                return
            }

            let requestedName = call.getString("filename") ?? "Sky-Remote-Diagnostic.txt"
            let safeName = requestedName
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
            do {
                try text.write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                call.reject("Could not prepare the diagnostic report for sharing.", nil, error)
                return
            }

            let controller = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            controller.popoverPresentationController?.sourceView = presenter.view
            controller.popoverPresentationController?.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.maxY - 1,
                width: 1,
                height: 1
            )
            controller.completionWithItemsHandler = { activityType, completed, _, error in
                try? FileManager.default.removeItem(at: fileURL)
                if let error {
                    call.reject("Sharing the diagnostic report failed.", nil, error)
                } else {
                    call.resolve([
                        "completed": completed,
                        "activity": activityType?.rawValue ?? ""
                    ])
                }
            }
            presenter.present(controller, animated: true)
        }
    }
}

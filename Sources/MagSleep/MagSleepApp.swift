import AppKit
import MagSleepCore

@main
enum MagSleepMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var helper: HelperManager!
    private var statusItemController: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if !arch(arm64)
        showUnsupportedAlert(message: "MagSleep only runs on Apple Silicon MacBooks.")
        NSApp.terminate(nil)
        return
        #endif

        if !MagSafeLED.isSupported() {
            showUnsupportedAlert(
                message: "This Mac does not expose MagSafe LED control (ACLC). MagSleep requires an Apple Silicon MacBook with MagSafe 3."
            )
        }

        helper = HelperManager()
        statusItemController = StatusItemController(helper: helper)
    }

    private func showUnsupportedAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "MagSleep"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

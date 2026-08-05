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
    private lazy var helper = HelperManager()
    private lazy var statusItemController = StatusItemController(helper: helper)

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
            NSApp.terminate(nil)
            return
        }

        // Force initialization of helper and statusItem
        _ = statusItemController
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Quitting the app must not touch the helper's state — the daemon keeps
        // running in the active mode (README: "the helper keeps running if
        // enabled"). The LED is restored to macOS control by the daemon's own
        // shutdown path (SIGTERM → .system). Only explicit Uninstall/Disable
        // actions change the helper state.
        return .terminateNow
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
import AppKit
import Darwin
import MagSleepCore

@main
enum MagSleepMain {
    static func main() {
        // The helper's socket can be closed by the daemon at any moment
        // (restart, rebind, /var/run cleanup); without this a write would
        // raise SIGPIPE and kill the app instead of surfacing as a failed
        // request.
        signal(SIGPIPE, SIG_IGN)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // A minimal main menu so Cmd+Q works even though this is a menu-bar
        // app: the status menu's Quit keyEquivalent only fires while that menu
        // is open, which would otherwise trap keyboard-only users (notably in
        // the mandatory onboarding window).
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit MagSleep", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        app.mainMenu = mainMenu
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

        // Prevent a second instance (e.g. the binary launched directly instead
        // of via `open`): two instances would create duplicate status items and
        // fight over the request file. Activate the existing instance instead.
        if let bundleID = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
               .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        }

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

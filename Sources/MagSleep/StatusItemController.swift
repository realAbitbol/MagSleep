import AppKit
import MagSleepCore

final class StatusItemController: NSObject {
    private let helper: HelperManager
    private let statusItem: NSStatusItem
    private var refreshTimer: Timer?

    init(helper: HelperManager) {
        self.helper = helper
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = Self.menuBarImage()
            button.image?.isTemplate = true
            button.toolTip = "MagSleep"
        }

        rebuildMenu()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.helper.refresh()
            self?.rebuildMenu()
        }
    }

    private static func menuBarImage() -> NSImage {
        if let image = NSImage(systemSymbolName: "moon.zzz",
                               accessibilityDescription: "MagSleep") {
            return image
        }
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        NSColor.labelColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 4, y: 4, width: 10, height: 10)).fill()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private func rebuildMenu() {
        helper.refresh()
        let menu = NSMenu()
        menu.autoenablesItems = false

        let status = NSMenuItem(title: helper.statusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        if helper.isLoaded {
            let disable = NSMenuItem(
                title: "Disable MagSleep",
                action: #selector(disableMagSleep),
                keyEquivalent: ""
            )
            disable.target = self
            menu.addItem(disable)
        } else {
            let enable = NSMenuItem(
                title: helper.isInstalled ? "Enable MagSleep" : "Enable MagSleep…",
                action: #selector(enableMagSleep),
                keyEquivalent: ""
            )
            enable.target = self
            menu.addItem(enable)
        }

        let uninstall = NSMenuItem(
            title: "Uninstall MagSleep…",
            action: #selector(uninstallMagSleep),
            keyEquivalent: ""
        )
        uninstall.target = self
        uninstall.isEnabled = helper.isInstalled || helper.isLoaded
        menu.addItem(uninstall)

        menu.addItem(.separator())

        let login = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        login.target = self
        login.state = helper.launchesAtLogin ? .on : .off
        menu.addItem(login)

        let coffee = NSMenuItem(
            title: "Buy me a coffee",
            action: #selector(buyCoffee),
            keyEquivalent: ""
        )
        coffee.target = self
        menu.addItem(coffee)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit MagSleep",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func enableMagSleep() {
        helper.enable { [weak self] success in
            guard let self else { return }
            self.rebuildMenu()
            if !success, let error = self.helper.lastError {
                self.showAlert(title: "Could not enable MagSleep", message: error)
            }
        }
    }

    @objc private func disableMagSleep() {
        helper.disable { [weak self] success in
            guard let self else { return }
            self.rebuildMenu()
            if !success, let error = self.helper.lastError {
                self.showAlert(title: "Could not disable MagSleep", message: error)
            }
        }
    }

    @objc private func uninstallMagSleep() {
        let alert = NSAlert()
        alert.messageText = "Uninstall MagSleep?"
        alert.informativeText = "This removes the privileged helper, restores MagSafe LED control to macOS, and turns off Launch at Login. MagSleep will quit afterwards — you can delete MagSleep.app yourself."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        helper.uninstall { [weak self] success in
            guard let self else { return }
            if success {
                NSApp.terminate(nil)
            } else {
                self.rebuildMenu()
                if let error = self.helper.lastError {
                    self.showAlert(title: "Could not uninstall MagSleep", message: error)
                }
            }
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try helper.setLaunchesAtLogin(!helper.launchesAtLogin)
            rebuildMenu()
        } catch {
            showAlert(title: "Launch at Login", message: error.localizedDescription)
        }
    }

    @objc private func buyCoffee() {
        NSWorkspace.shared.open(MagSleep.coffeeURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

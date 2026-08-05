import AppKit
import MagSleepCore

final class StatusItemController: NSObject {
    private let helper: HelperManager
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var refreshTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    private let modeSleepItem = NSMenuItem()
    private let modeAlwaysOffItem = NSMenuItem()
    private let modeDisabledItem = NSMenuItem()

    private let launchAtLoginItem = NSMenuItem()

    init(helper: HelperManager) {
        self.helper = helper
        super.init()

        setupObservers()
        createMenu()
        createStatusItem()
        startRefreshTimer()

        // Defer startup prompts so modal alerts don't block
        // applicationDidFinishLaunching (which constructs this controller).
        DispatchQueue.main.async { [weak self] in
            self?.runStartupChecks()
        }
    }

    private func runStartupChecks() {
        // Check if helper needs to be installed
        if !helper.isInstalled {
            showInstallPrompt()
        }

        // Check if installed helper is outdated. If the user chose "Quit",
        // stop here — no further dialogs or actions.
        if helper.isInstalled && helper.needsUpgrade {
            guard showUpdateHelperPrompt() else { return }
        }

        // Check if launch-at-login preference has been set
        if !UserDefaults.standard.bool(forKey: "LaunchAtLoginPromptShown") {
            UserDefaults.standard.set(true, forKey: "LaunchAtLoginPromptShown")
            showLaunchAtLoginPrompt()
        }

        // Restart the helper on launch if it's installed but not running
        // (e.g. after an external kill). Deliberately "Disabled" helpers stay
        // disabled — we only recover daemon liveness, never override the user's
        // enabled state. Skip while an install/update is already in flight to
        // avoid a second privileged install racing the first.
        if helper.isInstalled && !helper.isLoaded && !helper.isInstalling {
            helper.enable() { [weak self] _ in
                self?.updateMenuStates()
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let observer = wakeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        // `statusItem = nil` alone does not remove the item from the system
        // status bar — the NSStatusBar keeps a strong reference to it.
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        menu = nil
    }

    private func setupObservers() {
        wakeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshHelperState()
        }
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = menu
        statusItem = item

        if let button = item.button {
            button.image = statusImage()
            button.toolTip = helper.statusTitle
        }
    }

    /// Menu bar icon reflecting the current mode/state.
    private func statusImage() -> NSImage? {
        let symbolName: String
        if helper.isInstalling {
            symbolName = "hourglass"
        } else if !helper.isInstalled {
            symbolName = "exclamationmark.triangle"
        } else if !helper.isLoaded {
            symbolName = "exclamationmark.triangle"
        } else if !helper.isEnabled {
            symbolName = "circle.slash"
        } else {
            switch helper.mode {
            case .sleep: symbolName = "moon.zzz"
            case .alwaysOff: symbolName = "bolt.slash"
            }
        }
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: helper.statusTitle)
        image?.isTemplate = true
        return image
    }

    private func createMenu() {
        let menu = NSMenu()

        // Status label
        let statusItem = NSMenuItem(title: helper.statusTitle, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        menu.addItem(NSMenuItem.separator())

        // Mode items (checkmark shows the current mode)
        modeSleepItem.title = "Sleep Mode"
        modeSleepItem.toolTip = "Turn LED off on sleep, restore on wake"
        modeSleepItem.image = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: nil)
        modeSleepItem.target = self
        modeSleepItem.action = #selector(setSleepMode)
        menu.addItem(modeSleepItem)

        modeAlwaysOffItem.title = "Always Off"
        modeAlwaysOffItem.toolTip = "Keep LED off at all times"
        modeAlwaysOffItem.image = NSImage(systemSymbolName: "bolt.slash", accessibilityDescription: nil)
        modeAlwaysOffItem.target = self
        modeAlwaysOffItem.action = #selector(setAlwaysOffMode)
        menu.addItem(modeAlwaysOffItem)

        modeDisabledItem.title = "Disabled"
        modeDisabledItem.toolTip = "Let macOS control the LED"
        modeDisabledItem.image = NSImage(systemSymbolName: "circle.slash", accessibilityDescription: nil)
        modeDisabledItem.target = self
        modeDisabledItem.action = #selector(setDisabledMode)
        menu.addItem(modeDisabledItem)

        menu.addItem(NSMenuItem.separator())

        // Launch at Login (only meaningful when the app runs from /Applications)
        launchAtLoginItem.title = "Launch at Login"
        launchAtLoginItem.toolTip = helper.canManageLaunchAtLogin
            ? "Start MagSleep automatically at login"
            : "Move MagSleep.app to /Applications to use this"
        launchAtLoginItem.isEnabled = helper.canManageLaunchAtLogin
        launchAtLoginItem.target = self
        launchAtLoginItem.action = #selector(toggleLaunchAtLogin)
        launchAtLoginItem.state = helper.launchesAtLogin ? .on : .off
        menu.addItem(launchAtLoginItem)
        menu.addItem(NSMenuItem.separator())

        // Buy me a coffee
        let coffeeItem = NSMenuItem(title: "Buy me a coffee", action: #selector(openCoffee), keyEquivalent: "")
        coffeeItem.image = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil)
        coffeeItem.target = self
        menu.addItem(coffeeItem)

        // Uninstall
        let uninstallItem = NSMenuItem(title: "Uninstall MagSleep", action: #selector(uninstall), keyEquivalent: "")
        uninstallItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        uninstallItem.target = self
        menu.addItem(uninstallItem)

        // About
        let aboutItem = NSMenuItem(title: "About MagSleep…", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit MagSleep", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.menu = menu
    }

    @objc private func setSleepMode() {
        guard helper.isInstalled else {
            showInstallPrompt()
            return
        }
        helper.setMode(.sleep) { [weak self] success in
            guard let self else { return }
            if success {
                self.updateMenuStates()
            } else {
                self.showError(self.failureMessage("Failed to set sleep mode"))
            }
        }
    }

    @objc private func setAlwaysOffMode() {
        guard helper.isInstalled else {
            showInstallPrompt()
            return
        }
        helper.setMode(.alwaysOff) { [weak self] success in
            guard let self else { return }
            if success {
                self.updateMenuStates()
            } else {
                self.showError(self.failureMessage("Failed to set always off mode"))
            }
        }
    }

    @objc private func setDisabledMode() {
        helper.disable { [weak self] success in
            guard let self else { return }
            if success {
                self.updateMenuStates()
            } else {
                self.showError(self.failureMessage("Failed to disable"))
            }
        }
    }

    @objc private func toggleLaunchAtLogin() {
        guard helper.canManageLaunchAtLogin else {
            showError("Move MagSleep.app to /Applications to use Launch at Login.")
            return
        }
        do {
            let newState = !helper.launchesAtLogin
            try helper.setLaunchesAtLogin(newState)
            launchAtLoginItem.state = newState ? .on : .off
        } catch {
            showError("Failed to change launch at login setting: \(error.localizedDescription)")
        }
    }

    @objc private func openCoffee() {
        NSWorkspace.shared.open(MagSleep.coffeeURL)
    }

    @objc private func uninstall() {
        let alert = NSAlert()
        alert.messageText = "Uninstall MagSleep"
        alert.informativeText = "This will remove the helper and restore the MagSafe LED to macOS control. This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        helper.uninstall { [weak self] success in
            if success {
                // Leave nothing behind: drop the app's preference domain
                // (LaunchAtLoginPromptShown, etc.) before quitting.
                if let bundleID = Bundle.main.bundleIdentifier {
                    UserDefaults.standard.removePersistentDomain(forName: bundleID)
                }
                NSApp.terminate(nil)
            } else {
                self?.showError(self?.failureMessage("Failed to uninstall MagSleep") ?? "Failed to uninstall MagSleep")
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func showAbout() {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let helperVersion = helper.helperVersion ?? "not installed"
        let alert = NSAlert()
        alert.messageText = "MagSleep \(appVersion)"
        alert.informativeText = """
        A tiny menu bar app that turns off the MagSafe LED on sleep and restores it on wake — or keeps it off completely in Always Off mode.

        Application version: \(appVersion)
        Helper version: \(helperVersion)
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - UI Updates

    private func updateMenuStates() {
        // Update status icon + tooltip
        statusItem?.button?.image = statusImage()
        statusItem?.button?.toolTip = helper.statusTitle
        if let statusItem = menu?.item(at: 0) {
            statusItem.title = helper.statusTitle
        }

        // Update mode selection
        if !helper.isEnabled {
            modeSleepItem.state = .off
            modeAlwaysOffItem.state = .off
            modeDisabledItem.state = .on
        } else {
            modeDisabledItem.state = .off
            switch helper.mode {
            case .sleep:
                modeSleepItem.state = .on
                modeAlwaysOffItem.state = .off
            case .alwaysOff:
                modeSleepItem.state = .off
                modeAlwaysOffItem.state = .on
            }
        }

        // Update launch at login
        launchAtLoginItem.state = helper.launchesAtLogin ? .on : .off
    }

    private func refreshHelperState() {
        helper.refresh()
        updateMenuStates()
    }

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshHelperState()
        }
    }

    // MARK: - Prompts

    private func showInstallPrompt() {
        let alert = NSAlert()
        alert.messageText = "Install MagSleep Helper"
        alert.informativeText = "MagSleep requires a helper to control the MagSafe LED. Would you like to install it now?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            helper.enable() { [weak self] success in
                guard let self else { return }
                if success {
                    self.updateMenuStates()
                } else {
                    self.showError(self.failureMessage("Failed to install helper"))
                }
            }
        }
    }

    private func showLaunchAtLoginPrompt() {
        // SMAppService.mainApp can't register a login item for a bundle that
        // isn't in /Applications — don't offer a feature that can't work.
        guard helper.canManageLaunchAtLogin else { return }
        let alert = NSAlert()
        alert.messageText = "Launch at Login?"
        alert.informativeText = "Launch MagSleep at login so it can manage your MagSafe LED automatically?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            do {
                try helper.setLaunchesAtLogin(true)
                launchAtLoginItem.state = .on
            } catch {
                // Silently fail; user can enable manually
            }
        }
    }

    /// Returns false if the user chose "Quit" (so remaining startup checks are skipped).
    private func showUpdateHelperPrompt() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Outdated Helper Detected"
        alert.informativeText = "The installed helper is outdated. MagSleep requires the helper to be updated to function properly."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Update Helper")
        alert.addButton(withTitle: "Quit")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            helper.install() { [weak self] success in
                guard let self else { return }
                if !success {
                    self.showError(self.failureMessage("Failed to update helper"))
                    NSApp.terminate(nil)
                } else {
                    self.refreshHelperState()
                }
            }
            return true
        } else {
            NSApp.terminate(nil)
            return false
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "MagSleep"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Appends the underlying helper error (if any) to a fallback message so
    /// failures are diagnosable instead of generic.
    private func failureMessage(_ fallback: String) -> String {
        guard let detail = helper.lastError, !detail.isEmpty else { return fallback }
        return "\(fallback): \(detail)"
    }
}

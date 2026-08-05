import AppKit
import MagSleepCore

final class StatusItemController: NSObject, NSTextViewDelegate {
    private let helper: HelperManager
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    /// Slow fallback timer (15s) for state refresh; the primary signal is the
    /// config-directory watch below.
    private var refreshTimer: Timer?
    private var configWatcher: DirectoryWatcher?
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
        startConfigWatcher()

        // Defer startup prompts so modal alerts don't block
        // applicationDidFinishLaunching (which constructs this controller).
        DispatchQueue.main.async { [weak self] in
            self?.runStartupChecks()
        }
    }

    /// Watch the config directory so the UI updates the moment the daemon
    /// persists a mode/enable change — no waiting for a poll cycle.
    private func startConfigWatcher() {
        let watcher = DirectoryWatcher(path: MagSleep.configDirectory) { [weak self] in
            self?.refreshHelperState()
        }
        watcher.start()
        configWatcher = watcher
    }

    private func runStartupChecks() {
        // Chain the checks so prompts never overlap and each runs against
        // fresh state: install → helper upgrade → launch-at-login → recovery.
        checkInstall { [weak self] installed in
            guard let self else { return }
            self.checkUpgrade { [weak self] updated in
                guard let self else { return }
                let justManagedHelper = installed || updated
                self.checkLaunchAtLoginPrompt()
                self.checkDaemonRecovery(skip: justManagedHelper)
                self.checkForUpdateOnLaunch()
            }
        }
    }

    /// Returns whether the user opted into installing the helper in this step.
    private func checkInstall(completion: @escaping (Bool) -> Void) {
        guard !helper.isInstalled else {
            completion(false)
            return
        }
        showInstallPrompt(completion: completion)
    }

    /// Returns whether the user opted into updating the helper in this step.
    private func checkUpgrade(completion: @escaping (Bool) -> Void) {
        guard helper.isInstalled, helper.needsUpgrade else {
            completion(false)
            return
        }
        showUpdateHelperPrompt(completion: completion)
    }

    private func checkLaunchAtLoginPrompt() {
        guard helper.canManageLaunchAtLogin,
              !UserDefaults.standard.bool(forKey: "LaunchAtLoginPromptShown") else { return }
        UserDefaults.standard.set(true, forKey: "LaunchAtLoginPromptShown")
        showLaunchAtLoginPrompt()
    }

    /// Restart the helper on launch if it's installed but not running
    /// (e.g. after an external kill). Deliberately "Disabled" helpers stay
    /// disabled — we only recover daemon liveness, never override the user's
    /// enabled state. Skip while an install/update is already in flight to
    /// avoid a second privileged install racing the first, and never reinstall
    /// immediately after the install/update we just performed (the daemon was
    /// just bootstrapped; probing again would be redundant and would trigger a
    /// second admin prompt).
    private func checkDaemonRecovery(skip: Bool) {
        guard !skip, helper.isInstalled, !helper.isLoaded, !helper.isInstalling else { return }
        // helper.isLoaded was last probed at launch (HelperManager.init), but
        // the daemon's RunAtLoad bootstrap may still be in flight — a single
        // probe can false-negative and trigger a spurious admin prompt + full
        // reinstall. Give the daemon a short grace period first.
        confirmDaemonReachable { [weak self] reachable in
            guard let self else { return }
            if reachable {
                self.updateMenuStates()
            } else {
                self.helper.enable() { [weak self] _ in
                    self?.updateMenuStates()
                }
            }
        }
    }

    /// Re-probes the daemon a few times over a few seconds. Returns true as
    /// soon as the socket answers; false if it never comes up in time.
    private func confirmDaemonReachable(triesLeft: Int = 3, completion: @escaping (Bool) -> Void) {
        helper.refreshAsync { [weak self] in
            guard let self else { return }
            if self.helper.isLoaded {
                completion(true)
            } else if triesLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.confirmDaemonReachable(triesLeft: triesLeft - 1, completion: completion)
                }
            } else {
                completion(false)
            }
        }
    }

    private func checkForUpdateOnLaunch() {
        UpdateChecker.latestVersion(force: false) { [weak self] latest in
            guard let latest else { return }
            DispatchQueue.main.async {
                self?.presentUpdateResult(latest)
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
        refreshTimer = nil
        configWatcher?.stop()
        configWatcher = nil
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

        // Check for Updates
        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        updateItem.target = self
        menu.addItem(updateItem)

        // Copy Diagnostics
        let diagnosticsItem = NSMenuItem(title: "Copy Diagnostics…", action: #selector(copyDiagnostics), keyEquivalent: "")
        diagnosticsItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        diagnosticsItem.target = self
        menu.addItem(diagnosticsItem)

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
            showInstallPrompt(completion: { _ in })
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
            showInstallPrompt(completion: { _ in })
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

    @objc private func checkForUpdates() {
        UpdateChecker.latestVersion(force: true) { [weak self] latest in
            DispatchQueue.main.async {
                self?.presentUpdateResult(latest)
            }
        }
    }

    private func presentUpdateResult(_ latest: String?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        if let latest {
            alert.messageText = "MagSleep \(latest) is available"
            alert.informativeText = "A newer version of MagSleep is available on GitHub."
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(UpdateChecker.releasesPageURL)
            }
        } else {
            alert.messageText = "MagSleep is up to date"
            alert.informativeText = "You have the latest version of MagSleep."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// Copies a support-friendly diagnostics block to the clipboard.
    @objc private func copyDiagnostics() {
        var lines: [String] = []
        lines.append("MagSleep Diagnostics")
        lines.append("Generated: \(Date())")
        lines.append("App version: \(helper.appVersion)")
        lines.append("Helper version: \(helper.helperVersion ?? "not installed")")
        lines.append("Helper installed: \(helper.isInstalled)")
        lines.append("Helper running: \(helper.isLoaded)")
        lines.append("Mode: \(helper.mode.rawValue)")
        lines.append("Enabled: \(helper.isEnabled)")
        lines.append("Socket: \(MagSleep.socketPath)")
        if let data = try? Data(contentsOf: URL(fileURLWithPath: MagSleep.configFilePath)),
           let config = try? PropertyListDecoder().decode(DaemonConfig.self, from: data) {
            lines.append("Config on disk: mode=\(config.mode.rawValue), enabled=\(config.enabled)")
        } else {
            lines.append("Config on disk: (unreadable or missing)")
        }
        if let color = try? MagSafeLED.current() {
            lines.append("ACLC current: \(ledColorName(color))")
        } else {
            lines.append("ACLC current: (read failed)")
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func ledColorName(_ color: MagSafeLED.Color) -> String {
        switch color {
        case .system: return "system (0)"
        case .off: return "off (1)"
        case .green: return "green (3)"
        case .amber: return "amber (4)"
        }
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
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")

        // Body + clickable Ko-fi link as a non-editable text view. NSTextView
        // renders the link underline below the descenders (a link-styled
        // NSButton draws it at the baseline, where the "p" legs cut through it)
        // and handles link clicks without the NSTextField field-editor bug that
        // re-centered the text and dropped the link.
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center

        let body = NSMutableAttributedString()
        body.append(NSAttributedString(
            string: "A tiny menu bar app that turns off the MagSafe LED on sleep and restores it on wake — or keeps it off completely in Always Off mode.\n\nApplication version: \(appVersion)\nHelper version: \(helperVersion)\n\nMade with ♥️ by Abitbol\n\n",
            attributes: [.paragraphStyle: centered]
        ))
        body.append(NSAttributedString(
            string: "Support me on Kofi ☕",
            attributes: [.link: MagSleep.coffeeURL, .paragraphStyle: centered]
        ))

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true // required for link activation
        textView.drawsBackground = false
        textView.isRichText = true
        textView.textContainerInset = .zero
        textView.autoresizingMask = []
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: 420, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 420, height: CGFloat.greatestFiniteMagnitude)
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        textView.delegate = self
        textView.textStorage?.setAttributedString(body)

        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let height = ceil(textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 0)
        textView.frame = NSRect(x: 0, y: 0, width: 420, height: max(height, 1))

        alert.accessoryView = textView
        alert.runModal()
    }

    // MARK: - NSTextViewDelegate

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL {
            NSWorkspace.shared.open(url)
            return true
        }
        return false
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
        // Probe the socket off the main thread so a slow or unresponsive
        // daemon can never stall the UI; update the menu once the state lands.
        helper.refreshAsync { [weak self] in
            self?.updateMenuStates()
        }
    }

    private func startRefreshTimer() {
        // Slow fallback: the config-directory watch is the primary signal, this
        // catches anything it misses (and arms the watch once the directory
        // exists, e.g. right after the helper is installed).
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            self?.configWatcher?.start()
            self?.refreshHelperState()
        }
        // Add in .common so the refresh keeps running while a menu is open
        // (the run loop is in eventTracking mode then, where .default timers
        // are paused).
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    // MARK: - Prompts

    private func showInstallPrompt(completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Install MagSleep Helper"
        alert.informativeText = "MagSleep requires a helper to control the MagSafe LED. Would you like to install it now?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            helper.enable() { [weak self] success in
                guard let self else { completion(true); return }
                if success {
                    self.updateMenuStates()
                } else {
                    self.handleHelperFailure("Failed to install helper")
                }
                completion(true)
            }
        } else {
            completion(false)
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

    private func showUpdateHelperPrompt(completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Outdated Helper Detected"
        alert.informativeText = "The installed helper is outdated. MagSleep requires the helper to be updated to function properly."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Update Helper")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            helper.install() { [weak self] success in
                guard let self else { completion(true); return }
                if !success {
                    self.handleHelperFailure("Failed to update helper")
                }
                self.refreshHelperState()
                completion(true)
            }
        } else {
            // Declining no longer quits the app; the status icon keeps
            // signaling that the helper needs an update.
            completion(false)
        }
    }

    /// Surfaces an install/update failure. When the helper is installed but
    /// unreachable (e.g. the post-install connection confirmation timed out),
    /// offer a full reinstall instead of a dead-end error.
    private func handleHelperFailure(_ fallback: String) {
        if helper.isInstalled && !helper.isLoaded {
            showReinstallPrompt()
        } else {
            showError(failureMessage(fallback))
        }
    }

    /// Offers to completely reinstall the helper (install-helper.sh does a
    /// bootout, fresh binary install, and bootstrap). Requires admin.
    private func showReinstallPrompt() {
        let alert = NSAlert()
        alert.messageText = "Can't connect to helper"
        alert.informativeText = "MagSleep installed the helper but can't reach it. Reinstalling usually fixes this — you will be asked for your admin password."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reinstall Helper")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            helper.install() { [weak self] success in
                guard let self else { return }
                if success {
                    self.updateMenuStates()
                } else {
                    self.showError(self.failureMessage("Failed to reinstall helper"))
                }
            }
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

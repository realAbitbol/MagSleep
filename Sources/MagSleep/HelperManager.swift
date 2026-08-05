import AppKit
import Foundation
import MagSleepCore
import ServiceManagement

/// Installs, enables, disables, and removes the privileged helper daemon.
final class HelperManager {
    private(set) var isInstalled = false
    private(set) var isLoaded = false
    private(set) var mode: OperationMode = .sleep
    private(set) var isEnabled = false
    /// True while a privileged install/update script is running (admin prompt)
    /// or while we are confirming the daemon came back up afterwards. Both
    /// keep the menu-bar icon on the hourglass.
    private(set) var isInstalling = false
    /// True while `confirmConnection` is polling the socket after an install.
    private(set) var isConfirmingConnection = false
    /// True after a post-install confirmation timed out (daemon unreachable).
    private(set) var connectionFailed = false
    var lastError: String?
    /// True when the last privileged attempt ended because the user cancelled
    /// the admin password prompt (distinct from a real failure — `lastError`
    /// is nil in both cases).
    private(set) var lastAttemptWasCancelled = false

    /// Compact status string shared by Shortcuts and AppleScript.
    var statusDescription: String {
        LEDStatusDescription.describe(
            isInstalled: isInstalled,
            isLoaded: isLoaded,
            isEnabled: isEnabled,
            mode: mode
        )
    }

    /// How often to re-probe the socket while confirming a fresh install.
    private let connectionConfirmInterval: TimeInterval = 1.0
    /// How long to wait for the daemon to come up before declaring failure.
    private let connectionConfirmTimeout: TimeInterval = 15.0
    /// How long a privileged helper script may run before it is force-killed
    /// (a left-open admin prompt must never block a worker thread forever).
    private let privilegedScriptTimeout: TimeInterval = 180

    init() {
        refresh()
    }

    func refresh() {
        let fm = FileManager.default
        isInstalled = fm.fileExists(atPath: MagSleep.helperPlistPath)
            && fm.fileExists(atPath: MagSleep.helperBinaryPath)

        // Cheap liveness probe: the daemon's unix socket only exists while it
        // is listening, so a successful connect means it is actually running
        // (no pgrep spawn, no caching).
        isLoaded = isInstalled && HelperConnection.probe()
        if isLoaded {
            connectionFailed = false
        }

        // Reload mode and enabled state from config
        loadConfig()
    }

    /// Same as `refresh()`, but performs the (potentially blocking) socket
    /// probe off the main thread and delivers the updated state on the main
    /// queue. Prefer this for periodic/timer-driven refreshes so a slow or
    /// unresponsive daemon can never stall the UI.
    func refreshAsync(completion: (() -> Void)? = nil) {
        let fm = FileManager.default
        isInstalled = fm.fileExists(atPath: MagSleep.helperPlistPath)
            && fm.fileExists(atPath: MagSleep.helperBinaryPath)
        guard isInstalled else {
            isLoaded = false
            connectionFailed = false
            mode = .sleep
            isEnabled = false
            completion?()
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let loaded = HelperConnection.probe()
            DispatchQueue.main.async {
                self.isLoaded = loaded
                if loaded {
                    self.connectionFailed = false
                }
                self.loadConfig()
                completion?()
            }
        }
    }

    var statusTitle: String {
        if isInstalling {
            return isConfirmingConnection ? "Connecting to helper…" : "Installing helper…"
        }
        if !isInstalled {
            return "Helper not installed"
        }
        if !isLoaded {
            return connectionFailed ? "Can't connect to helper" : "Helper not running"
        }
        if !isEnabled {
            return "Disabled"
        }
        switch mode {
        case .sleep: return "Sleep Mode Active"
        case .alwaysOff: return "Always Off Active"
        }
    }

    // MARK: - Config Loading

    private func loadConfig() {
        guard isInstalled else {
            mode = .sleep
            isEnabled = false
            return
        }

        // The daemon writes the config world-readable (0644) so the app can
        // reflect the real mode/enabled state. If it can't be read yet (e.g.
        // first launch right after install), keep the last known state.
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: MagSleep.configFilePath)),
              let config = try? PropertyListDecoder().decode(DaemonConfig.self, from: data) else {
            return
        }
        mode = config.mode
        isEnabled = config.enabled
    }

    /// Version of the app bundle.
    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Revision of the installed helper (nil if not installed). This is the
    /// **helper revision** (last commit touching helper-affecting code) that
    /// install-helper.sh wrote at install time, not the app version.
    var helperVersion: String? {
        guard isInstalled else { return nil }
        return try? String(contentsOfFile: MagSleep.helperVersionFilePath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Revision of the helper bundled with this app, embedded by build-app.sh
    /// (see scripts/build-app.sh). "unknown" when git was unavailable at build
    /// time, which keeps the legacy always-reinstall behavior.
    private var helperRevision: String {
        guard let path = Bundle.main.path(forResource: "helper-revision", ofType: "txt"),
              let revision = try? String(contentsOfFile: path, encoding: .utf8) else {
            return "unknown"
        }
        return revision.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the installed helper matches the one bundled with this app
    /// (nil when the helper is not installed).
    var helperIsCurrent: Bool? {
        guard isInstalled else { return nil }
        return !HelperVersioning.shouldReinstall(
            installedRevision: helperVersion,
            bundledRevision: helperRevision
        )
    }

    /// Returns true if the installed helper revision differs from the one this
    /// app bundles — i.e. the helper actually changed and must be reinstalled.
    var needsUpgrade: Bool {
        guard isInstalled else { return false }
        return HelperVersioning.shouldReinstall(
            installedRevision: helperVersion,
            bundledRevision: helperRevision
        )
    }

    /// Installs or re-installs the helper with the bundled helper revision
    /// (needs admin). Keeps `isInstalling` true through the post-install
    /// connection confirmation so the UI shows the hourglass until the daemon
    /// answers.
    func install(completion: @escaping (Bool) -> Void) {
        isInstalling = true
        runPrivilegedScript(named: "install-helper.sh", args: [helperRevision]) { [weak self] success in
            guard let self else { return }
            if success {
                self.isConfirmingConnection = true
                self.confirmConnection(completion: completion)
            } else {
                self.isInstalling = false
                self.refresh()
                completion(false)
            }
        }
    }

    /// Polls the socket until the freshly installed daemon answers, or until
    /// `connectionConfirmTimeout` elapses. Runs the probe off the main thread
    /// (non-blocking connect) and hops back to main between attempts.
    private func confirmConnection(completion: @escaping (Bool) -> Void) {
        let start = Date()
        func attempt() {
            DispatchQueue.global(qos: .userInitiated).async {
                let reachable = HelperConnection.probe()
                DispatchQueue.main.async {
                    if reachable {
                        self.isInstalling = false
                        self.isConfirmingConnection = false
                        self.refresh()
                        completion(true)
                    } else if Date().timeIntervalSince(start) >= self.connectionConfirmTimeout {
                        self.isInstalling = false
                        self.isConfirmingConnection = false
                        self.connectionFailed = true
                        self.lastError = "The helper was installed but could not be reached."
                        self.refresh()
                        completion(false)
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + self.connectionConfirmInterval) {
                            attempt()
                        }
                    }
                }
            }
        }
        attempt()
    }

    // MARK: - Mode Management (via socket, no admin)

    /// Applies a user-facing LED mode (Sleep / Always Off / Disabled) through
    /// the same `setMode`/`disable` paths the menu uses — the single entry
    /// point for the menu, Shortcuts, and AppleScript.
    func apply(_ mode: LEDMode, completion: @escaping (Bool) -> Void) {
        if let operation = mode.operationMode {
            setMode(operation, completion: completion)
        } else {
            disable(completion: completion)
        }
    }

    func setMode(_ newMode: OperationMode, completion: @escaping (Bool) -> Void) {
        guard isLoaded else {
            lastError = "Helper is not running"
            completion(false)
            return
        }
        sendRequest("mode:\(newMode.rawValue)") { [weak self] success in
            if success {
                self?.mode = newMode
            }
            self?.refresh()
            completion(success)
        }
    }

    // MARK: - Enable / Disable (via socket, no admin)

    func enable(completion: @escaping (Bool) -> Void) {
        // The install script records the bundled helper revision (not the app
        // version) so an unchanged helper is never reported as outdated.
        let revision = helperRevision
        // If helper is not installed at all, need privileged install
        guard isInstalled else {
            // Fall through to privileged install
            isInstalling = true
            runPrivilegedScript(named: "install-helper.sh", args: [revision]) { [weak self] success in
                guard let self else { return }
                if success {
                    self.isConfirmingConnection = true
                    self.confirmConnection(completion: completion)
                } else {
                    self.isInstalling = false
                    self.refresh()
                    completion(false)
                }
            }
            return
        }

        // If helper is installed but not loaded, try to bootstrap it (needs admin)
        guard isLoaded else {
            isInstalling = true
            runPrivilegedScript(named: "install-helper.sh", args: [revision]) { [weak self] success in
                guard let self else { return }
                if success {
                    self.isConfirmingConnection = true
                    self.confirmConnection(completion: completion)
                } else {
                    self.isInstalling = false
                    self.refresh()
                    completion(false)
                }
            }
            return
        }

        // Helper is running; just send enable request
        sendRequest("enable") { [weak self] success in
            self?.refresh()
            completion(success)
        }
    }

    func disable(completion: @escaping (Bool) -> Void) {
        // Requires a live daemon (socket ack). If the daemon is dead the LED is
        // already unmanaged; the app's launch-time recovery re-bootstraps it.
        guard isInstalled else {
            // Nothing installed: nothing to disable.
            isEnabled = false
            completion(true)
            return
        }
        sendRequest("disable") { [weak self] success in
            self?.isEnabled = false
            self?.refresh()
            completion(success)
        }
    }

    // MARK: - Uninstall (needs admin)

    func uninstall(completion: @escaping (Bool) -> Void) {
        runPrivilegedScript(named: "uninstall-helper.sh") { [weak self] success in
            if success {
                try? SMAppService.mainApp.unregister()
            }
            self?.refresh()
            completion(success)
        }
    }

    // MARK: - Launch at Login

    var launchesAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// SMAppService.mainApp records the bundle path it was registered from, so
    /// Launch at Login only works reliably when the app runs from /Applications
    /// (a dev build in dist/ would pin the login item to a throwaway path).
    var canManageLaunchAtLogin: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    func setLaunchesAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    // MARK: - Socket Communication

    /// Sends a command to the helper daemon over the unix socket and awaits its
    /// acknowledgment, so success reflects what actually happened (no more
    /// optimistic reporting).
    private func sendRequest(_ command: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let response = try HelperConnection.send(command)
                DispatchQueue.main.async {
                    if response.ok {
                        self.lastError = nil
                        completion(true)
                    } else {
                        self.lastError = response.error ?? "Helper rejected the request"
                        completion(false)
                    }
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? "Could not communicate with helper"
                DispatchQueue.main.async {
                    self.lastError = message
                    completion(false)
                }
            }
        }
    }

    // MARK: - Privileged Script Execution

    private func runPrivilegedScript(named scriptName: String,
                                     args: [String] = [],
                                     completion: @escaping (Bool) -> Void) {
        // Each attempt starts fresh so a cancel can't be confused with a
        // stale error from a previous attempt.
        lastAttemptWasCancelled = false
        guard let scriptPath = Bundle.main.path(forResource: scriptName, ofType: nil),
              let resourcePath = Bundle.main.resourcePath else {
            lastError = "Helper resources missing; run the built MagSleep.app bundle."
            // Defensive: callers reset this on failure, but never leave the
            // UI stuck on the hourglass if a future caller forgets.
            isInstalling = false
            completion(false)
            return
        }
        let userName = NSUserName()
        let scriptArgs = [scriptPath, resourcePath, userName] + args
        let command = scriptArgs
            .map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: " ")
        // Build the AppleScript source and hand it to /usr/bin/osascript as a
        // single argv element. NSAppleScript is documented as not thread-safe
        // (main-thread only), so running it on a background queue risks
        // intermittent crashes; a separate osascript process is thread-safe and
        // keeps the app responsive while the admin prompt is up.
        let inner = "/bin/bash \(command)"
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(inner)\" with administrator privileges"

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", appleScript]
            process.standardOutput = FileHandle.nullDevice
            let errorPipe = Pipe()
            process.standardError = errorPipe

            // Drain stderr concurrently so a large error output can never
            // deadlock the pipe while osascript is still writing.
            var stderrData = Data()
            let stderrQueue = DispatchQueue(label: "magsleep.osascript.stderr")
            stderrQueue.async {
                stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            }

            // Bounded wait instead of waitUntilExit(): a left-open admin
            // prompt must never block this worker thread forever. The
            // termination handler is armed before run() so its signal can
            // never be missed.
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }

            do {
                try process.run()
                var timedOut = false
                if finished.wait(timeout: .now() + self.privilegedScriptTimeout) == .timedOut {
                    timedOut = true
                    process.terminate()
                    finished.wait() // the termination handler fires after terminate()
                }
                // Guarantee EOF for the background reader (the process is gone,
                // but our reference to the write end would otherwise keep the
                // read blocked forever).
                errorPipe.fileHandleForWriting.closeFile()
                stderrQueue.sync {}
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                DispatchQueue.main.async {
                    self.refresh()
                    if process.terminationStatus == 0 {
                        self.lastError = nil
                        self.lastAttemptWasCancelled = false
                        completion(true)
                    } else {
                        // The user cancelling the auth prompt is not an error.
                        let isCancel = stderr.localizedCaseInsensitiveContains("user canceled")
                            || stderr.contains("-128")
                        let message: String
                        if timedOut {
                            message = "The helper script timed out."
                        } else {
                            message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        self.lastError = isCancel
                            ? nil
                            : (message.isEmpty ? "Helper script failed." : message)
                        self.lastAttemptWasCancelled = isCancel
                        completion(false)
                    }
                }
            } catch {
                // Unblock the stderr reader so it does not leak a thread.
                errorPipe.fileHandleForWriting.closeFile()
                DispatchQueue.main.async {
                    self.isInstalling = false
                    self.lastError = "Could not run helper script: \(error.localizedDescription)"
                    completion(false)
                }
            }
        }
    }
}

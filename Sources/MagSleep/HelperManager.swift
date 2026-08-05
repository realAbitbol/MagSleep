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
    /// True while a privileged install/update script is running (admin prompt).
    private(set) var isInstalling = false
    var lastError: String?

    /// Cached result of launch daemon status check (nil = never checked).
    private var cachedDaemonLoaded: Bool?
    /// When the daemon liveness was last checked; used to age out the cache.
    private var daemonCheckDate: Date?
    /// Re-check daemon liveness at most this often, so a daemon that dies
    /// mid-session is detected within one interval.
    private let daemonCheckInterval: TimeInterval = 15

    init() {
        refresh()
    }

    func refresh() {
        let fm = FileManager.default
        isInstalled = fm.fileExists(atPath: MagSleep.helperPlistPath)
            && fm.fileExists(atPath: MagSleep.helperBinaryPath)

        // Re-check daemon liveness when never checked or when the cached result
        // has aged out, so a dead daemon is detected without spawning pgrep on
        // every 5s refresh tick.
        if isInstalled,
           cachedDaemonLoaded == nil
               || (daemonCheckDate.map { Date().timeIntervalSince($0) > daemonCheckInterval } ?? true) {
            cachedDaemonLoaded = isLaunchDaemonLoaded()
            daemonCheckDate = Date()
        }
        isLoaded = isInstalled && (cachedDaemonLoaded ?? false)

        // Invalidate cache when daemon is not installed
        if !isInstalled {
            cachedDaemonLoaded = nil
            daemonCheckDate = nil
        }

        // Reload mode and enabled state from config
        loadConfig()
    }

    /// Mark the daemon status cache as stale. Call after operations that may change it.
    func invalidateDaemonCache() {
        cachedDaemonLoaded = nil
    }

    var statusTitle: String {
        if isInstalling {
            return "Installing helper…"
        }
        if !isInstalled {
            return "Helper not installed"
        }
        if !isLoaded {
            return "Helper not running"
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

    /// Version of the installed helper (nil if not installed).
    var helperVersion: String? {
        guard isInstalled else { return nil }
        return try? String(contentsOfFile: MagSleep.helperVersionFilePath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns true if the installed helper version differs from the app version.
    var needsUpgrade: Bool {
        guard isInstalled else { return false }
        return helperVersion != appVersion
    }

    /// Installs or re-installs the helper with the current app version (needs admin).
    func install(completion: @escaping (Bool) -> Void) {
        isInstalling = true
        runPrivilegedScript(named: "install-helper.sh", args: [appVersion]) { [weak self] success in
            self?.isInstalling = false
            self?.invalidateDaemonCache()
            self?.refresh()
            completion(success)
        }
    }

    // MARK: - Mode Management (via request file, no admin)

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

    // MARK: - Enable / Disable (via request file, no admin)

    func enable(completion: @escaping (Bool) -> Void) {
        let version = appVersion
        // If helper is not installed at all, need privileged install
        guard isInstalled else {
            // Fall through to privileged install
            isInstalling = true
            runPrivilegedScript(named: "install-helper.sh", args: [version]) { [weak self] success in
                self?.isInstalling = false
                self?.invalidateDaemonCache()
                self?.refresh()
                completion(success)
            }
            return
        }

        // If helper is installed but not loaded, try to bootstrap it (needs admin)
        guard isLoaded else {
            isInstalling = true
            runPrivilegedScript(named: "install-helper.sh", args: [version]) { [weak self] success in
                self?.isInstalling = false
                self?.invalidateDaemonCache()
                self?.refresh()
                completion(success)
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
        // Send the request even when the daemon is currently dead (installed but
        // not running): the request file survives in /tmp/magsleep and is picked
        // up by `processRequestFile()` when the daemon (re)starts — otherwise
        // the persisted config would keep `enabled=true` and the daemon would
        // silently re-enable itself on its next launch.
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
            self?.invalidateDaemonCache()
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

    // MARK: - Request File Communication

    /// Send a command to the helper daemon via the request file.
    private func sendRequest(_ command: String, completion: @escaping (Bool) -> Void) {
        do {
            // Ensure the request directory exists (it may be absent if the
            // helper was just uninstalled or /tmp was cleaned).
            try FileManager.default.createDirectory(
                atPath: MagSleep.requestDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o777]
            )
            try command.write(
                toFile: MagSleep.requestFilePath,
                atomically: true,
                encoding: .utf8
            )
            // Request sent; daemon picks it up immediately via its directory watch.
            // Optimistically assume success; daemon will apply it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                completion(true)
            }
        } catch {
            lastError = "Could not communicate with helper: \(error.localizedDescription)"
            completion(false)
        }
    }

    // MARK: - Helpers

    private func isLaunchDaemonLoaded() -> Bool {
        // `launchctl print` exits 0 whenever the job is *registered* with
        // launchd — even if the process has exited (e.g. after `launchctl kill`
        // or a crash). Check the process is actually alive instead, so the app
        // can detect a dead helper and restart it.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", MagSleep.helperLabel]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Privileged Script Execution

    private func runPrivilegedScript(named scriptName: String,
                                     args: [String] = [],
                                     completion: @escaping (Bool) -> Void) {
        guard let scriptPath = Bundle.main.path(forResource: scriptName, ofType: nil),
              let resourcePath = Bundle.main.resourcePath else {
            lastError = "Helper resources missing; run the built MagSleep.app bundle."
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

            do {
                try process.run()
                process.waitUntilExit()
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
                        completion(true)
                    } else {
                        // The user cancelling the auth prompt is not an error.
                        let isCancel = stderr.localizedCaseInsensitiveContains("user canceled")
                            || stderr.contains("-128")
                        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.lastError = isCancel
                            ? nil
                            : (message.isEmpty ? "Helper script failed." : message)
                        completion(false)
                    }
                }
            } catch {
                // Unblock the stderr reader so it does not leak a thread.
                errorPipe.fileHandleForWriting.closeFile()
                DispatchQueue.main.async {
                    self.lastError = "Could not run helper script: \(error.localizedDescription)"
                    completion(false)
                }
            }
        }
    }
}

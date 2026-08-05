import Foundation
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import MagSleepCore
import os.log

/// magsleep-helper: privileged daemon that controls the MagSafe LED.
/// Runs as root via LaunchDaemon.
///
/// Behavior:
/// - Turns the MagSafe LED off when the Mac sleeps, restores macOS control on wake
/// - Watches the request directory for commands from the app (event-driven,
///   no polling): mode changes apply within milliseconds
/// - Re-asserts the active mode on power-source changes (covers alwaysOff
///   across plug-in / charging-state updates)
/// - Honors config.enabled: when false, LED is under macOS control, events ignored
/// - Falls back to DaemonConfig.default on startup if config is missing or corrupt
///
/// Invoked with --reset: restores the LED to macOS control and exits.
/// Used by uninstall-helper.sh.

/// IOKit power message IDs (C macros are not imported into Swift).
/// Values from IOMessage.h via `iokit_common_msg(...)`.
private enum PowerMessage {
    static let canSystemSleep: UInt32 = 0xe0000270
    static let systemWillSleep: UInt32 = 0xe0000280
    static let systemHasPoweredOn: UInt32 = 0xe0000300
}

final class PowerDaemon {
    private let log = Logger(subsystem: "com.magsleep.helper", category: "daemon")
    private var config = DaemonConfig.default
    private var isSleeping = false
    private var requestFileLastModified: TimeInterval = 0

    private var rootPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifierObject: io_object_t = 0
    private var signalSources: [DispatchSourceSignal] = []
    private var requestDirSource: DispatchSourceFileSystemObject?
    private var requestDirFD: Int32 = -1
    private var powerSourceSource: CFRunLoopSource?
    private var reassertTimer: Timer?
    /// Persistent SMC connection (opened lazily on first apply; retried on failure).
    private var smc: SMC.Connection?
    /// Throttles repeated SMC failure logs to one per distinct message.
    private var lastSMCLog: String?

    func run() {
        log.info("starting")

        // Ensure config and request directories exist
        ensureConfigDirectory()
        ensureRequestDirectory()

        // Load config (or fall back to defaults)
        loadConfig()

        // Seed the sleep state for the rare case where we're revived (launchd
        // KeepAlive) while the Mac is still asleep; power events keep it
        // accurate afterwards.
        isSleeping = isSystemSleeping()

        // Set up signal handlers and system power notifications
        setupSignalHandlers()
        registerForPowerNotifications()

        // Watch the request directory and power source changes (event-driven)
        armRequestDirectoryWatch()
        registerForPowerSourceChanges()

        // Process any request written before we started watching
        processRequestFile()

        // Slow re-assert timer: guarantees the LED converges back to the active
        // mode within a few seconds even if macOS changes it after our
        // event-driven writes (e.g. plug/unplug flips the LED to show charging).
        // A single-byte SMC write every 3s is negligible; mode-change latency is
        // unaffected (requests are still applied instantly via the directory
        // watch).
        startReassertTimer()

        // Run the run loop; all events fire here.
        RunLoop.main.run()
    }

    // MARK: - Config

    private func ensureConfigDirectory() {
        let dir = MagSleep.configDirectory
        if !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
        }
    }

    private func ensureRequestDirectory() {
        // World-writable so the user-space app can write requests without admin.
        try? FileManager.default.createDirectory(
            atPath: MagSleep.requestDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o777]
        )
    }

    private func loadConfig() {
        let url = URL(fileURLWithPath: MagSleep.configFilePath)
        var loaded = DaemonConfig.default
        let exists = FileManager.default.fileExists(atPath: url.path)

        if exists {
            do {
                let data = try Data(contentsOf: url)
                loaded = try PropertyListDecoder().decode(DaemonConfig.self, from: data)
            } catch {
                log.error("failed to load config: \(error)")
                loaded = DaemonConfig.default
            }
        }

        config = loaded
        log.info("config loaded: mode=\(self.config.mode.rawValue), enabled=\(self.config.enabled)")

        // Persist the initial state so the app (which runs as a user) can read
        // the current mode/enabled even if no request has been sent yet.
        if !exists {
            saveConfig(config)
        }

        // If disabled on startup, restore LED to macOS
        if !config.enabled {
            try? MagSafeLED.set(.system)
            log.info("started disabled, LED under macOS control")
        }
    }

    private func saveConfig(_ config: DaemonConfig) {
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .xml
            let data = try encoder.encode(config)
            // Atomic write so a concurrent reader (the app's refresh timer)
            // never observes a partially-written plist.
            try data.write(to: URL(fileURLWithPath: MagSleep.configFilePath), options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: MagSleep.configFilePath
            )
        } catch {
            log.error("failed to save config: \(error)")
        }
    }

    // MARK: - Request File (event-driven via directory watch)

    private func armRequestDirectoryWatch() {
        requestDirSource?.cancel()
        let fd = open(MagSleep.requestDirectory, O_EVTONLY)
        guard fd >= 0 else {
            log.error("cannot watch request directory (errno \(errno))")
            return
        }
        requestDirFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // If /tmp/magsleep was deleted and recreated out from under us, the
            // old fd watches an unlinked inode and would never fire again —
            // requests would be silently dropped. Re-arm against the live path.
            self.rearmIfWatchStale()
            self.processRequestFile()
            // The app writes the request atomically (temp file + rename). If the
            // watch fires before the rename completes we may read an empty file;
            // re-check shortly after so the request is not silently dropped.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.processRequestFile()
            }
        }
        source.setCancelHandler { [weak self] in
            close(fd)
            if self?.requestDirFD == fd {
                self?.requestDirFD = -1
            }
        }
        source.resume()
        requestDirSource = source
        log.info("watching request directory")
    }

    /// Re-arms the directory watch when the watched inode no longer matches the
    /// live path (directory deleted and recreated, e.g. /tmp cleaned by a
    /// third-party tool). Also recreates a missing directory so the app's next
    /// request lands somewhere we are watching.
    private func rearmIfWatchStale() {
        var watched = stat()
        if fstat(requestDirFD, &watched) != 0 {
            armRequestDirectoryWatch()
            return
        }
        var current = stat()
        if stat(MagSleep.requestDirectory, &current) != 0 {
            ensureRequestDirectory()
            armRequestDirectoryWatch()
            return
        }
        if current.st_dev != watched.st_dev || current.st_ino != watched.st_ino {
            armRequestDirectoryWatch()
        }
    }

    private func processRequestFile() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: MagSleep.requestFilePath) else {
            return
        }

        guard let mtime = attributes[.modificationDate] as? Date,
              mtime.timeIntervalSince1970 > requestFileLastModified else {
            return
        }

        guard let command = try? String(contentsOfFile: MagSleep.requestFilePath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else {
            return
        }

        log.info("processing request: \(command)")
        requestFileLastModified = mtime.timeIntervalSince1970

        switch command {
        case "mode:sleep":
            config.mode = .sleep
            config.enabled = true
            saveConfig(config)
            applyMode()
        case "mode:alwaysOff":
            config.mode = .alwaysOff
            config.enabled = true
            saveConfig(config)
            applyMode()
        case "enable":
            config.enabled = true
            saveConfig(config)
            applyMode()
        case "disable":
            config.enabled = false
            saveConfig(config)
            applyMode()
            log.info("disabled, LED under macOS control")
        default:
            log.error("unknown request: \(command)")
        }

        // Remove the request file only if it hasn't been replaced since we read
        // it — otherwise we'd delete a newer request before it was processed.
        if let current = try? FileManager.default.attributesOfItem(atPath: MagSleep.requestFilePath),
           let currentMtime = current[.modificationDate] as? Date,
           currentMtime.timeIntervalSince1970 == mtime.timeIntervalSince1970 {
            try? FileManager.default.removeItem(atPath: MagSleep.requestFilePath)
        }
    }

    // MARK: - Mode Application

    /// Computes the desired LED color and writes it. Called on sleep/wake events,
    /// on requests, and on power-source changes (to re-assert alwaysOff across
    /// external LED changes like plug-in / charging-state updates).
    private func applyMode() {
        let smc: SMC.Connection
        if let existing = self.smc {
            smc = existing
        } else {
            do {
                smc = try SMC.Connection()
                self.smc = smc
            } catch {
                logThrottled("SMC connection failed: \(error)")
                return
            }
        }

        let target: MagSafeLED.Color
        if !config.enabled {
            target = .system
        } else {
            switch config.mode {
            case .sleep:
                target = isSleeping ? .off : .system
            case .alwaysOff:
                target = .off
            }
        }

        do {
            try MagSafeLED.set(target, using: smc)
        } catch {
            logThrottled("failed to apply mode: \(error)")
        }
    }

    /// Logs SMC failures without spamming the unified log on every 3s tick.
    private func logThrottled(_ message: String) {
        guard message != lastSMCLog else { return }
        lastSMCLog = message
        log.error("\(message, privacy: .public)")
    }

    // MARK: - Power Notifications (event-driven sleep/wake detection)

    private func registerForPowerNotifications() {
        let callback: IOServiceInterestCallback = { refcon, _, messageType, messageArgument in
            guard let refcon else { return }
            let daemon = Unmanaged<PowerDaemon>.fromOpaque(refcon).takeUnretainedValue()
            daemon.handlePowerMessage(messageType: messageType, argument: messageArgument)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(
            selfPtr,
            &notificationPort,
            callback,
            &notifierObject
        )
        guard rootPort != 0, let notificationPort else {
            log.error("IORegisterForSystemPower failed")
            exit(1)
        }

        let runLoopSource = IONotificationPortGetRunLoopSource(notificationPort).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        log.info("registered for system power notifications")
    }

    private func handlePowerMessage(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        let notificationID = Int(bitPattern: argument)

        switch messageType {
        case PowerMessage.canSystemSleep:
            // Acknowledge so the system can proceed to sleep.
            IOAllowPowerChange(rootPort, notificationID)

        case PowerMessage.systemWillSleep:
            log.info("system will sleep; turning MagSafe LED off")
            isSleeping = true
            applyMode()
            IOAllowPowerChange(rootPort, notificationID)

        case PowerMessage.systemHasPoweredOn:
            log.info("system woke; handing MagSafe LED back to macOS")
            isSleeping = false
            applyMode()

        default:
            break
        }
    }

    // MARK: - Power Source Changes (event-driven alwaysOff re-assert)

    private func registerForPowerSourceChanges() {
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let daemon = Unmanaged<PowerDaemon>.fromOpaque(context).takeUnretainedValue()
            daemon.onPowerSourceChange()
        }

        guard let source = IOPSNotificationCreateRunLoopSource(
            callback,
            Unmanaged.passUnretained(self).toOpaque()
        )?.takeRetainedValue() else {
            log.error("failed to register for power source changes")
            return
        }
        powerSourceSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        log.info("registered for power source changes")
    }

    private func onPowerSourceChange() {
        // Re-assert the active mode; macOS may change the LED on plug/unplug
        // (alwaysOff must win over the charging indicator).
        applyMode()
    }

    // MARK: - Signal Handlers

    private func setupSignalHandlers() {
        // Use dispatch signal sources (not raw signal()) so the handler runs
        // in a normal dispatch context where IOKit/SMC calls are safe.
        let queue = DispatchQueue.main
        for signo in [SIGINT, SIGTERM] {
            signal(signo, SIG_IGN) // suppress default termination; source handles it
            let source = DispatchSource.makeSignalSource(signal: signo, queue: queue)
            source.setEventHandler { [weak self] in
                self?.shutdown()
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Restore LED to macOS control and exit non-zero so launchd's KeepAlive
    /// ({ SuccessfulExit: false }) revives the daemon whenever it is killed.
    /// Sequence on `launchctl kill`: LED returns to macOS control for a few
    /// seconds, launchd restarts the daemon, and it re-applies the active mode.
    /// bootout during install/uninstall unloads the job regardless of exit
    /// code, so those flows still stop it permanently.
    private func shutdown() {
        log.info("shutting down, restoring LED to macOS control")
        try? MagSafeLED.set(.system)
        exit(1)
    }

    // MARK: - Re-assert Timer

    private func startReassertTimer() {
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            self?.reassertActiveMode()
        }
        RunLoop.main.add(timer, forMode: .default)
        reassertTimer = timer
    }

    /// Periodic re-assert of the active mode. Skipped entirely while disabled:
    /// the LED belongs to macOS then, and the only SMC write needed is the
    /// one-shot `.system` transition done by `applyMode()` on the disable
    /// request. This keeps SMC traffic at zero when MagSleep is off.
    private func reassertActiveMode() {
        guard config.enabled else { return }
        applyMode()
    }

    // MARK: - Sleep/Wake Detection (startup seed only)

    /// Heuristic used once at startup to seed `isSleeping` (covers the case
    /// where launchd revives us while the Mac is still asleep). Not used for
    /// ongoing detection — that comes from IORegisterForSystemPower events.
    private func isSystemSleeping() -> Bool {
        let sleepFile = "/private/var/vm/sleepimage"
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: sleepFile) else {
            return false
        }
        guard let mtime = attributes[.modificationDate] as? Date else {
            return false
        }
        // If sleepimage was modified recently (within last 30 seconds), consider system sleeping
        return Date().timeIntervalSince(mtime) < 30
    }
}

// One-shot: restore the LED to macOS control and exit (uninstall/disable path).
if CommandLine.arguments.contains("--reset") {
    try? MagSafeLED.set(.system)
    exit(0)
}

PowerDaemon().run()

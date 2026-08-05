import Foundation
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import MagSleepCore
import os.log
import SystemConfiguration

/// magsleep-helper: privileged daemon that controls the MagSafe LED.
/// Runs as root via LaunchDaemon.
///
/// Behavior:
/// - Turns the MagSafe LED off when the Mac sleeps, restores macOS control on wake
/// - Serves app requests over a unix-domain socket (`MagSleep.socketPath`):
///   one connection per request, request/ack/error, no polling
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

    private var rootPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifierObject: io_object_t = 0
    private var signalSources: [DispatchSourceSignal] = []
    private var socketServer: SocketServer?
    // periphery:ignore - retained for lifetime (the run loop also holds these,
    // but the stored reference keeps them alive deterministically); never read.
    private var powerSourceSource: CFRunLoopSource?
    // periphery:ignore - see `powerSourceSource`.
    private var reassertTimer: Timer?
    /// Persistent SMC connection (opened lazily on first apply; retried on failure).
    private var smc: SMC.Connection?
    /// Throttles repeated SMC failure logs to one per distinct message.
    private var lastSMCLog: String?

    func run() {
        log.info("starting")

        // A client can disconnect while we are writing our response; without
        // this, SIGPIPE would take the daemon down (launchd would revive it,
        // but the LED would flicker on every occurrence).
        signal(SIGPIPE, SIG_IGN)

        // Ensure the config directory exists and load the config (or defaults)
        ensureConfigDirectory()
        loadConfig()

        // Seed the sleep state for the rare case where we're revived (launchd
        // KeepAlive) while the Mac is still asleep; power events keep it
        // accurate afterwards.
        isSleeping = isSystemSleeping()

        // Set up signal handlers, system power notifications, and the request
        // socket (app → daemon IPC, one connection per request).
        setupSignalHandlers()
        registerForPowerNotifications()
        startSocketServer()
        registerForPowerSourceChanges()

        // Slow re-assert timer: guarantees the LED converges back to the active
        // mode within a few seconds even if macOS changes it after our
        // event-driven writes (e.g. plug/unplug flips the LED to show charging).
        // A single-byte SMC write every 3s is negligible; mode-change latency is
        // unaffected (requests are still applied instantly via the socket).
        startReassertTimer()

        // Run the run loop; all events fire here.
        RunLoop.main.run()
    }

    private func startSocketServer() {
        let server = SocketServer(path: MagSleep.socketPath) { [weak self] line, peerUID in
            self?.handleSocketRequest(line, peerUID: peerUID) ?? ""
        }
        if server.start() {
            socketServer = server
        } else {
            log.error("failed to start socket server")
        }
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

    private func loadConfig() {
        let url = URL(fileURLWithPath: MagSleep.configFilePath)
        let exists = FileManager.default.fileExists(atPath: url.path)

        config = DaemonConfig.load(from: url)
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

    // MARK: - Socket Requests (app → daemon IPC)

    private func handleSocketRequest(_ line: String, peerUID: uid_t?) -> String {
        guard let request = SocketRequest.parseLine(line) else {
            return SocketResponse(id: "", ok: false, config: nil, error: "malformed request").encodeLine()
        }
        guard let peerUID = peerUID, isAllowedPeer(peerUID) else {
            if let peerUID {
                log.error("rejected request from uid \(peerUID, privacy: .public)")
            } else {
                log.error("rejected request: could not determine peer uid")
            }
            return SocketResponse(id: request.id, ok: false, config: nil, error: "unauthorized").encodeLine()
        }
        log.info("processing request: \(request.cmd, privacy: .public)")
        if config.apply(request.cmd) {
            saveConfig(config)
            applyMode()
            if !config.enabled {
                log.info("disabled, LED under macOS control")
            }
            return SocketResponse(id: request.id, ok: true, config: config, error: nil).encodeLine()
        }
        log.error("unknown request: \(request.cmd, privacy: .public)")
        return SocketResponse(id: request.id, ok: false, config: nil, error: "unknown command").encodeLine()
    }

    /// Accepts requests from root and from the current console user only.
    /// Fails closed: an undeterminable console user rejects the request rather
    /// than authorizing an arbitrary local process on the 0666 socket.
    private func isAllowedPeer(_ peerUID: uid_t) -> Bool {
        if peerUID == 0 { return true }
        var consoleUID: uid_t = 0
        var consoleGID: gid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &consoleUID, &consoleGID) != nil else { return false }
        return peerUID == consoleUID
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

        let target = LEDTarget.color(for: config, isSleeping: isSleeping)

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
        // While disabled the LED belongs entirely to macOS — no SMC traffic.
        guard config.enabled else { return }
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
        socketServer?.stop()
        try? MagSafeLED.set(.system)
        exit(1)
    }

    // MARK: - Re-assert Timer

    private func startReassertTimer() {
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            self?.reassertActiveMode()
            // Cheap stat; rebinds the socket if /var/run was cleaned out.
            self?.socketServer?.ensureSocketFileExists()
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
        // While awake in Sleep Mode the LED is already under macOS control
        // (the target is .system); re-writing it every tick is pure SMC churn
        // (~28,800 writes/day). Only Always Off needs the watchdog (macOS
        // flips the LED on plug/unplug), plus the window while the Mac is
        // asleep in Sleep Mode.
        if config.mode == .sleep && !isSleeping { return }
        applyMode()
    }

    // MARK: - Sleep/Wake Detection (startup seed only)

    /// Heuristic used once at startup to seed `isSleeping` (covers the case
    /// where launchd revives us while the Mac is still asleep). Not used for
    /// ongoing detection — that comes from IORegisterForSystemPower events.
    /// Cross-checked against the live power state to avoid the false positive
    /// of a revive shortly after wake (LED forced off while the Mac is awake).
    private func isSystemSleeping() -> Bool {
        let sleepFile = "/private/var/vm/sleepimage"
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: sleepFile),
              let mtime = attributes[.modificationDate] as? Date else {
            return false
        }
        // If sleepimage was modified recently (within last 30 seconds), consider system sleeping
        let heuristic = Date().timeIntervalSince(mtime) < 30
        return currentSystemPowerState() ?? heuristic
    }

    /// Reads the current system power state from the dynamic store. Returns
    /// `true` when the system is asleep, `false` when awake, and `nil` when
    /// the state cannot be determined (so callers fall back to their own
    /// heuristic).
    private func currentSystemPowerState() -> Bool? {
        let key = "State:/IOKit/PowerManagement/CurrentSystemPower" as CFString
        guard let store = SCDynamicStoreCreate(nil, "com.magsleep.helper.power" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, key),
              let dict = value as? [String: Any],
              let asleep = dict["System Sleep"] as? Bool else {
            return nil
        }
        return asleep
    }
}

/// Entry point. Using `@main` (instead of top-level code) lets Periphery
/// trace the real entry point, so the daemon's members are not reported as
/// dead code.
@main
enum MagSleepHelperMain {
    static func main() {
        // One-shot: restore the LED to macOS control and exit
        // (uninstall/disable path).
        if CommandLine.arguments.contains("--reset") {
            try? MagSafeLED.set(.system)
            exit(0)
        }
        PowerDaemon().run()
    }
}

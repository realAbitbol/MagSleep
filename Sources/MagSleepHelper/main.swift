import Foundation
import IOKit
import IOKit.pwr_mgt
import MagSleepCore
import os

/// magsleep-helper — root launchd daemon.
///
/// Turns the MagSafe LED off when the Mac goes to sleep, and hands control
/// back to macOS on wake.
///
/// Flags:
///   --reset   write ACLC = 0 and exit (used by disable/uninstall)
///   --off     write ACLC = 1 and exit (sanity check)
///   --probe   print whether this Mac exposes ACLC

let log = Logger(subsystem: "com.magsleep.helper", category: "helper")

if CommandLine.arguments.contains("--reset") {
    do {
        try MagSafeLED.set(.system)
        print("MagSafe LED handed back to macOS")
        exit(0)
    } catch {
        print("reset failed: \(error)")
        exit(1)
    }
}

if CommandLine.arguments.contains("--off") {
    do {
        try MagSafeLED.set(.off)
        print("MagSafe LED off")
        exit(0)
    } catch {
        print("off failed: \(error)")
        exit(1)
    }
}

if CommandLine.arguments.contains("--probe") {
    do {
        let info = try SMC.keyInfo(MagSafeLED.key)
        print("ACLC present: size=\(info.size) type=\(info.type)")
        if let color = try MagSafeLED.current() {
            print("current: \(color)")
        } else {
            print("current: unrecognized byte")
        }
    } catch {
        print("ACLC probe failed: \(error)")
        exit(1)
    }
    exit(0)
}

/// IOKit power message IDs (C macros are not imported into Swift).
/// Values from IOMessage.h via `iokit_common_msg(...)`.
private enum PowerMessage {
    static let canSystemSleep: UInt32 = 0xe0000270
    static let systemWillSleep: UInt32 = 0xe0000280
    static let systemHasPoweredOn: UInt32 = 0xe0000300
}

final class PowerDaemon {
    private var rootPort: io_connect_t = 0
    private var notifierObject: io_object_t = 0
    private var notificationPort: IONotificationPortRef?
    private var signalSources: [DispatchSourceSignal] = []

    func run() {
        log.info("magsleep-helper starting")
        installSignalHandlers()
        registerForPowerNotifications()
        RunLoop.main.run()
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                log.info("shutting down; handing LED back to macOS")
                try? MagSafeLED.set(.system)
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

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
            IOAllowPowerChange(rootPort, notificationID)

        case PowerMessage.systemWillSleep:
            log.info("system will sleep; MagSafe LED off")
            do {
                try MagSafeLED.set(.off)
            } catch {
                log.error("failed to turn LED off: \(String(describing: error), privacy: .public)")
            }
            IOAllowPowerChange(rootPort, notificationID)

        case PowerMessage.systemHasPoweredOn:
            log.info("system woke; handing MagSafe LED back to macOS")
            do {
                try MagSafeLED.set(.system)
            } catch {
                log.error("failed to restore LED: \(String(describing: error), privacy: .public)")
            }

        default:
            break
        }
    }
}

PowerDaemon().run()

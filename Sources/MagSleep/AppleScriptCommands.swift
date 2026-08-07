import AppKit
import MagSleepCore

// MARK: - Synchronous socket bridge

/// AppleScript commands run synchronously on the main thread, but the socket
/// send must not hop back to the main queue to deliver its result (a
/// main-thread semaphore wait would then deadlock). Send off-main and wait.
private func sendLEDCommand(_ command: String) -> (ok: Bool, error: String?) {
    var ok = false
    var errorMessage: String?
    let semaphore = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        do {
            let response = try HelperConnection.send(command)
            ok = response.ok
            if !ok {
                errorMessage = response.error
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Could not communicate with helper"
        }
        semaphore.signal()
    }
    semaphore.wait()
    return (ok, errorMessage)
}

private extension NSScriptCommand {
    /// Records an AppleScript error and returns nil (the script-failure path).
    func scriptFailure(_ message: String, code: Int = -1700) -> Any? {
        scriptErrorNumber = code
        scriptErrorString = message
        return nil
    }
}

// MARK: - sdef command handlers
// The classes below are discovered by name from packaging/MagSleep.sdef
// (`cocoa class="…"`), never referenced from app code — hence periphery:ignore.

// sdef: `set led mode <sleep|alwaysOff|disabled>`
// periphery:ignore - instantiated by AppKit from the sdef
@objc(SetLEDModeCommand)
final class SetLEDModeCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let raw = directParameter as? String else {
            return scriptFailure("Expected a mode: sleep, alwaysOff, or disabled.")
        }
        guard let mode = LEDMode(rawValue: raw) else {
            return scriptFailure("Unknown mode '\(raw)'; expected sleep, alwaysOff, or disabled.")
        }
        let (ok, error) = sendLEDCommand(mode.socketCommand)
        guard ok else { return scriptFailure(error ?? "The helper rejected the request") }
        return nil
    }
}

// sdef: `turn LED off`
// periphery:ignore - instantiated by AppKit from the sdef
@objc(TurnLEDOffCommand)
final class TurnLEDOffCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let (ok, error) = sendLEDCommand(LEDMode.alwaysOff.socketCommand)
        guard ok else { return scriptFailure(error ?? "The helper rejected the request") }
        return nil
    }
}

// sdef: `turn LED on`
// periphery:ignore - instantiated by AppKit from the sdef
@objc(TurnLEDOnCommand)
final class TurnLEDOnCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let (ok, error) = sendLEDCommand(LEDMode.disabled.socketCommand)
        guard ok else { return scriptFailure(error ?? "The helper rejected the request") }
        return nil
    }
}

// sdef: `get led status`
// periphery:ignore - instantiated by AppKit from the sdef
@objc(GetLEDStatusCommand)
final class GetLEDStatusCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        // Reuse one HelperManager instead of creating a fresh one per query
        // (its init performs a blocking socket probe on the main thread).
        // Refresh from the config file only — no probe — so the status is
        // current without stalling the UI.
        let helper = ScriptStatusHelper.shared
        helper.refreshFromDisk()
        return helper.statusDescription
    }
}

/// Shared status source for the AppleScript bridge.
private enum ScriptStatusHelper {
    static let shared = HelperManager()
}

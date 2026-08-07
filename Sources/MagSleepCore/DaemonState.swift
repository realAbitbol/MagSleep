import Foundation

/// Commands the app can send to the daemon (via the socket protocol).
/// The single source of the wire vocabulary: `DaemonConfig.apply` parses them,
/// `LEDMode.socketCommand` produces the mode ones, and the app + daemon both
/// reference the rest — so the two sides can never drift.
public enum RequestCommand {
    public static let modeSleep = "mode:sleep"
    public static let modeAlwaysOff = "mode:alwaysOff"
    public static let enable = "enable"
    public static let disable = "disable"
    public static let nightScheduleOn = "nightschedule:on"
    public static let nightScheduleOff = "nightschedule:off"
}

extension DaemonConfig {
    /// Applies a request command to the config, returning whether the command
    /// was recognized. Unknown commands leave the config unchanged.
    @discardableResult
    public mutating func apply(_ command: String) -> Bool {
        switch command {
        case RequestCommand.modeSleep:
            mode = .sleep
            enabled = true
            return true
        case RequestCommand.modeAlwaysOff:
            mode = .alwaysOff
            enabled = true
            return true
        case RequestCommand.enable:
            enabled = true
            return true
        case RequestCommand.disable:
            enabled = false
            return true
        case RequestCommand.nightScheduleOn:
            nightScheduleEnabled = true
            return true
        case RequestCommand.nightScheduleOff:
            nightScheduleEnabled = false
            return true
        default:
            return false
        }
    }

    /// Loads the config from disk, falling back to `DaemonConfig.default` on
    /// any error (missing/corrupt file, unknown mode, missing keys).
    public static func load(from url: URL) -> DaemonConfig {
        guard let data = try? Data(contentsOf: url),
              let config = try? PropertyListDecoder().decode(DaemonConfig.self, from: data) else {
            return .default
        }
        return config
    }
}

/// Pure LED-target decision shared by the daemon's mode application.
/// Kept in the core library so it can be unit-tested.
public enum LEDTarget {
    public static func color(
        for config: DaemonConfig,
        isSystemSleeping: Bool,
        isDisplayAsleep: Bool,
        isNight: Bool
    ) -> MagSafeLED.Color {
        // Disabled always wins: the LED belongs to macOS entirely.
        if !config.enabled {
            return .system
        }
        // Night schedule: LED forced off between sunset and sunrise, even awake.
        if config.nightScheduleEnabled && isNight {
            return .off
        }
        switch config.mode {
        case .sleep:
            // Off while the system OR just the display sleeps; macOS control
            // when both are awake.
            return (isSystemSleeping || isDisplayAsleep) ? .off : .system
        case .alwaysOff:
            return .off
        }
    }
}

import Foundation

/// Commands the app can send to the daemon (via the socket protocol).
public enum RequestCommand {
    public static let modeSleep = "mode:sleep"
    public static let modeAlwaysOff = "mode:alwaysOff"
    public static let enable = "enable"
    public static let disable = "disable"
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
    public static func color(for config: DaemonConfig, isSleeping: Bool) -> MagSafeLED.Color {
        if !config.enabled {
            return .system
        }
        switch config.mode {
        case .sleep:
            return isSleeping ? .off : .system
        case .alwaysOff:
            return .off
        }
    }
}

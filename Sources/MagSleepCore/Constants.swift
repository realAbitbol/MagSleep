import Foundation

public enum MagSleep {
    public static let helperLabel = "com.magsleep.helper"
    public static let helperBinaryPath = "/Library/PrivilegedHelperTools/\(helperLabel)"
    public static let helperPlistPath = "/Library/LaunchDaemons/\(helperLabel).plist"
    public static let coffeeURL = URL(string: "https://ko-fi.com/realabitbol")!

    /// Directory and file used to store persistent configuration (mode, etc.).
    /// Owned by root; read by the helper daemon, written by the helper daemon.
    public static let configDirectory = "/Library/Preferences/MagSleep"
    public static let configFilePath = "\(configDirectory)/config.plist"

    /// Unix-domain socket used for app → daemon IPC (request + ack + errors).
    /// Created by the daemon (root); the app connects as the console user.
    public static let socketPath = "/var/run/magsleep.sock"

    /// Maximum accepted IPC message size (bytes). The daemon closes
    /// connections whose requests exceed it; the client reads responses up to
    /// twice this (the shared single source, so both sides can't drift).
    public static let maxMessageBytes = 4096

    /// File storing the app version of the currently installed helper.
    public static let helperVersionFilePath = "\(configDirectory)/helper-version.txt"
}

/// Operation modes for MagSleep (user's preferred active mode).
public enum OperationMode: String, Codable, Equatable {
    /// Turn LED off on sleep, restore to macOS on wake.
    case sleep

    /// Keep the MagSafe LED off at all times while MagSleep is enabled.
    case alwaysOff
}

/// Configuration structure shared between the app and the helper daemon.
public struct DaemonConfig: Codable, Equatable {
    public var mode: OperationMode
    public var enabled: Bool
    /// Night schedule: LED forced off from sunset to sunrise (single toggle).
    /// Added in v1.3 — optional in the plist so existing configs keep decoding
    /// (missing key defaults to false).
    public var nightScheduleEnabled: Bool

    public init(mode: OperationMode = .sleep, enabled: Bool = true, nightScheduleEnabled: Bool = false) {
        self.mode = mode
        self.enabled = enabled
        self.nightScheduleEnabled = nightScheduleEnabled
    }

    public static let `default` = DaemonConfig()

    enum CodingKeys: String, CodingKey {
        case mode
        case enabled
        case nightScheduleEnabled
    }

    /// `mode` and `enabled` stay required (missing → decode failure → caller
    /// falls back to `.default`, preserving existing behavior); the new
    /// `nightScheduleEnabled` key defaults to false when absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(OperationMode.self, forKey: .mode)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        nightScheduleEnabled = try container.decodeIfPresent(Bool.self, forKey: .nightScheduleEnabled) ?? false
    }
}

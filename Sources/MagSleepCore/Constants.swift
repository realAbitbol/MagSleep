import Foundation

public enum MagSleep {
    public static let helperLabel = "com.magsleep.helper"
    public static let helperBinaryPath = "/Library/PrivilegedHelperTools/\(helperLabel)"
    public static let helperPlistPath = "/Library/LaunchDaemons/\(helperLabel).plist"
    public static let logDirectory = "/Library/Logs/MagSleep"
    public static let coffeeURL = URL(string: "https://ko-fi.com/realabitbol")!
    public static let bundledHelperName = "magsleep-helper"

    /// Directory and file used to store persistent configuration (mode, etc.).
    /// Owned by root; read by the helper daemon, written by the helper daemon.
    public static let configDirectory = "/Library/Preferences/MagSleep"
    public static let configFilePath = "\(configDirectory)/config.plist"

    /// Request file: app writes commands (mode change, enable, disable) here;
    /// the daemon watches the directory and processes requests immediately.
    /// No admin needed.
    public static let requestDirectory = "/tmp/magsleep"
    public static let requestFilePath = "\(requestDirectory)/request"

    /// File storing the app version of the currently installed helper.
    public static let helperVersionFilePath = "\(configDirectory)/helper-version.txt"
}

/// Operation modes for MagSleep (user's preferred active mode).
public enum OperationMode: String, Codable {
    /// Turn LED off on sleep, restore to macOS on wake.
    case sleep

    /// Keep the MagSafe LED off at all times while MagSleep is enabled.
    case alwaysOff
}

/// Configuration structure shared between the app and the helper daemon.
public struct DaemonConfig: Codable {
    public var mode: OperationMode
    public var enabled: Bool

    public init(mode: OperationMode = .sleep, enabled: Bool = true) {
        self.mode = mode
        self.enabled = enabled
    }

    public static let `default` = DaemonConfig(mode: .sleep, enabled: true)
}

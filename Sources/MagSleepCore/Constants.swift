import Foundation

public enum MagSleep {
    public static let helperLabel = "com.magsleep.helper"
    public static let helperBinaryPath = "/Library/PrivilegedHelperTools/\(helperLabel)"
    public static let helperPlistPath = "/Library/LaunchDaemons/\(helperLabel).plist"
    public static let logDirectory = "/Library/Logs/MagSleep"
    public static let coffeeURL = URL(string: "https://ko-fi.com/realabitbol")!
    public static let bundledHelperName = "magsleep-helper"
}

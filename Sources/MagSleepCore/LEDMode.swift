/// The three states a user can select for the MagSafe LED — the user-facing
/// concept, shared by the menu, Shortcuts, and AppleScript so the
/// mode→command mapping can never drift. The daemon config itself uses
/// `OperationMode` plus an `enabled` flag: `.disabled` here is that flag off.
public enum LEDMode: String, Codable, Equatable {
    case sleep
    case alwaysOff
    case disabled

    /// The socket command that applies this mode (daemon protocol). Pinned to
    /// the same `RequestCommand` constants the daemon's parser switches on, so
    /// the client producer and the daemon vocabulary cannot drift.
    public var socketCommand: String {
        switch self {
        case .sleep: return RequestCommand.modeSleep
        case .alwaysOff: return RequestCommand.modeAlwaysOff
        case .disabled: return RequestCommand.disable
        }
    }

    /// The matching `OperationMode`, or nil for `.disabled` (which is the
    /// `enabled = false` flag rather than a mode value).
    public var operationMode: OperationMode? {
        switch self {
        case .sleep: return .sleep
        case .alwaysOff: return .alwaysOff
        case .disabled: return nil
        }
    }
}

/// Human-readable LED status shared by Shortcuts and AppleScript, kept pure so
/// both surfaces report identical strings.
public enum LEDStatusDescription {
    public static func describe(
        isInstalled: Bool,
        isLoaded: Bool,
        isEnabled: Bool,
        mode: OperationMode
    ) -> String {
        if !isInstalled { return "not installed" }
        if !isLoaded { return "helper not running" }
        if !isEnabled { return "disabled (macOS control)" }
        return mode == .sleep ? "sleep mode" : "always off"
    }
}

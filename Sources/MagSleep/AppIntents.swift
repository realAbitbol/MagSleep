import AppIntents
import MagSleepCore

/// Shortcuts (App Intents) surface for MagSleep.
///
/// All intents route through `HelperManager`'s socket requests — the same path
/// the menu items use — so no daemon change is needed. Shortcuts performs
/// intents in the app's own process; each `perform` uses a fresh `HelperManager`
/// that re-probes the daemon, so state is never stale.
enum MagSleepIntentSupport {
    enum IntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
        case helperNotInstalled
        case requestFailed(String)

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .helperNotInstalled:
                "The MagSleep helper is not installed."
            case .requestFailed(let detail):
                "The MagSleep helper rejected the request: \(detail)"
            }
        }
    }

    /// Shortcuts parameter type. `LEDMode` (MagSleepCore) itself can't conform
    /// to `AppEnum` from this module — Swift 6 forbids retroactive
    /// Sendable/CaseIterable conformance across files — so this thin AppEnum
    /// bridges to it; the mode→command mapping still lives once in `LEDMode`.
    enum Mode: String, AppEnum {
        case sleep
        case alwaysOff
        case disabled

        static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mode"

        static let caseDisplayRepresentations: [Mode: DisplayRepresentation] = [
            .sleep: "Sleep Mode",
            .alwaysOff: "Always Off",
            .disabled: "Disabled",
        ]

        var ledMode: LEDMode {
            LEDMode(rawValue: rawValue)!
        }
    }

    /// Applies the requested mode over the socket and returns the daemon's ack.
    static func apply(_ mode: Mode) async throws {
        let helper = HelperManager()
        guard helper.isInstalled else { throw IntentError.helperNotInstalled }

        let ok: Bool = await withCheckedContinuation { continuation in
            helper.apply(mode.ledMode) { continuation.resume(returning: $0) }
        }
        guard ok else {
            throw IntentError.requestFailed(helper.lastError ?? "unknown error")
        }
    }
}

/// "Set LED Mode" — picks Sleep Mode, Always Off, or Disabled.
struct SetLEDModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set LED Mode"
    static let description: IntentDescription? = IntentDescription(
        "Sets how the MagSafe LED behaves: Sleep Mode, Always Off, or Disabled."
    )

    @Parameter(title: "Mode")
    var mode: MagSleepIntentSupport.Mode

    static var parameterSummary: some ParameterSummary {
        Summary("Set LED mode to \(\.$mode)")
    }

    func perform() async throws -> some IntentResult {
        try await MagSleepIntentSupport.apply(mode)
        return .result()
    }
}

/// "Turn LED Off" — Always Off mode (LED stays off at all times).
struct TurnLEDOffIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn LED Off"
    static let description: IntentDescription? = IntentDescription(
        "Turns the MagSafe LED off at all times (Always Off mode)."
    )

    func perform() async throws -> some IntentResult {
        try await MagSleepIntentSupport.apply(.alwaysOff)
        return .result()
    }
}

/// "Turn LED On" — Disabled mode (macOS controls the LED again).
struct TurnLEDOnIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn LED On"
    static let description: IntentDescription? = IntentDescription(
        "Returns the MagSafe LED to macOS control (Disables MagSleep's LED handling)."
    )

    func perform() async throws -> some IntentResult {
        try await MagSleepIntentSupport.apply(.disabled)
        return .result()
    }
}

/// "Get LED Status" — reports how the LED is currently managed.
struct LEDStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get LED Status"
    static let description: IntentDescription? = IntentDescription(
        "Reports how the MagSafe LED is currently managed."
    )

    func perform() async throws -> some IntentResult {
        let helper = HelperManager()
        return .result(value: helper.statusDescription)
    }
}

// periphery:ignore - discovered by AppKit at launch (AppShortcutsProvider is
// never referenced from app code); the Shortcuts app lists these.
/// Registers the app's shortcuts so they appear in the Shortcuts app.
struct MagSleepShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SetLEDModeIntent(),
            phrases: [
                "Set \(\.$mode) mode with \(.applicationName)",
                "Change the LED to \(\.$mode) with \(.applicationName)",
            ],
            shortTitle: "Set LED Mode",
            systemImageName: "bolt.slash"
        )
        AppShortcut(
            intent: TurnLEDOffIntent(),
            phrases: ["Turn off the LED with \(.applicationName)"],
            shortTitle: "Turn LED Off",
            systemImageName: "moon.zzz"
        )
        AppShortcut(
            intent: TurnLEDOnIntent(),
            phrases: ["Turn on the LED with \(.applicationName)"],
            shortTitle: "Turn LED On",
            systemImageName: "bolt"
        )
        AppShortcut(
            intent: LEDStatusIntent(),
            phrases: [
                "Get LED status with \(.applicationName)",
                "What is the LED status in \(.applicationName)",
            ],
            shortTitle: "Get LED Status",
            systemImageName: "info.circle"
        )
    }
}

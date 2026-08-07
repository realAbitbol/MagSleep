/// Pure outcome of a socket request dispatch: what to respond, whether to run
/// the notification blink, and the new config to persist/apply.
public struct SocketCommandOutcome {
    public let response: SocketResponse
    /// True when the daemon should run the notification blink (side effect).
    public let shouldBlink: Bool
    /// The new config to persist + apply (nil for non-config commands).
    public let newConfig: DaemonConfig?
}

/// Pure request dispatch for the daemon's socket handler — the authorization
/// boundary and command→response decision, extracted so it is unit-testable
/// (the daemon performs the side effects from the outcome).
public enum SocketCommandHandler {
    public static func handle(
        request: SocketRequest,
        isAuthorized: Bool,
        canBlink: Bool,
        currentConfig: DaemonConfig
    ) -> SocketCommandOutcome {
        guard isAuthorized else {
            return SocketCommandOutcome(
                response: SocketResponse(id: request.id, ok: false, config: nil, error: "unauthorized"),
                shouldBlink: false,
                newConfig: nil
            )
        }

        // Transient action (not a config mutation): the notification blink.
        if request.cmd == RequestCommand.blink {
            return SocketCommandOutcome(
                response: SocketResponse(
                    id: request.id,
                    ok: canBlink,
                    config: nil,
                    error: canBlink ? nil : "LED is disabled or the display is asleep"
                ),
                shouldBlink: canBlink,
                newConfig: nil
            )
        }

        var config = currentConfig
        guard config.apply(request.cmd) else {
            return SocketCommandOutcome(
                response: SocketResponse(id: request.id, ok: false, config: nil, error: "unknown command"),
                shouldBlink: false,
                newConfig: nil
            )
        }
        return SocketCommandOutcome(
            response: SocketResponse(id: request.id, ok: true, config: config, error: nil),
            shouldBlink: false,
            newConfig: config
        )
    }
}

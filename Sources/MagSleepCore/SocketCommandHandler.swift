/// Pure outcome of a socket request dispatch: what to respond and the new
/// config to persist/apply.
public struct SocketCommandOutcome {
    public let response: SocketResponse
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
        currentConfig: DaemonConfig
    ) -> SocketCommandOutcome {
        guard isAuthorized else {
            return SocketCommandOutcome(
                response: SocketResponse(id: request.id, ok: false, config: nil, error: "unauthorized"),
                newConfig: nil
            )
        }

        var config = currentConfig
        guard config.apply(request.cmd) else {
            return SocketCommandOutcome(
                response: SocketResponse(id: request.id, ok: false, config: nil, error: "unknown command"),
                newConfig: nil
            )
        }
        return SocketCommandOutcome(
            response: SocketResponse(id: request.id, ok: true, config: config, error: nil),
            newConfig: config
        )
    }
}

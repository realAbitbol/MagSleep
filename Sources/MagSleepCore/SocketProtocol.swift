import Foundation

/// Wire protocol between the MagSleep app and the privileged daemon over the
/// unix-domain socket at `MagSleep.socketPath`. One request per connection,
/// newline-delimited JSON (each message is a single line, no pretty printing).

/// Request sent by the app.
public struct SocketRequest: Codable, Equatable {
    public let id: String
    public let cmd: String

    public init(id: String, cmd: String) {
        self.id = id
        self.cmd = cmd
    }
}

/// Response sent by the daemon. `config` is present on success; `error` on
/// failure. The `id` echoes the request so callers can match replies.
public struct SocketResponse: Codable, Equatable {
    /// periphery:ignore - the daemon sets it and the client currently ignores
    /// it (kept for request/response correlation); Periphery reports assign-only.
    public let id: String
    public let ok: Bool
    public let config: DaemonConfig?
    public let error: String?

    public init(id: String, ok: Bool, config: DaemonConfig?, error: String?) {
        self.id = id
        self.ok = ok
        self.config = config
        self.error = error
    }

    /// Encodes as a single newline-terminated line. The failure fallback is a
    /// valid error response (never an unparseable sentinel like "{}", which
    /// would hang the client until its timeout).
    public func encodeLine() -> String {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(self),
           let line = String(data: data, encoding: .utf8) {
            return line + "\n"
        }
        return "{\"id\":\"\",\"ok\":false,\"config\":null,\"error\":\"internal error\"}\n"
    }

    public static func parseLine(_ line: String) -> SocketResponse? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SocketResponse.self, from: data)
    }
}

extension SocketRequest {
    public static func parseLine(_ line: String) -> SocketRequest? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SocketRequest.self, from: data)
    }
}

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

    /// Encodes as a single newline-terminated line, or "{}" on failure.
    public func encodeLine() -> String {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(self),
              let line = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return line + "\n"
    }

    public static func parseLine(_ line: String) -> SocketResponse? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SocketResponse.self, from: data)
    }

    /// Maximum accepted request size in bytes. The daemon closes connections
    /// that exceed it (defense against a broken or malicious peer).
    public static let maxMessageBytes = 4096
}

extension SocketRequest {
    public static func parseLine(_ line: String) -> SocketRequest? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SocketRequest.self, from: data)
    }
}

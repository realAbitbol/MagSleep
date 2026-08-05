import Foundation
import MagSleepCore

/// Client for the daemon's unix-domain socket (`MagSleep.socketPath`).
///
/// One request per connection: connect, send one JSON line, read one JSON line
/// back, close. All calls are synchronous with short timeouts, so they must be
/// dispatched off the main thread when the UI must stay responsive.
enum HelperConnection {
    static let connectTimeoutMs = 1000
    static let responseTimeoutMs = 2000

    enum ConnectionError: LocalizedError {
        case socketFailed
        case connectFailed
        case writeFailed
        case readFailed
        case timeout
        case decodeFailed

        var errorDescription: String? {
            switch self {
            case .socketFailed: return "Could not create a socket"
            case .connectFailed: return "Could not connect to the MagSleep helper (is it running?)"
            case .writeFailed: return "Could not write to the MagSleep helper"
            case .readFailed: return "Could not read from the MagSleep helper"
            case .timeout: return "The MagSleep helper did not respond in time"
            case .decodeFailed: return "The MagSleep helper returned an invalid response"
            }
        }
    }

    /// Sends a command and waits for the daemon's acknowledgment.
    static func send(_ command: String) throws -> SocketResponse {
        let fd = try connectSocket()
        defer { close(fd) }

        let request = SocketRequest(id: UUID().uuidString, cmd: command)
        let encoder = JSONEncoder()
        var payload = try encoder.encode(request)
        payload.append(0x0A)
        try writeAll(fd, payload)

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        let deadline = Date().addingTimeInterval(TimeInterval(responseTimeoutMs) / 1000)
        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let rc = poll(&pfd, 1, 250)
            if rc == 0 { continue } // re-check deadline
            if rc < 0 {
                if errno == EINTR { continue }
                throw ConnectionError.readFailed
            }
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                responseData.append(contentsOf: buffer[0..<n])
                if let newline = responseData.firstIndex(of: 0x0A) {
                    responseData = responseData[..<newline]
                    break
                }
                if responseData.count > SocketResponse.maxMessageBytes * 2 {
                    throw ConnectionError.decodeFailed
                }
            } else if n == 0 {
                break // daemon closed the connection
            } else if errno == EINTR {
                continue
            } else if errno != EAGAIN && errno != EWOULDBLOCK {
                throw ConnectionError.readFailed
            }
        }
        guard !responseData.isEmpty else { throw ConnectionError.timeout }

        let decoder = JSONDecoder()
        guard let response = try? decoder.decode(SocketResponse.self, from: responseData) else {
            throw ConnectionError.decodeFailed
        }
        return response
    }

    /// Cheap liveness probe: connecting successfully means the daemon is up.
    /// Never blocks for more than the connect timeout.
    static func probe() -> Bool {
        guard let fd = try? connectSocket() else { return false }
        close(fd)
        return true
    }

    // MARK: - Socket plumbing

    private static func connectSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ConnectionError.socketFailed }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let pathBytes = Array(MagSleep.socketPath.utf8)
            let count = min(pathBytes.count, raw.count - 1)
            for i in 0..<count {
                raw[i] = pathBytes[i]
            }
            raw[count] = 0
        }

        // Non-blocking connect with a short deadline so the probe never hangs.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            if errno == EINPROGRESS {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let rc = poll(&pfd, 1, Int32(connectTimeoutMs))
                if rc <= 0 || (pfd.revents & Int16(POLLERR)) != 0 {
                    close(fd)
                    throw ConnectionError.connectFailed
                }
            } else {
                close(fd)
                throw ConnectionError.connectFailed
            }
        }
        return fd
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = write(fd, base.advanced(by: sent), data.count - sent)
                if n > 0 {
                    sent += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    if poll(&pfd, 1, 1000) <= 0 {
                        throw ConnectionError.writeFailed
                    }
                } else {
                    throw ConnectionError.writeFailed
                }
            }
        }
    }
}

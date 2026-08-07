import Darwin
import Foundation

/// Shared low-level unix-socket helpers, so the client (`HelperConnection`)
/// and the daemon's server (`SocketServer`) can't drift in the fd-level
/// details (the two previously hand-copied them).
public enum UnixSocket {
    public enum Error: Swift.Error {
        case writeFailed
        case pathTooLong
    }

    /// Builds a `sockaddr_un` for a path (NUL-terminated, truncated at the
    /// platform path limit — the caller's paths are fixed constants well
    /// under it).
    public static func makeSockAddr(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let count = min(pathBytes.count, MemoryLayout.size(ofValue: addr.sun_path) - 1)
        guard count == pathBytes.count else { throw Error.pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for i in 0..<count {
                raw[i] = pathBytes[i]
            }
            raw[count] = 0
        }
        return addr
    }

    /// Writes all bytes to a fd, blocking on EAGAIN up to `pollTimeoutMs` per
    /// wait. Throws on a short write or a real error.
    @discardableResult
    public static func writeAll(_ fd: Int32, _ data: Data, pollTimeoutMs: Int32 = 1000) throws -> Int {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return 0 }
            var sent = 0
            while sent < data.count {
                let n = write(fd, base.advanced(by: sent), data.count - sent)
                if n > 0 {
                    sent += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    if poll(&pfd, 1, pollTimeoutMs) <= 0 {
                        throw Error.writeFailed
                    }
                } else {
                    throw Error.writeFailed
                }
            }
            return sent
        }
    }
}

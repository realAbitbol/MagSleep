import Foundation
import MagSleepCore
import os.log

/// Event-driven unix-domain socket server for app → daemon requests.
///
/// One connection per request: the app connects, sends a single JSON line, the
/// daemon replies with a single JSON line and closes. All I/O happens on the
/// main queue via dispatch sources (the same run-loop style as the rest of the
/// daemon). The connecting peer's uid is surfaced via `getpeereid` so the
/// daemon can reject requests from other local users.
final class SocketServer {
    private let path: String
    private let log = Logger(subsystem: "com.magsleep.helper", category: "socket")
    /// Returns the exact bytes to send back (must include the trailing newline).
    private let onRequest: (String, uid_t?) -> String

    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]
    /// Upper bound on simultaneous connections (defense against a stuck or
    /// misbehaving local peer accumulating entries).
    private let maxClients = 32
    /// Connections that do not complete a request within this window are
    /// closed by the periodic sweep (a peer that connects and stalls must not
    /// hold an fd + dispatch source forever).
    private let clientIdleTimeout: TimeInterval = 10
    private var idleSweepTimer: Timer?

    private struct Client {
        var buffer = Data()
        var source: DispatchSourceRead?
        var connectedAt = Date()
    }

    init(path: String, onRequest: @escaping (String, uid_t?) -> String) {
        self.path = path
        self.onRequest = onRequest
    }

    // MARK: - Lifecycle

    @discardableResult
    func start() -> Bool {
        guard listenFD < 0 else { return true } // already listening

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            log.error("socket() failed (errno \(errno))")
            return false
        }

        var addr: sockaddr_un
        do {
            addr = try UnixSocket.makeSockAddr(path)
        } catch {
            log.error("socket path too long")
            close(fd)
            return false
        }

        // Remove a stale socket file left by a previous run.
        unlink(path)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            log.error("bind() failed (errno \(errno))")
            close(fd)
            return false
        }
        // Any local process may connect; the daemon rejects non-console peers
        // via getpeereid in the request handler (defense in depth).
        // NOTE: must be chmod() by path — fchmod() on a unix socket fd fails
        // with EINVAL on macOS, silently leaving the bind-time 0755 mode.
        chmod(path, 0o666)

        guard listen(fd, 8) == 0 else {
            log.error("listen() failed (errno \(errno))")
            close(fd)
            return false
        }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            self?.acceptPending()
        }
        source.setCancelHandler { [weak self] in
            close(fd)
            if self?.listenFD == fd {
                self?.listenFD = -1
            }
        }
        source.resume()
        listenSource = source

        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.sweepIdleClients()
        }
        RunLoop.main.add(timer, forMode: .default)
        idleSweepTimer = timer

        log.info("listening on \(self.path, privacy: .public)")
        return true
    }

    func stop() {
        listenSource?.cancel()
        listenSource = nil
        idleSweepTimer?.invalidate()
        idleSweepTimer = nil
        for client in clients.values {
            client.source?.cancel()
        }
        clients.removeAll()
        unlink(path)
        // Reset synchronously: the dispatch cancel handler runs asynchronously,
        // and `start()` guards on `listenFD < 0`. Without this, stop()→start()
        // (the self-heal rebind path) would no-op on the stale fd and the
        // daemon would stop accepting IPC until restart.
        listenFD = -1
        log.info("stopped")
    }

    /// Re-creates the listening socket if the socket file was deleted or
    /// replaced (e.g. /var/run cleaned by a third-party tool). Cheap; call
    /// from a slow timer.
    func ensureSocketFileExists() {
        guard listenFD >= 0 else { return }
        var st = stat()
        if stat(path, &st) != 0 || (st.st_mode & S_IFMT) != S_IFSOCK {
            log.warning("socket file missing; rebinding")
            stop()
            _ = start()
        }
    }

    // MARK: - Connection handling

    private func acceptPending() {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                break // EAGAIN or another transient error; no more pending
            }
            if clients.count >= maxClients {
                log.warning("too many concurrent clients; rejecting")
                close(clientFD)
                continue
            }
            let flags = fcntl(clientFD, F_GETFL, 0)
            _ = fcntl(clientFD, F_SETFL, flags | O_NONBLOCK)

            let source = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: .main)
            source.setEventHandler { [weak self] in
                self?.readFrom(clientFD)
            }
            source.setCancelHandler {
                close(clientFD)
            }
            source.resume()
            clients[clientFD] = Client(source: source)
        }
    }

    /// Closes connections that never completed a request within the idle
    /// window, so a stalled peer cannot accumulate fds/sources indefinitely.
    private func sweepIdleClients() {
        let now = Date()
        let expired = clients
            .filter { now.timeIntervalSince($0.value.connectedAt) > clientIdleTimeout }
            .map { $0.key }
        for fd in expired {
            log.warning("closing idle client")
            closeClient(fd)
        }
    }

    private func readFrom(_ fd: Int32) {
        guard var client = clients[fd] else { return }

        var buffer = [UInt8](repeating: 0, count: 1024)
        let n = read(fd, &buffer, buffer.count)
        if n > 0 {
            client.buffer.append(contentsOf: buffer[0..<n])
            if client.buffer.count > MagSleep.maxMessageBytes {
                log.error("request too large; closing connection")
                closeClient(fd)
                return
            }
            if let newlineIndex = client.buffer.firstIndex(of: 0x0A) {
                let lineData = client.buffer[..<newlineIndex]
                let line = String(data: lineData, encoding: .utf8) ?? ""
                respond(to: fd, line: line)
                closeClient(fd)
                return
            }
            clients[fd] = client
        } else if n == 0 {
            closeClient(fd) // peer closed before sending a full line
        } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
            closeClient(fd)
        }
    }

    private func respond(to fd: Int32, line: String) {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        let hasPeer = getpeereid(fd, &peerUID, &peerGID) == 0
        let response = onRequest(line, hasPeer ? peerUID : nil)
        writeAll(fd, Data(response.utf8))
    }

    private func closeClient(_ fd: Int32) {
        guard let client = clients.removeValue(forKey: fd) else { return }
        client.source?.cancel()
    }

    private func writeAll(_ fd: Int32, _ data: Data) {
        // Best-effort (the connection is closed right after); the client side
        // of the protocol surfaces write errors instead.
        _ = try? UnixSocket.writeAll(fd, data, pollTimeoutMs: 500)
    }
}

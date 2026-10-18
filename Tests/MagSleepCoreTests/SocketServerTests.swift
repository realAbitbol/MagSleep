import Darwin
import XCTest
@testable import MagSleepCore

/// Drives a real `SocketServer` over a temp-path unix socket: accept, framing,
/// peer-uid reporting, and the oversized-request close. The server runs on a
/// dedicated serial queue so its dispatch sources fire while the test thread
/// talks to it as a client (and so the main run loop is never pumped).
final class SocketServerTests: XCTestCase {
    private enum TestError: Error {
        case connectFailed
    }

    /// A deliberately short path: `sun_path` is 104 bytes, and the macOS temp
    /// directory plus a UUID would exceed it.
    private func socketPath() -> String {
        "/tmp/mgs-\(UUID().uuidString.prefix(8)).sock"
    }

    private func startServer(
        queue: DispatchQueue,
        onRequest: @escaping (String, uid_t?) -> String
    ) -> (server: SocketServer, path: String) {
        let path = socketPath()
        let server = SocketServer(path: path, queue: queue, onRequest: onRequest)
        XCTAssertTrue(server.start(), "server should bind \(path)")
        return (server, path)
    }

    private func connectClient(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = try UnixSocket.makeSockAddr(path)
        let rc = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            close(fd)
            throw TestError.connectFailed
        }
        return fd
    }

    /// Reads a single response line, or nil when the peer closed / the deadline
    /// elapsed (so a server bug fails the test instead of hanging the suite).
    private func readLine(_ fd: Int32, timeoutMs: Int32 = 3000) -> String? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while data.firstIndex(of: 0x0A) == nil {
            let remaining = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            guard remaining > 0 else { return nil }
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pollFD, 1, remaining) > 0 else { return nil }
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break } // peer closed
            data.append(contentsOf: buffer[0..<count])
        }
        guard let newline = data.firstIndex(of: 0x0A) else { return nil }
        return String(data: data[..<newline], encoding: .utf8)
    }

    func testServesOneRequestPerConnection() throws {
        let queue = DispatchQueue(label: "test.magsleep.socket-server")
        let (server, path) = startServer(queue: queue) { line, _ in
            line == "ping" ? "pong\n" : "unexpected\n"
        }
        defer { queue.sync { server.stop() } }

        let first = try connectClient(to: path)
        try UnixSocket.writeAll(first, Data("ping\n".utf8))
        XCTAssertEqual(readLine(first), "pong")
        close(first)

        // A second connection works, and the server closes it after one reply.
        let second = try connectClient(to: path)
        try UnixSocket.writeAll(second, Data("other\n".utf8))
        XCTAssertEqual(readLine(second), "unexpected")
        XCTAssertNil(readLine(second, timeoutMs: 500), "the server must close after one request")
        close(second)
    }

    func testReassemblesARequestSplitAcrossTwoWrites() throws {
        let queue = DispatchQueue(label: "test.magsleep.socket-server.split")
        let (server, path) = startServer(queue: queue) { line, _ in "got:\(line)\n" }
        defer { queue.sync { server.stop() } }

        let fd = try connectClient(to: path)
        defer { close(fd) }
        try UnixSocket.writeAll(fd, Data("he".utf8))
        Thread.sleep(forTimeInterval: 0.2) // let the first partial read land
        try UnixSocket.writeAll(fd, Data("llo\n".utf8))
        XCTAssertEqual(readLine(fd), "got:hello")
    }

    func testReportsTheConnectingPeersUID() throws {
        let queue = DispatchQueue(label: "test.magsleep.socket-server.uid")
        var observedUID: uid_t?
        let (server, path) = startServer(queue: queue) { _, peerUID in
            observedUID = peerUID
            return "ok\n"
        }
        defer { queue.sync { server.stop() } }

        let fd = try connectClient(to: path)
        defer { close(fd) }
        try UnixSocket.writeAll(fd, Data("ping\n".utf8))
        XCTAssertEqual(readLine(fd), "ok")
        // Barrier: every handler already enqueued on the server queue has run,
        // so reading the captured uid here is synchronised with its write.
        queue.sync {}
        XCTAssertEqual(observedUID, getuid(), "getpeereid must surface the local peer's uid")
    }

    func testOversizedRequestIsClosedWithoutAResponse() throws {
        let queue = DispatchQueue(label: "test.magsleep.socket-server.oversized")
        let (server, path) = startServer(queue: queue) { _, _ in "should never be sent\n" }
        defer { queue.sync { server.stop() } }

        let fd = try connectClient(to: path)
        defer { close(fd) }
        let oversized = Data(repeating: 0x41, count: MagSleep.maxMessageBytes + 64)
        do {
            // The server may close mid-write, which is itself the expected
            // outcome — the assertion below is that no line comes back.
            try UnixSocket.writeAll(fd, oversized)
        } catch {
            // ignored: the connection was closed for exceeding the limit
        }
        XCTAssertNil(readLine(fd, timeoutMs: 2000))
    }
}

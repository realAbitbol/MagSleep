import Foundation

/// Pure framing decision for the daemon's newline-delimited socket protocol.
///
/// Extracted from `SocketServer` so the line/limit rules are unit-testable
/// without a socket: the server keeps only the fd plumbing and asks this for
/// "what did those bytes mean?". Internal to `MagSleepCore` — only the socket
/// server consumes it (`@testable` reaches it from the tests).
enum SocketFraming {
    enum Outcome: Equatable {
        /// A complete request line arrived (without its trailing newline).
        case line(String)
        /// No newline yet; keep buffering.
        case incomplete
        /// The buffered request exceeded `maxBytes` before a newline arrived.
        case tooLarge
    }

    /// Decides what to do with the bytes received so far.
    ///
    /// The size cap is checked *before* the newline (matching the long-standing
    /// behaviour): an oversized buffer is rejected even if it happens to
    /// contain a newline, so a peer cannot smuggle an unbounded line in.
    static func consume(
        buffer: Data,
        maxBytes: Int = MagSleep.maxMessageBytes
    ) -> Outcome {
        if buffer.count > maxBytes { return .tooLarge }
        guard let newline = buffer.firstIndex(of: 0x0A) else { return .incomplete }
        let lineData = buffer[..<newline]
        // Invalid UTF-8 degrades to an empty line, which the parser rejects as a
        // malformed request — never a crash.
        return .line(String(data: lineData, encoding: .utf8) ?? "")
    }
}

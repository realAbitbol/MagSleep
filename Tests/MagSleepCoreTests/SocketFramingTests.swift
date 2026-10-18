import XCTest
@testable import MagSleepCore

/// Framing rules for the newline-delimited request protocol. Previously the
/// daemon decided these inline inside its socket read handler, where no test
/// could reach them.
final class SocketFramingTests: XCTestCase {
    func testCompleteLineIsExtractedWithoutItsNewline() {
        XCTAssertEqual(SocketFraming.consume(buffer: Data(#"{"id":"a"}"#.utf8 + [0x0A])), .line(#"{"id":"a"}"#))
    }

    func testOnlyTheFirstLineIsTaken() {
        // One request per connection: bytes after the first newline are ignored.
        XCTAssertEqual(SocketFraming.consume(buffer: Data("first\nsecond\n".utf8)), .line("first"))
    }

    func testIncompleteBufferKeepsBuffering() {
        XCTAssertEqual(SocketFraming.consume(buffer: Data(#"{"id""#.utf8)), .incomplete)
        XCTAssertEqual(SocketFraming.consume(buffer: Data()), .incomplete)
    }

    func testBufferAtExactlyTheLimitIsStillIncomplete() {
        XCTAssertEqual(
            SocketFraming.consume(buffer: Data(repeating: 0x41, count: MagSleep.maxMessageBytes)),
            .incomplete
        )
    }

    func testOversizedBufferIsRejectedEvenWhenItContainsANewline() {
        // The cap is evaluated before the newline, so a peer cannot smuggle an
        // unbounded line through in a single read.
        var buffer = Data(repeating: 0x41, count: MagSleep.maxMessageBytes)
        buffer.append(0x0A)
        XCTAssertEqual(SocketFraming.consume(buffer: buffer), .tooLarge)
    }

    func testInvalidUTF8DegradesToAnEmptyLine() {
        // Never a crash: the parser rejects an empty line as a malformed request.
        XCTAssertEqual(SocketFraming.consume(buffer: Data([0xFF, 0xFE, 0x0A])), .line(""))
    }

    func testCRLFFrameKeepsTheCarriageReturn() {
        // The JSON decoder tolerates the trailing CR (pinned by the protocol tests).
        XCTAssertEqual(SocketFraming.consume(buffer: Data("{}\r\n".utf8)), .line("{}\r"))
    }
}

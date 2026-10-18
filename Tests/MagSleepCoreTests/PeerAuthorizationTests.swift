import XCTest
@testable import MagSleepCore

/// The fail-closed peer-authorization rule the daemon applies per request on
/// its world-writable socket.
final class PeerAuthorizationTests: XCTestCase {
    func testRootIsAlwaysAllowed() {
        XCTAssertTrue(PeerAuthorization.isAllowed(peerUID: 0, consoleUID: 501))
        XCTAssertTrue(PeerAuthorization.isAllowed(peerUID: 0, consoleUID: nil))
    }

    func testConsoleUserIsAllowed() {
        XCTAssertTrue(PeerAuthorization.isAllowed(peerUID: 501, consoleUID: 501))
    }

    func testAnotherUserIsRejected() {
        XCTAssertFalse(PeerAuthorization.isAllowed(peerUID: 502, consoleUID: 501))
    }

    func testUndeterminableConsoleUserFailsClosed() {
        // Rather than authorizing an arbitrary local process on the 0666 socket.
        XCTAssertFalse(PeerAuthorization.isAllowed(peerUID: 501, consoleUID: nil))
    }

    func testUndeterminablePeerIsRejected() {
        XCTAssertFalse(PeerAuthorization.isAllowed(peerUID: nil, consoleUID: 501))
        XCTAssertFalse(PeerAuthorization.isAllowed(peerUID: nil, consoleUID: nil))
    }
}

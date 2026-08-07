import XCTest
@testable import MagSleepCore

final class SocketCommandHandlerTests: XCTestCase {
    private let request = SocketRequest(id: "r1", cmd: "mode:sleep")

    func testUnauthorizedAlwaysRejected() {
        let outcome = SocketCommandHandler.handle(
            request: request,
            isAuthorized: false,
            currentConfig: .default
        )
        XCTAssertFalse(outcome.response.ok)
        XCTAssertEqual(outcome.response.error, "unauthorized")
        XCTAssertNil(outcome.newConfig)
    }

    func testConfigCommandAppliesAndReturnsNewConfig() {
        let outcome = SocketCommandHandler.handle(
            request: request,
            isAuthorized: true,
            currentConfig: DaemonConfig(mode: .alwaysOff, enabled: false)
        )
        XCTAssertTrue(outcome.response.ok)
        XCTAssertNil(outcome.response.error)
        XCTAssertEqual(outcome.newConfig?.mode, .sleep)
        XCTAssertTrue(outcome.newConfig?.enabled == true)
        // The new config is what the caller must persist — the response echoes it.
        XCTAssertEqual(outcome.response.config, outcome.newConfig)
    }

    func testUnknownCommand() {
        let unknown = SocketRequest(id: "u1", cmd: "bogus-command")
        let outcome = SocketCommandHandler.handle(
            request: unknown,
            isAuthorized: true,
            currentConfig: .default
        )
        XCTAssertFalse(outcome.response.ok)
        XCTAssertEqual(outcome.response.error, "unknown command")
        XCTAssertNil(outcome.newConfig)
    }

    func testDisableCommand() {
        let outcome = SocketCommandHandler.handle(
            request: SocketRequest(id: "d1", cmd: RequestCommand.disable),
            isAuthorized: true,
            currentConfig: .default
        )
        XCTAssertTrue(outcome.response.ok)
        XCTAssertEqual(outcome.newConfig?.enabled, false)
    }
}

final class BoundedProcessTests: XCTestCase {
    func testCapturesStdout() {
        let result = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello", "magsleep"],
            timeout: 5
        )
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(String(data: result.stdout, encoding: .utf8), "hello magsleep\n")
        XCTAssertFalse(result.timedOut)
    }

    func testReportsNonZeroExit() {
        let result = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-c", "exit 3"],
            timeout: 5
        )
        XCTAssertEqual(result.terminationStatus, 3)
        XCTAssertFalse(result.timedOut)
    }

    func testCapturesStderr() {
        let result = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-c", "echo oops >&2"],
            timeout: 5
        )
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(String(data: result.stderr, encoding: .utf8), "oops\n")
    }

    func testHungProcessTimesOut() {
        let start = Date()
        let result = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            timeout: 0.3
        )
        XCTAssertTrue(result.timedOut)
        XCTAssertNotEqual(result.terminationStatus, 0)
        // The SIGTERM → SIGKILL escalation keeps the total wait bounded (~2s).
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
}

final class UnixSocketTests: XCTestCase {
    func testMakeSockAddrCopiesPath() throws {
        let addr = try UnixSocket.makeSockAddr("/var/run/magsleep.sock")
        XCTAssertEqual(addr.sun_family, sa_family_t(AF_UNIX))
        let path = withUnsafeBytes(of: addr.sun_path) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(bytes: bytes, encoding: .utf8) ?? ""
        }
        XCTAssertEqual(path, "/var/run/magsleep.sock")
    }

    func testMakeSockAddrRejectsTooLongPath() {
        let longPath = String(repeating: "x", count: 200)
        XCTAssertThrowsError(try UnixSocket.makeSockAddr(longPath))
    }
}

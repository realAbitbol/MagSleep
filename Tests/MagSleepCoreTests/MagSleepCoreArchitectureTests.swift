import XCTest
@testable import MagSleepCore

final class SocketCommandHandlerTests: XCTestCase {
    private let request = SocketRequest(id: "r1", cmd: "mode:sleep")

    func testUnauthorizedAlwaysRejected() {
        let outcome = SocketCommandHandler.handle(
            request: request,
            isAuthorized: false,
            canBlink: true,
            currentConfig: .default
        )
        XCTAssertFalse(outcome.response.ok)
        XCTAssertEqual(outcome.response.error, "unauthorized")
        XCTAssertNil(outcome.newConfig)
        XCTAssertFalse(outcome.shouldBlink)
    }

    func testConfigCommandAppliesAndReturnsNewConfig() {
        let outcome = SocketCommandHandler.handle(
            request: request,
            isAuthorized: true,
            canBlink: false,
            currentConfig: DaemonConfig(mode: .alwaysOff, enabled: false)
        )
        XCTAssertTrue(outcome.response.ok)
        XCTAssertNil(outcome.response.error)
        XCTAssertFalse(outcome.shouldBlink)
        XCTAssertEqual(outcome.newConfig?.mode, .sleep)
        XCTAssertTrue(outcome.newConfig?.enabled == true)
        // The new config is what the caller must persist — the response echoes it.
        XCTAssertEqual(outcome.response.config, outcome.newConfig)
    }

    func testBlinkAuthorizedAndGateOpen() {
        let blink = SocketRequest(id: "b1", cmd: RequestCommand.blink)
        let outcome = SocketCommandHandler.handle(
            request: blink,
            isAuthorized: true,
            canBlink: true,
            currentConfig: .default
        )
        XCTAssertTrue(outcome.response.ok)
        XCTAssertTrue(outcome.shouldBlink)
        XCTAssertNil(outcome.newConfig)
        XCTAssertNil(outcome.response.config) // not a config mutation
    }

    func testBlinkRejectedWhenGateClosed() {
        let blink = SocketRequest(id: "b1", cmd: RequestCommand.blink)
        let outcome = SocketCommandHandler.handle(
            request: blink,
            isAuthorized: true,
            canBlink: false,
            currentConfig: .default
        )
        XCTAssertFalse(outcome.response.ok)
        XCTAssertFalse(outcome.shouldBlink)
        XCTAssertNil(outcome.newConfig)
        XCTAssertNotNil(outcome.response.error)
    }

    func testUnknownCommand() {
        let unknown = SocketRequest(id: "u1", cmd: "bogus-command")
        let outcome = SocketCommandHandler.handle(
            request: unknown,
            isAuthorized: true,
            canBlink: true,
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
            canBlink: true,
            currentConfig: .default
        )
        XCTAssertTrue(outcome.response.ok)
        XCTAssertEqual(outcome.newConfig?.enabled, false)
    }
}

final class NotificationNodeDetectorTests: XCTestCase {
    private func leaf(_ title: String? = nil, value: String? = nil, description: String? = nil) -> AccessibilityNode {
        AccessibilityNode(title: title, value: value, nodeDescription: description)
    }

    func testBannerSubroleIsDetected() {
        let banner = AccessibilityNode(
            role: "AXGroup",
            subrole: "AXNotificationCenterBanner",
            children: [
                leaf("Messages"),
                leaf("Alice"),
                leaf("Wanna grab lunch?"),
            ]
        )
        let keys = NotificationNodeDetector.notificationKeys(in: AccessibilityNode(role: "AXApplication", children: [banner]))
        XCTAssertEqual(keys, ["Messages Alice Wanna grab lunch?"])
    }

    func testContainerWithTwoToSixTextsIsDetected() {
        let group = AccessibilityNode(
            role: "AXGroup",
            children: [
                leaf("Mail"),
                leaf("New invoice"),
                leaf("You have a new invoice from Acme"),
            ]
        )
        let keys = NotificationNodeDetector.notificationKeys(in: AccessibilityNode(role: "AXApplication", children: [group]))
        XCTAssertEqual(keys, ["Mail New invoice You have a new invoice from Acme"])
    }

    func testIgnoredChromeTextsAreFiltered() {
        // "Close" + "Options" are Notification Center chrome, not content.
        let group = AccessibilityNode(
            role: "AXGroup",
            children: [
                leaf("Slack"),
                leaf("Close"),
                leaf("Options"),
                leaf("Message from @bob"),
            ]
        )
        let keys = NotificationNodeDetector.notificationKeys(in: AccessibilityNode(role: "AXApplication", children: [group]))
        XCTAssertEqual(keys, ["Slack Message from @bob"])
    }

    func testNodeWithOnlyChromeTextsIsNotANotification() {
        let group = AccessibilityNode(
            role: "AXGroup",
            children: [
                leaf("Close"),
                leaf("Options"),
            ]
        )
        let keys = NotificationNodeDetector.notificationKeys(in: AccessibilityNode(role: "AXApplication", children: [group]))
        XCTAssertTrue(keys.isEmpty)
    }

    func testSingleTextIsNotANotificationWithoutBannerSubrole() {
        let group = AccessibilityNode(role: "AXGroup", children: [leaf("Notification Center")])
        let keys = NotificationNodeDetector.notificationKeys(in: AccessibilityNode(role: "AXApplication", children: [group]))
        XCTAssertTrue(keys.isEmpty)
    }

    func testMoreThanSixTextsIsNotANotification() {
        let texts = (1...8).map { "text-\($0)" }
        let group = AccessibilityNode(role: "AXGroup", children: texts.map { leaf($0) })
        let keys = NotificationNodeDetector.notificationKeys(in: AccessibilityNode(role: "AXApplication", children: [group]))
        XCTAssertTrue(keys.isEmpty)
    }

    func testNestedDetection() {
        let banner = AccessibilityNode(
            role: "AXWindow",
            subrole: "AXNotificationCenterBannerStack",
            children: [
                AccessibilityNode(role: "AXGroup", children: [
                    leaf("Calendar"),
                    leaf("Stand up meeting"),
                    leaf("in 10 minutes"),
                ]),
            ]
        )
        let app = AccessibilityNode(role: "AXApplication", children: [
            AccessibilityNode(role: "AXScrollArea", children: [banner]),
        ])
        let keys = NotificationNodeDetector.notificationKeys(in: app)
        XCTAssertEqual(keys, ["Calendar Stand up meeting in 10 minutes"])
    }

    func testDuplicateContentIsDeduplicated() {
        let banner1 = AccessibilityNode(role: "AXGroup", subrole: "AXNotificationCenterBanner", children: [
            leaf("Mail"), leaf("Re: project"), leaf("see thread"),
        ])
        let banner2 = AccessibilityNode(role: "AXGroup", subrole: "AXNotificationCenterBanner", children: [
            leaf("Mail"), leaf("Re: project"), leaf("see thread"),
        ])
        let banner3 = AccessibilityNode(role: "AXGroup", subrole: "AXNotificationCenterBanner", children: [
            leaf("Messages"), leaf("Alice"), leaf("Dinner tonight?"),
        ])
        // Realistic tree: the shared stack holds chrome + several banners, so
        // it exceeds the 2–6 text rule and only the banner subroles are
        // reported — identical banners collapse to one key.
        let stack = AccessibilityNode(role: "AXGroup", subrole: "AXNotificationCenterBannerStack", children: [
            leaf("Notification Center"), leaf("Clear All"), leaf("Earlier Today"),
            banner1, banner2, banner3,
        ])
        let keys = NotificationNodeDetector.notificationKeys(in: AccessibilityNode(role: "AXApplication", children: [stack]))
        XCTAssertEqual(keys, ["Mail Re: project see thread", "Messages Alice Dinner tonight?"])
    }

    // MARK: - macOS version robustness (the AX tree shape differs across the
    // app's supported range, macOS 14…26 — the detector must work on all of them)

    /// macOS 13/14-era shape: banners inside an explicitly-marked stack,
    /// chrome texts, and per-banner age timestamps ("5m ago") in the tree.
    func testSonomaStyleTreeWithTimestamps() {
        let banner = AccessibilityNode(role: "AXGroup", subrole: "AXNotificationCenterBanner", children: [
            leaf("Mail"),
            leaf("Re: launch"),
            leaf("The build is green"),
            leaf("5m ago"), // relative time must not pollute the key
        ])
        let stack = AccessibilityNode(role: "AXGroup", subrole: "AXNotificationCenterBannerStack", children: [
            leaf("Notification Center"),
            leaf("Clear All"),
            leaf("Earlier Today"),
            banner,
        ])
        let app = AccessibilityNode(role: "AXApplication", children: [
            AccessibilityNode(role: "AXWindow", children: [stack]),
        ])
        let keys = NotificationNodeDetector.notificationKeys(in: app)
        XCTAssertEqual(keys, ["Mail Re: launch The build is green"])
    }

    /// macOS 15/26-era shape: no banner subroles exposed (hosted in Control
    /// Center), notifications are plain groups detected by the 2–6 text rule,
    /// with a clock-text leaf.
    func testTahoeStyleTreeWithoutSubroles() {
        let notification = AccessibilityNode(role: "AXGroup", children: [
            leaf("Slack"),
            leaf("@ada"),
            leaf("Standup in 5"),
            leaf("12:30"),
        ])
        let scroll = AccessibilityNode(role: "AXScrollArea", children: [
            leaf("Notification Center"),
            leaf("Clear All"),
            notification,
        ])
        let app = AccessibilityNode(role: "AXApplication", children: [scroll])
        let keys = NotificationNodeDetector.notificationKeys(in: app)
        XCTAssertEqual(keys, ["Slack @ada Standup in 5"])
    }

    /// The same message must produce the same key regardless of its age text —
    /// a changing timestamp must never re-trigger a blink.
    func testTimestampChangeDoesNotChangeKey() {
        func key(withTimestamp timestamp: String) -> Set<String> {
            let banner = AccessibilityNode(role: "AXGroup", subrole: "AXNotificationCenterBanner", children: [
                leaf("Mail"), leaf("Re: project"), leaf("see thread"), leaf(timestamp),
            ])
            return NotificationNodeDetector.notificationKeys(
                in: AccessibilityNode(role: "AXApplication", children: [banner])
            )
        }
        XCTAssertEqual(key(withTimestamp: "5m ago"), key(withTimestamp: "now"))
        XCTAssertEqual(key(withTimestamp: "2 hours ago"), key(withTimestamp: "12:30"))
    }

    /// A timestamp-only + chrome node is not a notification.
    func testTimestampAloneIsNotANotification() {
        let group = AccessibilityNode(role: "AXGroup", children: [
            leaf("Close"), leaf("Options"), leaf("5m ago"),
        ])
        let keys = NotificationNodeDetector.notificationKeys(in: AccessibilityNode(role: "AXApplication", children: [group]))
        XCTAssertTrue(keys.isEmpty)
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

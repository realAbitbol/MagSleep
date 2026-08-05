import XCTest
@testable import MagSleepCore

final class DaemonConfigTests: XCTestCase {
    func testDefault() {
        XCTAssertEqual(DaemonConfig.default.mode, .sleep)
        XCTAssertTrue(DaemonConfig.default.enabled)
    }

    func testApplyModeSleep() {
        var config = DaemonConfig(mode: .alwaysOff, enabled: false)
        XCTAssertTrue(config.apply(RequestCommand.modeSleep))
        XCTAssertEqual(config.mode, .sleep)
        XCTAssertTrue(config.enabled)
    }

    func testApplyModeAlwaysOff() {
        var config = DaemonConfig(mode: .sleep, enabled: false)
        XCTAssertTrue(config.apply(RequestCommand.modeAlwaysOff))
        XCTAssertEqual(config.mode, .alwaysOff)
        XCTAssertTrue(config.enabled)
    }

    func testApplyEnable() {
        var config = DaemonConfig(enabled: false)
        XCTAssertTrue(config.apply(RequestCommand.enable))
        XCTAssertTrue(config.enabled)
    }

    func testApplyDisable() {
        var config = DaemonConfig(enabled: true)
        XCTAssertTrue(config.apply(RequestCommand.disable))
        XCTAssertFalse(config.enabled)
    }

    func testApplyUnknownCommandLeavesConfigUnchanged() {
        var config = DaemonConfig(mode: .alwaysOff, enabled: true)
        XCTAssertFalse(config.apply("bogus-command"))
        XCTAssertEqual(config.mode, .alwaysOff)
        XCTAssertTrue(config.enabled)
    }
}

final class DaemonConfigDecodingTests: XCTestCase {
    func testDecodeValid() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
            <key>mode</key><string>alwaysOff</string>
            <key>enabled</key><false/>
        </dict></plist>
        """
        let config = try PropertyListDecoder().decode(DaemonConfig.self, from: Data(xml.utf8))
        XCTAssertEqual(config.mode, .alwaysOff)
        XCTAssertFalse(config.enabled)
    }

    func testCorruptDataFailsDecode() {
        XCTAssertNil(try? PropertyListDecoder().decode(DaemonConfig.self, from: Data("garbage".utf8)))
    }

    func testUnknownModeStringFailsDecode() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
            <key>mode</key><string>lavaLamp</string>
            <key>enabled</key><true/>
        </dict></plist>
        """
        XCTAssertNil(try? PropertyListDecoder().decode(DaemonConfig.self, from: Data(xml.utf8)))
    }

    func testMissingEnabledKeyFailsDecode() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
            <key>mode</key><string>sleep</string>
        </dict></plist>
        """
        XCTAssertNil(try? PropertyListDecoder().decode(DaemonConfig.self, from: Data(xml.utf8)))
    }

    func testRoundTrip() throws {
        let config = DaemonConfig(mode: .alwaysOff, enabled: false)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(config)
        let decoded = try PropertyListDecoder().decode(DaemonConfig.self, from: data)
        XCTAssertEqual(decoded.mode, config.mode)
        XCTAssertEqual(decoded.enabled, config.enabled)
    }

    func testLoadMissingFileFallsBackToDefault() {
        let url = URL(fileURLWithPath: "/nonexistent/magsleep/config.plist")
        let config = DaemonConfig.load(from: url)
        XCTAssertEqual(config.mode, .sleep)
        XCTAssertTrue(config.enabled)
    }

    func testLoadCorruptFileFallsBackToDefault() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("magsleep-test-corrupt.plist")
        try Data("garbage".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let config = DaemonConfig.load(from: url)
        XCTAssertEqual(config.mode, .sleep)
        XCTAssertTrue(config.enabled)
    }
}

final class LEDTargetTests: XCTestCase {
    func testDisabledAlwaysHandsControlToSystem() {
        let config = DaemonConfig(enabled: false)
        XCTAssertEqual(LEDTarget.color(for: config, isSleeping: true), .system)
        XCTAssertEqual(LEDTarget.color(for: config, isSleeping: false), .system)
    }

    func testSleepMode() {
        let config = DaemonConfig(mode: .sleep, enabled: true)
        XCTAssertEqual(LEDTarget.color(for: config, isSleeping: true), .off)
        XCTAssertEqual(LEDTarget.color(for: config, isSleeping: false), .system)
    }

    func testAlwaysOffMode() {
        let config = DaemonConfig(mode: .alwaysOff, enabled: true)
        XCTAssertEqual(LEDTarget.color(for: config, isSleeping: true), .off)
        XCTAssertEqual(LEDTarget.color(for: config, isSleeping: false), .off)
    }
}

final class SMCLayoutTests: XCTestCase {
    /// The daemon talks to the kernel's AppleSMC user client with a fixed 80-byte
    /// struct. If Swift ever pads the layout differently, the SMC calls would
    /// corrupt data — this test guards against compiler/ABI regressions.
    func testSMCParamStructStrideIs80() {
        XCTAssertEqual(MemoryLayout<SMC.SMCParamStruct>.stride, 80)
    }
}

final class SocketProtocolTests: XCTestCase {
    func testRequestRoundTrip() throws {
        let request = SocketRequest(id: "abc-123", cmd: RequestCommand.modeSleep)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(SocketRequest.self, from: data)
        XCTAssertEqual(decoded, request)
    }

    func testResponseSuccessRoundTrip() throws {
        let config = DaemonConfig(mode: .alwaysOff, enabled: true)
        let response = SocketResponse(id: "abc-123", ok: true, config: config, error: nil)
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(SocketResponse.self, from: data)
        XCTAssertEqual(decoded, response)
        XCTAssertEqual(decoded.config?.mode, .alwaysOff)
        XCTAssertTrue(decoded.config?.enabled == true)
    }

    func testResponseFailureRoundTrip() throws {
        let response = SocketResponse(id: "abc-123", ok: false, config: nil, error: "unknown command")
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(SocketResponse.self, from: data)
        XCTAssertEqual(decoded, response)
        XCTAssertNil(decoded.config)
        XCTAssertEqual(decoded.error, "unknown command")
    }

    func testParseLine() {
        let response = SocketResponse(id: "x", ok: true, config: nil, error: nil)
        let line = response.encodeLine()
        XCTAssertTrue(line.hasSuffix("\n"))
        XCTAssertEqual(SocketResponse.parseLine(String(line.dropLast())), response)
    }

    func testParseMalformedLineReturnsNil() {
        XCTAssertNil(SocketRequest.parseLine("not json"))
        XCTAssertNil(SocketResponse.parseLine("not json"))
    }
}

final class SemanticVersionTests: XCTestCase {
    func testEqualVersions() {
        XCTAssertEqual(SemanticVersion("1.0.0"), SemanticVersion("1.0.0"))
        XCTAssertFalse(SemanticVersion("1.0.0") > SemanticVersion("1.0.0"))
    }

    func testNewerMajorMinorPatch() {
        XCTAssertTrue(SemanticVersion("1.1.0") > SemanticVersion("1.0.9"))
        XCTAssertTrue(SemanticVersion("2.0.0") > SemanticVersion("1.9.9"))
        XCTAssertTrue(SemanticVersion("1.0.10") > SemanticVersion("1.0.9"))
    }

    func testShorterVersionsCompareAsZeroPadded() {
        XCTAssertTrue(SemanticVersion("1.1") > SemanticVersion("1.0.9"))
        XCTAssertTrue(SemanticVersion("1.0.1") > SemanticVersion("1.0"))
        XCTAssertFalse(SemanticVersion("1.0") > SemanticVersion("1.0.0"))
    }

    func testNonNumericComponentsAreIgnored() {
        XCTAssertEqual(SemanticVersion("1.0.0-beta").components, [1, 0])
        XCTAssertEqual(SemanticVersion("1.0.5"), SemanticVersion("1.0.5"))
    }
}

final class ConstantsTests: XCTestCase {
    func testOperationModeRawValues() {
        XCTAssertEqual(OperationMode.sleep.rawValue, "sleep")
        XCTAssertEqual(OperationMode.alwaysOff.rawValue, "alwaysOff")
    }

    func testHelperPaths() {
        XCTAssertEqual(MagSleep.helperLabel, "com.magsleep.helper")
        XCTAssertEqual(MagSleep.helperBinaryPath, "/Library/PrivilegedHelperTools/com.magsleep.helper")
        XCTAssertEqual(MagSleep.helperPlistPath, "/Library/LaunchDaemons/com.magsleep.helper.plist")
        XCTAssertEqual(MagSleep.configFilePath, "/Library/Preferences/MagSleep/config.plist")
    }
}

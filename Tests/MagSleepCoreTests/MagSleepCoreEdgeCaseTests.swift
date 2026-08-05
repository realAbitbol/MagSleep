import XCTest
@testable import MagSleepCore

final class DaemonConfigApplyEdgeCaseTests: XCTestCase {
    func testApplyRejectsWhitespaceWrappedCommands() {
        for command in [" mode:sleep", "mode:sleep ", "mode:sleep\n", "\tmode:sleep\t", " mode:alwaysOff "] {
            var config = DaemonConfig(mode: .alwaysOff, enabled: true)
            XCTAssertFalse(config.apply(command), "expected \(command.debugDescription) to be rejected")
            XCTAssertEqual(config.mode, .alwaysOff, "config mutated by \(command.debugDescription)")
            XCTAssertTrue(config.enabled)
        }
    }

    func testApplyIsCaseSensitive() {
        for command in ["Mode:Sleep", "MODE:SLEEP", "Mode:AlwaysOff", "Enable", "DISABLE", "EnAbLe"] {
            var config = DaemonConfig(mode: .sleep, enabled: true)
            XCTAssertFalse(config.apply(command), "expected \(command) to be rejected")
            XCTAssertEqual(config.mode, .sleep)
            XCTAssertTrue(config.enabled)
        }
    }

    func testApplyEmptyStringIsUnknown() {
        var config = DaemonConfig(mode: .alwaysOff, enabled: false)
        XCTAssertFalse(config.apply(""))
        XCTAssertEqual(config.mode, .alwaysOff)
        XCTAssertFalse(config.enabled)
    }

    func testApplyEnablePreservesMode() {
        var config = DaemonConfig(mode: .alwaysOff, enabled: false)
        XCTAssertTrue(config.apply(RequestCommand.enable))
        XCTAssertEqual(config.mode, .alwaysOff)
        XCTAssertTrue(config.enabled)
    }

    func testApplyDisablePreservesMode() {
        var config = DaemonConfig(mode: .sleep, enabled: true)
        XCTAssertTrue(config.apply(RequestCommand.disable))
        XCTAssertEqual(config.mode, .sleep)
        XCTAssertFalse(config.enabled)
    }
}

final class DaemonConfigLoadFileTests: XCTestCase {
    private func writePlist(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("magsleep-test-\(UUID().uuidString).plist")
        try Data(body.utf8).write(to: url)
        return url
    }

    private func plistDoc(body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
            \(body)
        </dict></plist>
        """
    }

    func testLoadValidPlistFromTempFile() throws {
        let url = try writePlist(plistDoc(body: """
            <key>mode</key><string>alwaysOff</string>
            <key>enabled</key><false/>
            """))
        defer { try? FileManager.default.removeItem(at: url) }
        let config = DaemonConfig.load(from: url)
        XCTAssertEqual(config.mode, .alwaysOff)
        XCTAssertFalse(config.enabled)
    }

    func testLoadValidPlistExplicitTrueFromTempFile() throws {
        let url = try writePlist(plistDoc(body: """
            <key>mode</key><string>sleep</string>
            <key>enabled</key><true/>
            """))
        defer { try? FileManager.default.removeItem(at: url) }
        let config = DaemonConfig.load(from: url)
        XCTAssertEqual(config.mode, .sleep)
        XCTAssertTrue(config.enabled)
    }

    func testLoadEnabledWrongTypeFallsBackToDefault() throws {
        // mode is alwaysOff so a successful decode would be distinguishable
        // from the .default fallback (sleep/enabled).
        let bodies = [
            "<key>mode</key><string>alwaysOff</string><key>enabled</key><integer>1</integer>",
            "<key>mode</key><string>alwaysOff</string><key>enabled</key><string>false</string>",
            "<key>mode</key><string>alwaysOff</string><key>enabled</key><data>AA==</data>"
        ]
        for body in bodies {
            let url = try writePlist(plistDoc(body: body))
            defer { try? FileManager.default.removeItem(at: url) }
            let config = DaemonConfig.load(from: url)
            XCTAssertEqual(config.mode, .sleep, "wrong-type enabled should fall back for \(body)")
            XCTAssertTrue(config.enabled, "wrong-type enabled should fall back for \(body)")
        }
    }

    func testLoadModeWrongTypeFallsBackToDefault() throws {
        let url = try writePlist(plistDoc(body: "<key>mode</key><integer>1</integer><key>enabled</key><true/>"))
        defer { try? FileManager.default.removeItem(at: url) }
        let config = DaemonConfig.load(from: url)
        XCTAssertEqual(config.mode, .sleep)
        XCTAssertTrue(config.enabled)
    }

    func testLoadEmptyFileFallsBackToDefault() throws {
        let url = try writePlist("")
        defer { try? FileManager.default.removeItem(at: url) }
        let config = DaemonConfig.load(from: url)
        XCTAssertEqual(config.mode, .sleep)
        XCTAssertTrue(config.enabled)
    }

    func testLoadDirectoryURLFallsBackToDefault() {
        let config = DaemonConfig.load(from: FileManager.default.temporaryDirectory)
        XCTAssertEqual(config.mode, .sleep)
        XCTAssertTrue(config.enabled)
    }
}

final class SMCPureLogicTests: XCTestCase {
    func testFourCCEncoding() {
        XCTAssertEqual(SMC.fourCC("ACLC"), 0x41434C43)
        XCTAssertEqual(SMC.fourCC("ABCD"), 0x41424344)
        XCTAssertEqual(SMC.fourCC("abcd"), 0x61626364)
    }

    func testFourCCOfMagSafeLEDKey() {
        XCTAssertEqual(MagSafeLED.key, "ACLC")
        XCTAssertEqual(SMC.fourCC(MagSafeLED.key), 0x41434C43)
    }

    func testMagSafeLEDColorRawValues() {
        XCTAssertEqual(MagSafeLED.Color.system.rawValue, 0)
        XCTAssertEqual(MagSafeLED.Color.off.rawValue, 1)
        XCTAssertEqual(MagSafeLED.Color.green.rawValue, 3)
        XCTAssertEqual(MagSafeLED.Color.amber.rawValue, 4)
    }

    func testSMCErrorDescriptions() {
        XCTAssertEqual(SMC.SMCError.serviceNotFound.description, "AppleSMC service not found")
        XCTAssertEqual(SMC.SMCError.openFailed(5).description, "IOServiceOpen failed (5)")
        XCTAssertEqual(SMC.SMCError.callFailed(4).description, "IOConnectCallStructMethod failed (4)")
        XCTAssertEqual(SMC.SMCError.smcResult(0x84).description,
                       "SMC key not found (this Mac may not support the MagSafe LED)")
        XCTAssertEqual(SMC.SMCError.smcResult(0x01).description, "SMC returned error 1")
        XCTAssertEqual(SMC.SMCError.unexpectedLayout(16).description,
                       "SMCParamStruct has unexpected size 16, refusing to talk to the SMC")
    }
}

final class SocketProtocolEdgeCaseTests: XCTestCase {
    func testRequestParseLineRoundTrip() throws {
        let request = SocketRequest(id: "abc", cmd: RequestCommand.modeSleep)
        let line = String(data: try JSONEncoder().encode(request), encoding: .utf8)!
        XCTAssertEqual(SocketRequest.parseLine(line), request)
    }

    func testParseLineMissingRequiredFieldsReturnsNil() {
        XCTAssertNil(SocketResponse.parseLine(#"{"ok":true,"config":null,"error":null}"#))
        XCTAssertNil(SocketResponse.parseLine(#"{"id":"x","config":null,"error":null}"#))
        XCTAssertNil(SocketRequest.parseLine(#"{"id":"x"}"#))
    }

    func testParseLineWrongTypesReturnNil() {
        XCTAssertNil(SocketResponse.parseLine(#"{"id":1,"ok":true,"config":null,"error":null}"#))
        XCTAssertNil(SocketResponse.parseLine(#"{"id":"x","ok":"true","config":null,"error":null}"#))
        XCTAssertNil(SocketRequest.parseLine(#"{"id":1,"cmd":"mode:sleep"}"#))
    }

    func testParseLineIgnoresUnknownFields() {
        let response = SocketResponse(id: "x", ok: true, config: nil, error: nil)
        let line = #"{"id":"x","ok":true,"config":null,"error":null,"surprise":1}"#
        XCTAssertEqual(SocketResponse.parseLine(line), response)
    }

    func testParseLineToleratesTrailingNewline() {
        let response = SocketResponse(id: "x", ok: false, config: nil, error: "boom")
        let line = response.encodeLine()
        XCTAssertTrue(line.hasSuffix("\n"))
        XCTAssertEqual(SocketResponse.parseLine(line), response)
    }

    func testParseLineEmptyOrNewlineReturnsNil() {
        XCTAssertNil(SocketResponse.parseLine(""))
        XCTAssertNil(SocketResponse.parseLine("\n"))
    }

    func testEncodeLineProducesSingleNewlineTerminatedLine() {
        let response = SocketResponse(id: "x", ok: true, config: nil, error: nil)
        let line = response.encodeLine()
        XCTAssertTrue(line.hasSuffix("\n"))
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1)
        XCTAssertFalse(line.dropLast().contains("\n"))
        XCTAssertEqual(SocketResponse.parseLine(line), response)
    }

    func testMaxMessageBytesIs4096() {
        XCTAssertEqual(SocketResponse.maxMessageBytes, 4096)
    }
}

final class ConstantsEdgeCaseTests: XCTestCase {
    func testConfigAndSocketPaths() {
        XCTAssertEqual(MagSleep.configDirectory, "/Library/Preferences/MagSleep")
        XCTAssertEqual(MagSleep.socketPath, "/var/run/magsleep.sock")
        XCTAssertEqual(MagSleep.helperVersionFilePath, "/Library/Preferences/MagSleep/helper-version.txt")
    }

    func testCoffeeURL() {
        XCTAssertEqual(MagSleep.coffeeURL.scheme, "https")
        XCTAssertEqual(MagSleep.coffeeURL.host, "ko-fi.com")
    }
}

final class HelperVersioningTests: XCTestCase {
    func testMatchingRevisionDoesNotReinstall() {
        XCTAssertFalse(HelperVersioning.shouldReinstall(installedRevision: "e2e22d7", bundledRevision: "e2e22d7"))
    }

    func testMismatchedRevisionReinstalls() {
        XCTAssertTrue(HelperVersioning.shouldReinstall(installedRevision: "e2e22d7", bundledRevision: "deadbee"))
        XCTAssertTrue(HelperVersioning.shouldReinstall(installedRevision: "1.2.3", bundledRevision: "e2e22d7"))
    }

    func testMissingOrEmptyRevisionReinstalls() {
        XCTAssertTrue(HelperVersioning.shouldReinstall(installedRevision: nil, bundledRevision: "e2e22d7"))
        XCTAssertTrue(HelperVersioning.shouldReinstall(installedRevision: "", bundledRevision: "e2e22d7"))
    }

    func testUnknownBundledRevisionStillCompares() {
        // No-git builds embed "unknown"; an installed "unknown" then matches.
        XCTAssertFalse(HelperVersioning.shouldReinstall(installedRevision: "unknown", bundledRevision: "unknown"))
        XCTAssertTrue(HelperVersioning.shouldReinstall(installedRevision: "e2e22d7", bundledRevision: "unknown"))
    }
}

final class LEDModeTests: XCTestCase {
    func testSocketCommands() {
        XCTAssertEqual(LEDMode.sleep.socketCommand, "mode:sleep")
        XCTAssertEqual(LEDMode.alwaysOff.socketCommand, "mode:alwaysOff")
        XCTAssertEqual(LEDMode.disabled.socketCommand, "disable")
    }

    func testOperationModeMapping() {
        XCTAssertEqual(LEDMode.sleep.operationMode, .sleep)
        XCTAssertEqual(LEDMode.alwaysOff.operationMode, .alwaysOff)
        XCTAssertNil(LEDMode.disabled.operationMode)
    }

    func testRawValueParsing() {
        XCTAssertEqual(LEDMode(rawValue: "sleep"), .sleep)
        XCTAssertEqual(LEDMode(rawValue: "alwaysOff"), .alwaysOff)
        XCTAssertEqual(LEDMode(rawValue: "disabled"), .disabled)
        XCTAssertNil(LEDMode(rawValue: "bogus"))
    }
}

final class LEDStatusDescriptionTests: XCTestCase {
    func testStatusDescriptions() {
        XCTAssertEqual(
            LEDStatusDescription.describe(isInstalled: false, isLoaded: false, isEnabled: false, mode: .sleep),
            "not installed"
        )
        XCTAssertEqual(
            LEDStatusDescription.describe(isInstalled: true, isLoaded: false, isEnabled: false, mode: .sleep),
            "helper not running"
        )
        XCTAssertEqual(
            LEDStatusDescription.describe(isInstalled: true, isLoaded: true, isEnabled: false, mode: .sleep),
            "disabled (macOS control)"
        )
        XCTAssertEqual(
            LEDStatusDescription.describe(isInstalled: true, isLoaded: true, isEnabled: true, mode: .sleep),
            "sleep mode"
        )
        XCTAssertEqual(
            LEDStatusDescription.describe(isInstalled: true, isLoaded: true, isEnabled: true, mode: .alwaysOff),
            "always off"
        )
    }
}

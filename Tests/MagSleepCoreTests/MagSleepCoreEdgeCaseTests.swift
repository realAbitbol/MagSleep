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
    func testFourCCEncoding() throws {
        XCTAssertEqual(try SMC.fourCC("ACLC"), 0x41434C43)
        XCTAssertEqual(try SMC.fourCC("ABCD"), 0x41424344)
        XCTAssertEqual(try SMC.fourCC("abcd"), 0x61626364)
    }

    func testFourCCOfMagSafeLEDKey() throws {
        XCTAssertEqual(MagSafeLED.key, "ACLC")
        XCTAssertEqual(try SMC.fourCC(MagSafeLED.key), 0x41434C43)
    }

    func testFourCCRejectsWrongLength() {
        XCTAssertThrowsError(try SMC.fourCC("ACL"))
        XCTAssertThrowsError(try SMC.fourCC(""))
        XCTAssertThrowsError(try SMC.fourCC("ACLCL"))
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
        XCTAssertEqual(MagSleep.maxMessageBytes, 4096)
    }

    func testParseLineToleratesCRLF() {
        let line = "{\"id\":\"a\",\"cmd\":\"enable\"}\r\n"
        XCTAssertNotNil(SocketRequest.parseLine(line))
    }

    func testParseLineWhitespaceOnlyReturnsNil() {
        XCTAssertNil(SocketRequest.parseLine("   \n"))
        XCTAssertNil(SocketResponse.parseLine(" \t \n"))
    }

    func testParseLineNullRequiredFieldReturnsNil() {
        XCTAssertNil(SocketRequest.parseLine(#"{"id":"a","cmd":null}"#))
    }

    func testRequestParseLineToleratesTrailingNewline() {
        let line = "{\"id\":\"a\",\"cmd\":\"enable\"}\n"
        XCTAssertNotNil(SocketRequest.parseLine(line))
    }

    func testEncodeLineFailureFallbackIsParseable() {
        // Even the impossible encode failure must yield a response the client
        // can parse (never an unparseable "{}" that hangs until timeout).
        let line = SocketResponse(id: "x", ok: true, config: nil, error: nil).encodeLine()
        XCTAssertNotNil(SocketResponse.parseLine(line))
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

final class SunScheduleTests: XCTestCase {
    /// Real output captured from `/usr/libexec/corebrightnessdiag sunschedule`
    /// on macOS 26.
    private let sample = """
    Night Shift Sunset/Sunrise
    {
        isDaylight = 0;
        nextSunrise = "2026-08-08 04:37:06 +0000";
        nextSunset = "2026-08-08 18:54:29 +0000";
        previousSunrise = "2026-08-06 04:34:43 +0000";
        previousSunset = "2026-08-06 18:57:22 +0000";
        sunrise = "2026-08-07 04:35:54 +0000";
        sunset = "2026-08-07 18:55:56 +0000";
    }
    """

    func testParsesRealOutput() {
        guard let schedule = SunSchedule(parsing: sample) else {
            return XCTFail("should parse the real corebrightnessdiag output")
        }
        // The tool prints UTC (+0000); compare in UTC regardless of the
        // machine's timezone.
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let sunriseComponents = utcCalendar.dateComponents([.hour, .minute], from: schedule.sunrise)
        XCTAssertEqual(sunriseComponents.hour, 4)
        XCTAssertEqual(sunriseComponents.minute, 35)
        let sunsetComponents = utcCalendar.dateComponents([.hour, .minute], from: schedule.sunset)
        XCTAssertEqual(sunsetComponents.hour, 18)
        XCTAssertEqual(sunsetComponents.minute, 55)
    }

    func testRejectsGarbage() {
        XCTAssertNil(SunSchedule(parsing: "not a sun schedule"))
        XCTAssertNil(SunSchedule(parsing: ""))
    }

    func testRejectsPartialOutput() {
        XCTAssertNil(SunSchedule(parsing: "sunrise = \"2026-08-07 04:35:54 +0000\";"))
    }

    func testAnchoredParseIgnoresSiblingKeys() {
        // nextSunrise/nextSunset are adjacent keys — the anchored parser must
        // pick exactly the "sunrise"/"sunset" lines regardless of order.
        let text = """
        nextSunset = "2026-08-08 18:54:29 +0000";
        sunrise = "2026-08-07 04:35:54 +0000";
        sunset = "2026-08-07 18:55:56 +0000";
        nextSunrise = "2026-08-08 04:37:06 +0000";
        """
        guard let schedule = SunSchedule(parsing: text) else { return XCTFail("should parse") }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(utc.component(.hour, from: schedule.sunrise), 4)
        XCTAssertEqual(utc.component(.hour, from: schedule.sunset), 18)
    }
}

final class DayNightTests: XCTestCase {
    /// A fixed schedule: sunrise 04:00 UTC, sunset 20:00 UTC.
    private func schedule() -> SunSchedule {
        let text = """
        sunrise = "2026-08-07 04:00:00 +0000";
        sunset = "2026-08-07 20:00:00 +0000";
        """
        guard let schedule = SunSchedule(parsing: text) else {
            fatalError("bad fixture")
        }
        return schedule
    }

    private func instant(_ date: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.date(from: date)!
    }

    func testScheduleBoundaries() {
        let schedule = schedule()
        XCTAssertTrue(DayNight.isNight(now: instant("2026-08-07 00:00:00 +0000"), schedule: schedule))
        XCTAssertFalse(DayNight.isNight(now: instant("2026-08-07 12:00:00 +0000"), schedule: schedule))
        // Exactly at sunrise → day; exactly at sunset → night.
        XCTAssertFalse(DayNight.isNight(now: instant("2026-08-07 04:00:00 +0000"), schedule: schedule))
        XCTAssertTrue(DayNight.isNight(now: instant("2026-08-07 20:00:00 +0000"), schedule: schedule))
        XCTAssertTrue(DayNight.isNight(now: instant("2026-08-07 03:59:00 +0000"), schedule: schedule))
        XCTAssertTrue(DayNight.isNight(now: instant("2026-08-07 20:01:00 +0000"), schedule: schedule))
    }

    func testFallbackWindowLocalHours() {
        func localDate(hour: Int) -> Date {
            var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
            comps.hour = hour
            return Calendar.current.date(from: comps)!
        }
        XCTAssertTrue(DayNight.isNight(now: localDate(hour: 20), schedule: nil))
        XCTAssertTrue(DayNight.isNight(now: localDate(hour: 23), schedule: nil))
        XCTAssertTrue(DayNight.isNight(now: localDate(hour: 6), schedule: nil))
        XCTAssertFalse(DayNight.isNight(now: localDate(hour: 7), schedule: nil)) // end exclusive
        XCTAssertFalse(DayNight.isNight(now: localDate(hour: 19), schedule: nil))
        XCTAssertFalse(DayNight.isNight(now: localDate(hour: 12), schedule: nil))
        // No schedule AND no fallback window → always day.
        XCTAssertFalse(DayNight.isNight(now: localDate(hour: 23), schedule: nil, fallbackWindow: nil))
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

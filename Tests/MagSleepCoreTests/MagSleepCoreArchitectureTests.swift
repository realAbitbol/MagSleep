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

    func testGrandchildHoldingPipeDoesNotHang() {
        // A background grandchild inherits the pipe's write end and keeps it
        // open after the direct child exits, so EOF never arrives. The drain
        // must still return at the deadline instead of blocking forever (the
        // regression this test pins: `availableData` blocked past the deadline
        // indefinitely, hanging BoundedProcess.run despite its timeout).
        let start = Date()
        let result = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-c", "sleep 3 & echo done"],
            timeout: 1.0
        )
        XCTAssertFalse(result.timedOut) // the direct child exited quickly
        XCTAssertTrue(String(data: result.stdout, encoding: .utf8)?.contains("done") == true)
        // Old code returned only after the grandchild's `sleep 3` released the
        // pipe (~3s); the poll-bounded drain returns at the ~1s deadline.
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.5)
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

final class MachOContentHashTests: XCTestCase {
    /// A minimal thin arm64 Mach-O: header + `__LINKEDIT` segment + code
    /// signature load command + content + signature blob. `dataoff` is 136.
    private func makeMachO(
        contentByte: UInt8,
        sigByte: UInt8,
        filesize: UInt64,
        datasize: UInt32
    ) -> Data {
        func u32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        func u64(_ value: UInt64) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        var d = Data()
        d.append(u32(0xfeedfacf)) // MH_MAGIC_64
        d.append(u32(0x0100_000c)) // CPU_TYPE_ARM64
        d.append(u32(0)) // cpusubtype
        d.append(u32(0)) // filetype
        d.append(u32(2)) // ncmds
        d.append(u32(88)) // sizeofcmds
        d.append(u32(0)) // flags
        d.append(u32(0)) // reserved
        // LC_SEGMENT_64: __LINKEDIT
        d.append(u32(0x19))
        d.append(u32(72))
        d.append(Data("__LINKEDIT".utf8))
        d.append(Data(repeating: 0, count: 6)) // 16-byte padded segname
        d.append(u64(0)) // vmaddr
        d.append(u64(0)) // vmsize
        d.append(u64(0)) // fileoff
        d.append(u64(filesize)) // filesize (variant field at +48)
        d.append(u32(0)) // maxprot
        d.append(u32(0)) // initprot
        d.append(u32(0)) // nsects
        d.append(u32(0)) // flags
        // LC_CODE_SIGNATURE
        d.append(u32(0x1d))
        d.append(u32(16))
        d.append(u32(136)) // dataoff
        d.append(u32(datasize)) // datasize (variant field at +12)
        // content (offsets 120...135)
        d.append(Data(repeating: 0, count: 15))
        d.append(contentByte)
        // signature blob (offsets 136...151)
        d.append(Data(repeating: 0, count: 15))
        d.append(sigByte)
        return d
    }

    func testHashIgnoresSignatureMetadata() {
        // Different signature bytes, signature size, and the two load-command
        // size fields must not change the hash (that is the re-sign case).
        let a = makeMachO(contentByte: 0x41, sigByte: 0x01, filesize: 32, datasize: 16)
        let b = makeMachO(contentByte: 0x41, sigByte: 0x99, filesize: 64, datasize: 32)
        XCTAssertEqual(MachOContentHash.hexSHA256(of: a), MachOContentHash.hexSHA256(of: b))
    }

    func testHashDetectsContentChange() {
        let a = makeMachO(contentByte: 0x41, sigByte: 0x01, filesize: 32, datasize: 16)
        let changed = makeMachO(contentByte: 0x42, sigByte: 0x01, filesize: 32, datasize: 16)
        XCTAssertNotEqual(MachOContentHash.hexSHA256(of: a), MachOContentHash.hexSHA256(of: changed))
    }

    func testHashRejectsNonMachO() {
        XCTAssertNil(MachOContentHash.hexSHA256(of: Data("not a mach-o at all".utf8)))
    }

    func testShouldReinstallByContentHash() {
        XCTAssertTrue(HelperVersioning.shouldReinstall(installedContentHash: "aaa", bundledContentHash: "bbb"))
        XCTAssertFalse(HelperVersioning.shouldReinstall(installedContentHash: "aaa", bundledContentHash: "aaa"))
        // Unknown hashes never force a reinstall on their own (revision fallback).
        XCTAssertFalse(HelperVersioning.shouldReinstall(installedContentHash: nil, bundledContentHash: "aaa"))
        XCTAssertFalse(HelperVersioning.shouldReinstall(installedContentHash: "aaa", bundledContentHash: nil))
    }
}

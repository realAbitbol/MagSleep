import Foundation
import IOKit

/// Minimal AppleSMC client: read key info and write a single-byte key.
/// Struct layout mirrors the kernel's SMCParamStruct (80 bytes).
public enum SMC {
    public enum SMCError: Error, CustomStringConvertible {
        case serviceNotFound
        case openFailed(kern_return_t)
        case callFailed(kern_return_t)
        case smcResult(UInt8)
        case unexpectedLayout(Int)

        public var description: String {
            switch self {
            case .serviceNotFound: return "AppleSMC service not found"
            case .openFailed(let kr): return "IOServiceOpen failed (\(kr))"
            case .callFailed(let kr): return "IOConnectCallStructMethod failed (\(kr))"
            case .smcResult(let r):
                return r == 0x84
                    ? "SMC key not found (this Mac may not support the MagSafe LED)"
                    : "SMC returned error \(r)"
            case .unexpectedLayout(let size):
                return "SMCParamStruct has unexpected size \(size), refusing to talk to the SMC"
            }
        }
    }

    // Kernel-layout mirrors: fields are read by AppleSMC via
    // IOConnectCallStructMethod, which Periphery cannot see. The per-field
    // periphery:ignore comments are the supported way to keep these.

    struct SMCVersion {
        // periphery:ignore
        var major: UInt8 = 0
        // periphery:ignore
        var minor: UInt8 = 0
        // periphery:ignore
        var build: UInt8 = 0
        // periphery:ignore
        var reserved: UInt8 = 0
        // periphery:ignore
        var release: UInt16 = 0
    }

    struct SMCPLimitData {
        // periphery:ignore
        var version: UInt16 = 0
        // periphery:ignore
        var length: UInt16 = 0
        // periphery:ignore
        var cpuPLimit: UInt32 = 0
        // periphery:ignore
        var gpuPLimit: UInt32 = 0
        // periphery:ignore
        var memPLimit: UInt32 = 0
    }

    struct SMCKeyInfoData {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        // periphery:ignore - kernel-layout mirror; see SMCVersion.
        var dataAttributes: UInt8 = 0
    }

    // swiftlint:disable large_tuple
    // (fixed 32-byte kernel layout; must stay a single tuple of 32 UInt8)
    typealias SMCBytes = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )
    // swiftlint:enable large_tuple

    struct SMCParamStruct {
        // periphery:ignore - kernel-layout fields; read by AppleSMC via
        // IOConnectCallStructMethod, which Periphery cannot see.
        var key: UInt32 = 0
        var vers = SMCVersion()
        var pLimitData = SMCPLimitData()
        var keyInfo = SMCKeyInfoData()
        // periphery:ignore - see `key`.
        var padding: UInt16 = 0
        var result: UInt8 = 0
        // periphery:ignore - see `key`.
        var status: UInt8 = 0
        // periphery:ignore - see `key`.
        var data8: UInt8 = 0
        // periphery:ignore - see `key`.
        var data32: UInt32 = 0
        // periphery:ignore - see `key`.
        var bytes: SMCBytes = (
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        )
    }

    private static let kSMCHandleYPCEvent: UInt32 = 2
    private static let kSMCWriteKey: UInt8 = 6
    private static let kSMCGetKeyInfo: UInt8 = 9

    public static func fourCC(_ code: String) -> UInt32 {
        precondition(code.utf8.count == 4, "SMC keys are 4 characters")
        return code.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func withConnection<T>(_ body: (io_connect_t) throws -> T) throws -> T {
        guard MemoryLayout<SMCParamStruct>.stride == 80 else {
            throw SMCError.unexpectedLayout(MemoryLayout<SMCParamStruct>.stride)
        }
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard kr == kIOReturnSuccess else { throw SMCError.openFailed(kr) }
        defer { IOServiceClose(connection) }
        return try body(connection)
    }

    private static func call(_ connection: io_connect_t,
                             _ input: SMCParamStruct) throws -> SMCParamStruct {
        var input = input
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let kr = IOConnectCallStructMethod(
            connection,
            kSMCHandleYPCEvent,
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outputSize
        )
        guard kr == kIOReturnSuccess else { throw SMCError.callFailed(kr) }
        guard output.result == 0 else { throw SMCError.smcResult(output.result) }
        return output
    }

    public static func keyInfo(_ key: String) throws -> (size: UInt32, type: String) {
        try withConnection { connection in
            var request = SMCParamStruct()
            request.key = fourCC(key)
            request.data8 = kSMCGetKeyInfo
            let reply = try call(connection, request)
            let t = reply.keyInfo.dataType
            let type = String(
                bytes: [
                    UInt8(t >> 24 & 0xff), UInt8(t >> 16 & 0xff),
                    UInt8(t >> 8 & 0xff), UInt8(t & 0xff)
                ],
                encoding: .ascii
            ) ?? "????"
            return (reply.keyInfo.dataSize, type)
        }
    }

    /// Writes a single-byte SMC key. Requires root.
    public static func writeByte(_ key: String, _ value: UInt8) throws {
        try withConnection { connection in
            var info = SMCParamStruct()
            info.key = fourCC(key)
            info.data8 = kSMCGetKeyInfo
            let infoReply = try call(connection, info)

            var request = SMCParamStruct()
            request.key = fourCC(key)
            request.data8 = kSMCWriteKey
            request.keyInfo.dataSize = infoReply.keyInfo.dataSize
            request.bytes.0 = value
            _ = try call(connection, request)
        }
    }

    /// A persistent SMC connection. Opens the AppleSMC service once and reuses
    /// the connection for many reads/writes — the one-shot API above pays an
    /// IOServiceGetMatchingService / IOServiceOpen / IOServiceClose round-trip
    /// on every call, which matters for the daemon's recurring re-assert.
    /// Key info is cached after the first lookup. Not thread-safe; call from a
    /// single thread (the daemon only touches it from the main run loop).
    public final class Connection {
        private var connection: io_connect_t = 0
        private let service: io_service_t
        private var keyInfoCache: [String: UInt32] = [:]

        public init() throws {
            guard MemoryLayout<SMCParamStruct>.stride == 80 else {
                throw SMCError.unexpectedLayout(MemoryLayout<SMCParamStruct>.stride)
            }
            let service = IOServiceGetMatchingService(
                kIOMainPortDefault,
                IOServiceMatching("AppleSMC")
            )
            guard service != 0 else { throw SMCError.serviceNotFound }
            self.service = service
            var conn: io_connect_t = 0
            let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
            guard kr == kIOReturnSuccess else {
                IOObjectRelease(service)
                throw SMCError.openFailed(kr)
            }
            self.connection = conn
        }

        deinit {
            if connection != 0 {
                IOServiceClose(connection)
            }
            IOObjectRelease(service)
        }

        public func writeByte(_ key: String, _ value: UInt8) throws {
            var request = SMCParamStruct()
            request.key = fourCC(key)
            request.data8 = kSMCWriteKey
            request.keyInfo.dataSize = try keyInfoSize(key)
            request.bytes.0 = value
            _ = try call(request)
        }

        private func keyInfoSize(_ key: String) throws -> UInt32 {
            if let size = keyInfoCache[key] { return size }
            var request = SMCParamStruct()
            request.key = fourCC(key)
            request.data8 = kSMCGetKeyInfo
            let reply = try call(request)
            keyInfoCache[key] = reply.keyInfo.dataSize
            return reply.keyInfo.dataSize
        }

        private func call(_ input: SMCParamStruct) throws -> SMCParamStruct {
            var input = input
            var output = SMCParamStruct()
            var outputSize = MemoryLayout<SMCParamStruct>.stride
            let kr = IOConnectCallStructMethod(
                connection,
                kSMCHandleYPCEvent,
                &input,
                MemoryLayout<SMCParamStruct>.stride,
                &output,
                &outputSize
            )
            guard kr == kIOReturnSuccess else { throw SMCError.callFailed(kr) }
            guard output.result == 0 else { throw SMCError.smcResult(output.result) }
            return output
        }
    }
}

/// MagSafe LED control key on Apple Silicon MacBooks with MagSafe 3.
public enum MagSafeLED {
    public static let key = "ACLC"

    public enum Color: UInt8 {
        case system = 0
        case off = 1
        case green = 3
        case amber = 4
    }

    public static func set(_ color: Color) throws {
        try SMC.writeByte(key, color.rawValue)
    }

    /// Writes the LED color over a persistent connection (no open/close churn).
    public static func set(_ color: Color, using connection: SMC.Connection) throws {
        try connection.writeByte(key, color.rawValue)
    }

    public static func isSupported() -> Bool {
        (try? SMC.keyInfo(key)) != nil
    }
}

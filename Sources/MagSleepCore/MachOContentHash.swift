import CryptoKit
import Foundation

/// Signing-independent content hash of a Mach-O executable.
///
/// The natural "is this the same binary?" identifier — the code-signing CDHash —
/// is not stable across machines whose `codesign` versions differ: re-signing
/// the *identical* code on another toolchain recomputes the CodeDirectory and
/// yields a different cdhash. That shipped as a 1.3.2 regression that falsely
/// rejected legitimate helper updates (CI-signed binary, re-signed locally).
///
/// Instead this hashes the binary's actual content — everything up to the code
/// signature — with the two load-command fields that re-signing legitimately
/// rewrites neutralized (`__LINKEDIT`'s `filesize` and `LC_CODE_SIGNATURE`'s
/// `datasize`, both of which just track the signature's size), and with the
/// signature blob itself (everything from `dataoff` on) excluded. Two binaries
/// built from the same code therefore hash equal regardless of who signed
/// them; any real code change changes the hash.
public enum MachOContentHash {
    /// Returns the hex SHA-256 of a Mach-O's content, or nil when the file
    /// can't be read or isn't a supported (thin arm64, or fat containing
    /// arm64) Mach-O.
    public static func hexSHA256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return hexSHA256(of: data)
    }

    public static func hexSHA256(of data: Data) -> String? {
        guard let slice = arm64Slice(in: data) else { return nil }
        guard slice.count >= 32, uint32(slice, 0) == 0xfeedfacf else { return nil } // MH_MAGIC_64
        let ncmds = uint32(slice, 16)
        var offset = 32
        var linkEditFilesize: Range<Int>?
        var codeSignatureDatasize: Range<Int>?
        var dataOff: Int?
        for _ in 0..<ncmds {
            guard offset + 8 <= slice.count else { return nil }
            let cmd = uint32(slice, offset)
            let cmdsize = Int(uint32(slice, offset + 4))
            guard cmdsize >= 8, offset + cmdsize <= slice.count else { return nil }
            switch cmd {
            case 0x19: // LC_SEGMENT_64
                if segname(slice, at: offset + 8) == "__LINKEDIT" {
                    // filesize (8 bytes) sits at +48 within the command.
                    linkEditFilesize = (offset + 48)..<(offset + 56)
                }
            case 0x1d: // LC_CODE_SIGNATURE
                // dataoff at +8; datasize (4 bytes) at +12 within the command.
                dataOff = Int(uint32(slice, offset + 8))
                codeSignatureDatasize = (offset + 12)..<(offset + 16)
            default:
                break
            }
            offset += cmdsize
        }

        // Hash everything before the signature blob, with the two
        // signature-tracking load-command fields zeroed.
        let end = dataOff ?? slice.count
        guard end > 0, end <= slice.count else { return nil }
        var bytes = [UInt8](slice[..<end])
        if let range = linkEditFilesize, range.upperBound <= bytes.count {
            for i in range { bytes[i] = 0 }
        }
        if let range = codeSignatureDatasize, range.upperBound <= bytes.count {
            for i in range { bytes[i] = 0 }
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Returns the thin arm64 slice of the file (the whole file when it is
    /// already thin), or nil for unsupported magic / a fat file with no arm64.
    private static func arm64Slice(in data: Data) -> Data? {
        guard data.count >= 4 else { return nil }
        let magic = uint32(data, 0)
        if magic == 0xfeedfacf { // MH_MAGIC_64 — already thin
            return data
        }
        if magic == 0xcafebabe || magic == 0xcafebabf { // FAT_MAGIC / FAT_MAGIC_64
            guard data.count >= 8 else { return nil }
            let nfat = uint32(data, 4)
            let entryWidth = magic == 0xcafebabf ? 20 : 16
            var entryOffset = 8
            for _ in 0..<nfat {
                guard entryOffset + entryWidth <= data.count else { return nil }
                let cputype = uint32(data, entryOffset)
                let offset = Int(uint32(data, entryOffset + 8))
                let size = Int(uint32(data, entryOffset + 12))
                if cputype == 0x0100_000c { // CPU_TYPE_ARM64
                    guard offset + size <= data.count else { return nil }
                    return data.subdata(in: offset..<(offset + size))
                }
                entryOffset += entryWidth
            }
        }
        return nil
    }

    private static func segname(_ data: Data, at offset: Int) -> String {
        guard offset + 16 <= data.count else { return "" }
        return String(bytes: data[offset..<(offset + 16)].prefix { $0 != 0 }, encoding: .utf8) ?? ""
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return data.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        }
    }
}

#!/usr/bin/env swift
// Verifies that the Sparkle EdDSA signing key (SPARKLE_EDDSA_KEY) derives the
// public key embedded in the app (packaging/Info.plist → SUPublicEDKey). A
// mismatch means every Sparkle client would silently reject the signed appcast,
// so the release must fail before anything is signed or published.
//
// Usage: swift verify-sparkle-key.swift [path-to-Info.plist]
// Reads SPARKLE_EDDSA_KEY from the environment (never from argv — GitHub masks
// secret values in env, and argv would leak into the process list).
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard let key = ProcessInfo.processInfo.environment["SPARKLE_EDDSA_KEY"]?
    .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
    fail("verify-sparkle-key: SPARKLE_EDDSA_KEY is not set")
}
guard let seed = Data(base64Encoded: key), seed.count == 32 else {
    fail("verify-sparkle-key: SPARKLE_EDDSA_KEY is not a 32-byte Ed25519 seed")
}
let plistPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "packaging/Info.plist"
guard let plistData = FileManager.default.contents(atPath: plistPath),
      let plist = (try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)) as? [String: Any],
      let expected = plist["SUPublicEDKey"] as? String else {
    fail("verify-sparkle-key: could not read SUPublicEDKey from \(plistPath)")
}
guard let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
    fail("verify-sparkle-key: could not build an Ed25519 key from the seed")
}
let derived = privateKey.publicKey.rawRepresentation.base64EncodedString()
guard derived == expected else {
    fail(
        "verify-sparkle-key: SPARKLE_EDDSA_KEY does not match SUPublicEDKey in \(plistPath)\n"
        + "  derived : \(derived)\n"
        + "  expected: \(expected)"
    )
}
print("Sparkle EdDSA key matches the embedded SUPublicEDKey")

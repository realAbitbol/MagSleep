import Foundation

/// Pure peer-authorization decision for the daemon's socket server.
///
/// The daemon's socket is `0666` so the app (running as the console user) can
/// connect; authorization is therefore decided here, per request. The rule is
/// deliberately fail-closed: root is always accepted, the current console user
/// is accepted, and when the console user cannot be determined the request is
/// **rejected** rather than authorizing an arbitrary local process.
///
/// Kept in the shared core (free of the daemon's SystemConfiguration lookup) so
/// the rule can be unit-tested directly.
public enum PeerAuthorization {
    /// - Parameters:
    ///   - peerUID: the connecting peer's uid from `getpeereid`, or nil when it
    ///     could not be read.
    ///   - consoleUID: the current console user's uid, or nil when it could not
    ///     be determined.
    public static func isAllowed(peerUID: uid_t?, consoleUID: uid_t?) -> Bool {
        guard let peerUID else { return false }
        if peerUID == 0 { return true } // root
        guard let consoleUID else { return false } // fail closed
        return peerUID == consoleUID
    }
}

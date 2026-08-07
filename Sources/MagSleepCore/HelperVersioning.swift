/// Pure helper-versioning decision logic, shared by the app and covered by
/// unit tests. The "version" here is the **helper revision** — the last commit
/// touching helper-affecting code — recorded in `helper-version.txt` by
/// `install-helper.sh` at install time.
public enum HelperVersioning {
    /// True when the helper must be reinstalled: no revision is recorded on
    /// disk (or it is empty), or it differs from the one the app bundles.
    /// Note: the caller decides whether the helper is installed at all; this
    /// function only answers "does the recorded revision match what we ship?".
    public static func shouldReinstall(installedRevision: String?, bundledRevision: String) -> Bool {
        guard let installedRevision, !installedRevision.isEmpty else { return true }
        return installedRevision != bundledRevision
    }

    /// True when the helper's *binary* differs from the one the app bundles.
    /// Content hashes are signing-independent (see `MachOContentHash`), so this
    /// stays correct across machines whose codesign versions differ — unlike
    /// the recorded revision, which can drift from the installed binary (a
    /// failed install can leave the new binary in place while keeping the old
    /// version file). Returns false when either hash is unavailable, so callers
    /// fall back to the revision comparison before asking this function.
    public static func shouldReinstall(installedContentHash: String?, bundledContentHash: String?) -> Bool {
        guard let installedContentHash, let bundledContentHash else { return false }
        return installedContentHash != bundledContentHash
    }
}

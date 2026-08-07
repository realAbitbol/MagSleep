import AppKit
import Foundation
import Sparkle

/// Wraps Sparkle's programmatic updater (SPUUpdater).
///
/// - "Check for Updates…" menu item → `checkForUpdates()` (user-initiated UI).
/// - Automatic checks twice a day via `automaticallyChecksForUpdates` +
///   `updateCheckInterval` (12h), replacing the previous custom checker.
///
/// Signing model: Sparkle accepts updates whose EdDSA public key matches the
/// host's (identity rotation allowed), so the app can stay ad-hoc signed —
/// see SUUpdateValidator's `passesBasicUpdatePolicyWith…` + the "old and new
/// (Ed)DSA public keys are the same and valid" acceptance rule.
final class UpdateManager: NSObject, SPUUpdaterDelegate {
    // Note: all interaction happens on the main thread (menu actions and
    // Sparkle's UI); the class is intentionally not @MainActor-annotated so it
    // can be created from the non-isolated AppKit entry points.
    private var updater: SPUUpdater?
    private let userDriver: SPUStandardUserDriver
    /// Whether Sparkle started successfully. "Check for Updates…" no-ops
    /// silently when nil, so expose the failure for the menu to react to.
    private(set) var isAvailable = false

    /// Where the appcast lives. A static URL served over HTTPS; committed to
    /// the repo and served from GitHub raw for the initial test.
    static let feedURL = "https://raw.githubusercontent.com/realAbitbol/MagSleep/master/appcast/appcast.xml"

    override init() {
        userDriver = SPUStandardUserDriver(hostBundle: Bundle.main, delegate: nil)
        super.init()
    }

    func start() {
        let updater = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: userDriver,
            delegate: self
        )
        // Configure the automatic-check settings BEFORE start() so the first
        // run adopts them (Sparkle recommends configuring before starting).
        updater.automaticallyChecksForUpdates = true
        updater.updateCheckInterval = 12 * 60 * 60
        do {
            try updater.start()
        } catch {
            NSLog("MagSleep: Sparkle failed to start: \(error)")
            isAvailable = false
            return
        }
        self.updater = updater
        isAvailable = true
    }

    /// "Check for Updates…" menu action (shows Sparkle's update UI).
    func checkForUpdates() {
        updater?.checkForUpdates()
    }

    // MARK: - SPUUpdaterDelegate

    func feedURLString(for updater: SPUUpdater) -> String? {
        Self.feedURL
    }
}

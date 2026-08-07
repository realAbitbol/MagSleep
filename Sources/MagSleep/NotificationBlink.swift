import AppKit
import ApplicationServices
import Foundation
import MagSleepCore

/// Notification Blink: watches the Notification Center's accessibility tree
/// and asks the daemon to blink the LED green when a new notification appears.
///
/// There is no push signal for incoming notifications (the Notification Center
/// is a closed component), but real notification-forwarding apps read the
/// Notification Center's UI **through the Accessibility API**: they locate the
/// notificationcenterui/controlcenter process, snapshot its accessibility
/// tree, and detect notification nodes. That requires Accessibility
/// permission (heavier than notification permission — hence the System
/// Settings pane on refusal). Enabling requests it; if the user refuses, the
/// toggle stays off (unchecked) and can be retried later. The tree-node
/// detection is pure (`NotificationNodeDetector` in MagSleepCore) and verified
/// against Sonoma-era and Tahoe-era tree fixtures (macOS 14–26).
final class NotificationBlink {
    /// Posted whenever the toggle's state changes, so the menu can refresh.
    static let stateDidChange = Notification.Name("MagSleepNotificationBlinkStateDidChange")

    private enum DefaultsKey {
        static let enabled = "NotificationBlinkEnabled"
    }

    private let defaults = UserDefaults.standard
    private let helper: HelperManager
    private var timer: Timer?
    private var reauthTimer: Timer?
    /// Best-effort observer on the undocumented `com.apple.accessibility.api`
    /// distributed notification (see `startPolling`).
    private var permissionObserver: NSObjectProtocol?
    private var knownKeys = Set<String>()
    private var isSeeded = false
    /// Poll interval: short enough to feel live, long enough to stay cheap.
    /// Each poll is a bounded AX snapshot (0.2s messaging timeout).
    private let pollInterval: TimeInterval = 2.5
    /// How often to re-check that Accessibility permission is still granted
    /// (a revocation in System Settings would otherwise leave the toggle on
    /// while blinks silently stop).
    private let reauthInterval: TimeInterval = 60
    /// Bounds for the AX tree walk, so a huge tree can never stall a poll.
    private let maxDepth = 8
    private let maxChildrenPerNode = 48

    private(set) var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: DefaultsKey.enabled)
            // Post with `object: self` so object-filtered observers fire.
            NotificationCenter.default.post(name: Self.stateDidChange, object: self)
        }
    }

    init(helper: HelperManager) {
        self.helper = helper
        self.isEnabled = defaults.bool(forKey: DefaultsKey.enabled)
    }

    /// Called at startup: if the toggle was left on, resume polling only when
    /// Accessibility permission is still granted. If it was revoked in System
    /// Settings, flip the toggle off silently — never prompt at launch (the
    /// prompt is reserved for the user explicitly toggling it on).
    func start() {
        guard isEnabled else { return }
        if hasAccessibilityPermission(prompt: false) {
            startPolling()
        } else {
            stop()
        }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            requestPermissionThenStart()
        } else {
            stop()
        }
    }

    // MARK: - Permission (Accessibility, not notification authorization)

    /// True when this process can actually read the accessibility tree.
    ///
    /// Follows the pattern production apps use (e.g. Clipy's Accessibility
    /// helper): `AXIsProcessTrustedWithOptions` can return **false for
    /// unsigned / ad-hoc-signed builds even when the user granted access**, so
    /// the API's word is not trusted on its own. A practical read of the
    /// system-wide AX element confirms trust: `.success` (an app has focus and
    /// the read worked) or `.noValue` (no app has focus, but the API accepted
    /// the call) both mean trust is granted; `.apiDisabled`/`.cannotComplete`
    /// mean it is not.
    private func hasAccessibilityPermission(prompt: Bool) -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if accessibilityTrusted() {
            return true
        }
        guard prompt else { return false }
        // Show the system dialog; its return value can also be stale/lying for
        // ad-hoc builds (omi documents the same on macOS 26), so re-verify with
        // the practical read after a short settle (Loop waits 250 ms for the
        // same reason).
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        Thread.sleep(forTimeInterval: 0.3)
        return accessibilityTrusted()
    }

    private func accessibilityTrusted() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if AXIsProcessTrustedWithOptions([promptKey: false] as CFDictionary) {
            return true
        }
        // Ad-hoc builds: the API can lie, so verify with a practical read.
        // Only .apiDisabled (or a hard error that survives retries) means AX
        // is genuinely disabled — .cannotComplete/.failure are transient
        // (e.g. mid app-switch) and must not be treated as "not trusted",
        // which would re-prompt a user who already granted access.
        for _ in 0..<3 {
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(
                AXUIElementCreateSystemWide(),
                kAXFocusedApplicationAttribute as CFString,
                &value
            )
            switch result {
            case .apiDisabled, .invalidUIElement, .attributeUnsupported:
                return false
            case .cannotComplete, .failure:
                Thread.sleep(forTimeInterval: 0.05)
                continue
            default: // .success / .noValue — access works
                return true
            }
        }
        return false
    }

    private func openAccessibilitySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
        ]
        for rawURL in urls {
            guard let url = URL(string: rawURL) else { continue }
            if NSWorkspace.shared.open(url) { return }
        }
    }

    private func requestPermissionThenStart() {
        if hasAccessibilityPermission(prompt: false) {
            startPolling()
            return
        }
        // Prompts the system dialog; if the user refuses there is no callback,
        // so open the Settings pane AND explain. The dialog is sometimes
        // suppressed by a previously cached denial in System Settings, which
        // leaves the user wondering why nothing happened — hence the alert.
        if hasAccessibilityPermission(prompt: true) {
            startPolling()
            return
        }
        openAccessibilitySettings()
        let alert = NSAlert()
        alert.messageText = "MagSleep needs Accessibility access"
        alert.informativeText = "To read the Notification Center for Notification Blink, "
            + "MagSleep needs permission in System Settings → Privacy & Security → Accessibility. "
            + "If the system prompt didn't appear, enable MagSleep there (add it with the + button "
            + "if needed), then enable Notification Blink again."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Polling

    private func startPolling() {
        isEnabled = true
        isSeeded = false
        // Seed with the current tree so pre-existing notifications do not
        // trigger a blink — and only start polling once the seed lands, so a
        // poll can never run against an empty seed and blink spuriously.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let keys = self?.currentNotificationKeys() ?? []
            DispatchQueue.main.async {
                guard let self else { return }
                self.knownKeys = keys
                self.isSeeded = true
            }
        }
        timer?.invalidate()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // Re-check permission: a revocation should stop the polling and flip
        // the toggle off rather than silently no-op forever. Two triggers —
        // a slow backstop timer (the reliable path) and the best-effort
        // distributed notification (the pattern production apps like
        // alt-tab / WhichSpace use for instant reaction; note it can silently
        // fail for ad-hoc-signed binaries on macOS 15+, per alt-tab).
        reauthTimer?.invalidate()
        let reauthTimer = Timer(timeInterval: reauthInterval, repeats: true) { [weak self] _ in
            self?.verifyPermissionStillGranted()
        }
        RunLoop.main.add(reauthTimer, forMode: .common)
        self.reauthTimer = reauthTimer
        if let permissionObserver {
            DistributedNotificationCenter.default().removeObserver(permissionObserver)
        }
        permissionObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.verifyPermissionStillGranted()
        }
    }

    /// Re-checks that Accessibility permission is still granted; a revocation
    /// stops polling and flips the toggle off.
    private func verifyPermissionStillGranted() {
        if !hasAccessibilityPermission(prompt: false) {
            stop()
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        reauthTimer?.invalidate()
        reauthTimer = nil
        if let permissionObserver {
            DistributedNotificationCenter.default().removeObserver(permissionObserver)
        }
        permissionObserver = nil
        isEnabled = false
    }

    private func poll() {
        guard isEnabled else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self, let current = self.currentNotificationKeys() else { return }
            DispatchQueue.main.async {
                guard self.isEnabled, self.isSeeded else { return }
                let newOnes = current.subtracting(self.knownKeys)
                self.knownKeys = current
                if !newOnes.isEmpty {
                    self.helper.sendBlink()
                }
            }
        }
    }

    // MARK: - Accessibility snapshot

    /// Captures the current Notification Center AX tree and reduces it to the
    /// detector's stable keys, or nil if the Notification Center is not
    /// running (its process appears once the system has shown any UI). Runs
    /// off-main; AX calls are blocking-ish (0.2s messaging timeout) so they
    /// must never run on the main thread.
    private func currentNotificationKeys() -> Set<String>? {
        guard let snapshot = snapshotNotificationCenter() else { return nil }
        return NotificationNodeDetector.notificationKeys(in: snapshot)
    }

    private func snapshotNotificationCenter() -> AccessibilityNode? {
        guard let app = notificationCenterApplication() else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.2)
        return snapshot(element: root, depth: 0)
    }

    private func notificationCenterApplication() -> NSRunningApplication? {
        let bundleIdentifiers = [
            "com.apple.notificationcenterui",
            "com.apple.controlcenter",
        ]
        for bundleIdentifier in bundleIdentifiers {
            if let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .first(where: { !$0.isTerminated }) {
                return application
            }
        }
        // Fallback for renamed UI (e.g. localized process names).
        return NSWorkspace.shared.runningApplications.first {
            !$0.isTerminated && $0.localizedName == "NotificationCenter"
        }
    }

    private func snapshot(element: AXUIElement, depth: Int) -> AccessibilityNode {
        let children: [AccessibilityNode]
        if depth >= maxDepth {
            children = []
        } else {
            children = childElements(for: element, depth: depth)
                .prefix(maxChildrenPerNode)
                .map { snapshot(element: $0, depth: depth + 1) }
        }
        return AccessibilityNode(
            role: stringValue(for: kAXRoleAttribute, element: element),
            subrole: stringValue(for: kAXSubroleAttribute, element: element),
            title: stringValue(for: kAXTitleAttribute, element: element),
            value: stringValue(for: kAXValueAttribute, element: element),
            nodeDescription: stringValue(for: kAXDescriptionAttribute, element: element),
            identifier: stringValue(for: kAXIdentifierAttribute, element: element),
            children: children
        )
    }

    private func childElements(for element: AXUIElement, depth: Int) -> [AXUIElement] {
        var attributes = [kAXChildrenAttribute]
        if depth == 0 {
            attributes.insert(kAXWindowsAttribute, at: 0)
        }
        var allChildren: [AXUIElement] = []
        for attribute in attributes {
            allChildren.append(contentsOf: arrayValue(for: attribute, element: element))
        }
        return allChildren
    }

    private func stringValue(for attribute: String, element: AXUIElement) -> String? {
        var rawValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        guard error == .success, let rawValue, CFGetTypeID(rawValue) == CFStringGetTypeID() else {
            return nil
        }
        return rawValue as? String
    }

    private func arrayValue(for attribute: String, element: AXUIElement) -> [AXUIElement] {
        var rawValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        guard error == .success, let rawValue, CFGetTypeID(rawValue) == CFArrayGetTypeID() else {
            return []
        }
        return rawValue as? [AXUIElement] ?? []
    }

    deinit {
        timer?.invalidate()
        reauthTimer?.invalidate()
        if let permissionObserver {
            DistributedNotificationCenter.default().removeObserver(permissionObserver)
        }
    }
}

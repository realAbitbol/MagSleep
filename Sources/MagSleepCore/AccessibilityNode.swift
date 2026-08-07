import Foundation

/// Simplified accessibility node model: produced by the live Notification
/// Center AX snapshot (app side) and decodable from a debug dump, so the
/// notification detector is pure and fixture-testable.
public struct AccessibilityNode: Codable, Equatable {
    public var role: String?
    public var subrole: String?
    public var title: String?
    public var value: String?
    public var nodeDescription: String?
    // periphery:ignore - public API, decoded from the JSON debug dump
    public var identifier: String?
    public var children: [AccessibilityNode]

    public init(
        role: String? = nil,
        subrole: String? = nil,
        title: String? = nil,
        value: String? = nil,
        nodeDescription: String? = nil,
        identifier: String? = nil,
        children: [AccessibilityNode] = []
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        self.nodeDescription = nodeDescription
        self.identifier = identifier
        self.children = children
    }
}

/// Detects notification nodes in the Notification Center's accessibility
/// tree. Pure + fixture-tested; the live snapshot is produced by
/// NotificationBlink, which diffs these keys to blink on new notifications.
///
/// Heuristics adapted from real notification-forwarding apps (the Bark
/// bridge): a notification is a container node whose subrole is an explicit
/// Notification Center banner marker, or a container with 2–6 leaf texts
/// (source + title + body), excluding known chrome ("Close", "Options"…).
public enum NotificationNodeDetector {
    private static let containerRoles: Set<String> = [
        "AXApplication", "AXGroup", "AXList", "AXRow", "AXScrollArea", "AXWindow",
    ]
    private static let bannerSubroles: Set<String> = [
        "AXNotificationCenterBanner",
        // The stack is the aggregate container — only the singular banner
        // subrole marks a notification itself; banners inside a stack are
        // caught by the 2–6 text rule (or their own singular subrole).
    ]
    private static let ignoredTexts: Set<String> = [
        "Notification Center", "Close", "Options", "Clear", "Clear All",
        "Earlier Today", "Now", "No Older Notifications",
    ]

    /// Stable keys for the notification nodes currently visible in the tree.
    /// A new key between polls means a new notification arrived.
    public static func notificationKeys(in root: AccessibilityNode) -> Set<String> {
        var keys = Set<String>()
        collect(root: root, into: &keys)
        return keys
    }

    private static func collect(root: AccessibilityNode, into keys: inout Set<String>) {
        if let key = key(for: root) {
            keys.insert(key)
        }
        for child in root.children {
            collect(root: child, into: &keys)
        }
    }

    private static func key(for node: AccessibilityNode) -> String? {
        guard let role = node.role, containerRoles.contains(role) else { return nil }
        let texts = leafTexts(in: node)
            .compactMap(clean)
            .filter { !ignoredTexts.contains($0) }
            // Relative timestamps ("12:30", "5m ago", "2 hours ago") appear in
            // the tree on some macOS versions and would both pollute keys and
            // make a key change as the age text updates — dropping them keeps
            // detection stable across macOS 14…26 tree shapes.
            .filter { !looksLikeRelativeTime($0) }
        guard !texts.isEmpty else { return nil }
        if let subrole = node.subrole, bannerSubroles.contains(subrole) {
            return texts.joined(separator: " ")
        }
        guard (2...6).contains(texts.count) else { return nil }
        let joined = texts.joined(separator: " ")
        guard joined.count <= 400 else { return nil }
        return joined
    }

    private static func leafTexts(in node: AccessibilityNode) -> [String] {
        if node.children.isEmpty {
            return [node.title, node.value, node.nodeDescription].compactMap { $0 }
        }
        return node.children.flatMap { leafTexts(in: $0) }
    }

    private static func clean(_ text: String) -> String? {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// "12:30", "5m ago", "2 hours ago", "now" — age/clock text that some
    /// macOS versions expose on notification nodes. Not part of the message.
    private static func looksLikeRelativeTime(_ text: String) -> Bool {
        let patterns = [
            #"^\d{1,2}:\d{2}$"#,
            #"^\d+\s?(m|min|mins|minute|minutes|h|hr|hrs|hour|hours|s|sec|secs|second|seconds)\s?(ago)?$"#,
            #"^now$"#,
        ]
        return patterns.contains { pattern in
            text.range(of: pattern, options: .regularExpression) != nil
        }
    }
}

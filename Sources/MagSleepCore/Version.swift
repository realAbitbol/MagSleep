import Foundation

/// Minimal numeric version comparison for update checks (e.g. "1.0.5").
/// Handles dotted numeric versions of any length; missing components count as
/// zero. Non-numeric segments are ignored.
public struct SemanticVersion: Equatable, Comparable {
    public let components: [Int]

    public init(_ string: String) {
        components = string
            .split(separator: ".")
            .compactMap { Int($0) }
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for i in 0..<count {
            let a = i < lhs.components.count ? lhs.components[i] : 0
            let b = i < rhs.components.count ? rhs.components[i] : 0
            if a != b { return a < b }
        }
        return false
    }
}

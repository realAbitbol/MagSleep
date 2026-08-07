import Foundation

/// Parses the output of `corebrightnessdiag sunschedule` (best-effort — the
/// tool and its format are undocumented and it may move or vanish between
/// macOS releases; callers must degrade gracefully when parsing fails).
public struct SunSchedule {
    public let sunrise: Date
    public let sunset: Date

    /// `corebrightnessdiag` prints lines like:
    ///     sunrise = "2026-08-07 04:35:54 +0000";
    ///     sunset = "2026-08-07 18:55:56 +0000";
    /// The key is anchored to a line start so a future casing change of
    /// `nextSunrise`/`previousSunrise` can't be matched by mistake.
    public init?(parsing text: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"

        func extract(_ key: String) -> Date? {
            // Anchored to a line start (allowing indentation) so a future
            // casing change of next/previousSunrise can't be matched.
            let pattern = "(^|\n)\\s*\(key) = \""
            guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
            let after = text[range.upperBound...]
            guard let end = after.firstIndex(of: "\"") else { return nil }
            return formatter.date(from: String(after[..<end]))
        }

        guard let sunrise = extract("sunrise"), let sunset = extract("sunset") else { return nil }
        self.sunrise = sunrise
        self.sunset = sunset
    }
}

/// Core day/night decision shared by the daemon: night = between sunset and
/// sunrise when a schedule is available, otherwise a local-time fallback
/// window. Kept in the core library so the boundary semantics are testable.
public enum DayNight {
    /// Night when `now` is between sunset and sunrise (absolute instants — the
    /// tool prints UTC). Without a schedule, falls back to a local-time window
    /// (default 20:00–07:00) which may wrap past midnight.
    public static func isNight(
        now: Date = Date(),
        schedule: SunSchedule?,
        fallbackWindow: (start: Int, end: Int)? = (20, 7)
    ) -> Bool {
        if let schedule {
            return now < schedule.sunrise || now >= schedule.sunset
        }
        guard let fallbackWindow else { return false }
        let hour = Calendar.current.component(.hour, from: now)
        if fallbackWindow.start <= fallbackWindow.end {
            return hour >= fallbackWindow.start && hour < fallbackWindow.end
        }
        return hour >= fallbackWindow.start || hour < fallbackWindow.end
    }
}

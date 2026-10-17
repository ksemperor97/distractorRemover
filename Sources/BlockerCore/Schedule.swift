import Foundation

/// A weekly time window. Days use Monday = 0 … Sunday = 6, matching the v1 config.
/// When `end <= start` the window runs overnight into the following day.
public struct ScheduleWindow: Equatable, Hashable {
    public let days: [Int]
    public let start: Int
    public let end: Int

    public init?(days: [Int], start: Int, end: Int) {
        let cleaned = Array(Set(days)).sorted()
        guard !cleaned.isEmpty, cleaned.allSatisfy({ (0...6).contains($0) }),
              (0..<1440).contains(start), (0..<1440).contains(end), start != end
        else { return nil }
        self.days = cleaned
        self.start = start
        self.end = end
    }

    public init?(days: [Int], start: String, end: String) {
        guard let s = Self.parseTime(start), let e = Self.parseTime(end) else { return nil }
        self.init(days: days, start: s, end: e)
    }

    public var startText: String { Self.formatTime(start) }
    public var endText: String { Self.formatTime(end) }

    /// `"9:05"` / `"09:05"` → 545. Rejects anything else.
    public static func parseTime(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let h = Int(parts[0]), let m = Int(parts[1]), h < 24, m < 60
        else { return nil }
        return h * 60 + m
    }

    public static func formatTime(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    func contains(weekday: Int, minute: Int) -> Bool {
        if start < end {
            return days.contains(weekday) && start <= minute && minute < end
        }
        if days.contains(weekday) && minute >= start { return true }
        return days.contains((weekday + 6) % 7) && minute < end
    }
}

public struct Schedule: Equatable {
    public var enabled: Bool
    public var windows: [ScheduleWindow]

    public init(enabled: Bool = false, windows: [ScheduleWindow] = []) {
        self.enabled = enabled
        self.windows = windows
    }
}

public enum ScheduleMath {
    /// Monday = 0 … Sunday = 6, in the given calendar's time zone.
    public static func weekdayIndex(_ date: Date, calendar: Calendar) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7
    }

    public static func inAnyWindow(_ date: Date, _ windows: [ScheduleWindow], calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let weekday = weekdayIndex(date, calendar: calendar)
        return windows.contains { $0.contains(weekday: weekday, minute: minute) }
    }

    public static func isActive(
        _ date: Date, schedule: Schedule, overrideUntil: Date?, calendar: Calendar
    ) -> Bool {
        guard schedule.enabled, !schedule.windows.isEmpty else { return false }
        if let overrideUntil, date < overrideUntil { return false }
        return inAnyWindow(date, schedule.windows, calendar: calendar)
    }

    /// The next moment the derived schedule state flips, or `nil` if it never
    /// does within a week (always on / always off). State can only change at a
    /// window boundary or when the override ends, so only those are examined.
    public static func nextTransition(
        after date: Date, schedule: Schedule, overrideUntil: Date?, calendar: Calendar
    ) -> Date? {
        let current = isActive(date, schedule: schedule, overrideUntil: overrideUntil, calendar: calendar)
        var candidates = Set<Date>()
        if let overrideUntil { candidates.insert(overrideUntil) }
        let today = calendar.startOfDay(for: date)
        let boundaries = Set(schedule.windows.flatMap { [$0.start, $0.end] })
        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            for minute in boundaries {
                if let moment = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day) {
                    candidates.insert(moment)
                }
            }
        }
        return candidates.filter { $0 > date }.sorted().first {
            isActive($0, schedule: schedule, overrideUntil: overrideUntil, calendar: calendar) != current
        }
    }
}

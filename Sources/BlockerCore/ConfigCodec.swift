import Foundation

/// A configuration exists but cannot be read without risking data loss.
public struct ConfigLoadError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Reads and writes `config.json`, compatible with the v1.x Python app
/// (schema 1 with `manual_blocking`/`blocking`, and schema 2).
public enum ConfigCodec {
    public static func decode(_ data: Data) throws -> Config {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ConfigLoadError("The configuration file is damaged and was left unchanged: \(error.localizedDescription)")
        }
        guard let dict = object as? [String: Any] else {
            throw ConfigLoadError("The configuration file must contain a JSON object and was left unchanged.")
        }
        return try decode(dict)
    }

    static func decode(_ dict: [String: Any]) throws -> Config {
        // Sites: strict shape check, then canonicalize.
        let rawSites = nonNull(dict["sites"]) ?? [Any]()
        guard let siteList = rawSites as? [Any] else {
            throw ConfigLoadError("The configuration's sites value must be a list.")
        }
        var siteStrings: [String] = []
        for entry in siteList {
            guard let site = entry as? String, Domains.normalize(site) != nil else {
                throw ConfigLoadError("The configuration contains an invalid site entry.")
            }
            siteStrings.append(site)
        }

        // Schedule.
        let rawSchedule = nonNull(dict["schedule"]) ?? [String: Any]()
        guard let scheduleDict = rawSchedule as? [String: Any] else {
            throw ConfigLoadError("The configuration's schedule value must be an object.")
        }
        let rawWindows = nonNull(scheduleDict["windows"]) ?? [Any]()
        guard let windowList = rawWindows as? [Any] else {
            throw ConfigLoadError("The configuration's schedule windows must be a list.")
        }
        var windows: [ScheduleWindow] = []
        for (index, entry) in windowList.enumerated() {
            guard let window = decodeWindow(entry) else {
                throw ConfigLoadError("The configuration contains an invalid schedule window at position \(index + 1).")
            }
            windows.append(window)
        }
        let schedule = Schedule(
            enabled: truthy(scheduleDict["enabled"]) && !windows.isEmpty,
            windows: windows
        )

        // Override.
        var overrideUntil: Date?
        if let raw = nonNull(dict["schedule_override_until"]) {
            guard let text = raw as? String else {
                throw ConfigLoadError("The configuration contains an invalid schedule override.")
            }
            overrideUntil = parseLocalTimestamp(text)
        }

        let manual = dict["manual_enabled"] ?? dict["manual_blocking"] ?? dict["blocking"]
        return Config(
            sites: Domains.canonicalList(siteStrings),
            manualEnabled: truthy(manual),
            schedule: schedule,
            scheduleOverrideUntil: overrideUntil
        )
    }

    public static func encode(_ config: Config) throws -> Data {
        let dict: [String: Any] = [
            "schema_version": AppConstants.configSchemaVersion,
            "sites": config.sites,
            "manual_enabled": config.manualEnabled,
            "schedule": [
                "enabled": config.schedule.enabled,
                "windows": config.schedule.windows.map {
                    ["days": $0.days, "start": $0.startText, "end": $0.endText] as [String: Any]
                },
            ] as [String: Any],
            "schedule_override_until": config.scheduleOverrideUntil.map(formatLocalTimestamp) ?? NSNull(),
        ]
        return try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Helpers

    private static func decodeWindow(_ entry: Any) -> ScheduleWindow? {
        guard let dict = entry as? [String: Any],
              let rawDays = dict["days"] as? [Any], !rawDays.isEmpty,
              let start = dict["start"] as? String, let end = dict["end"] as? String
        else { return nil }
        var days: [Int] = []
        for value in rawDays {
            guard let day = integer(value), (0...6).contains(day) else { return nil }
            days.append(day)
        }
        return ScheduleWindow(days: days, start: start, end: end)
    }

    private static func integer(_ value: Any) -> Int? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let double = number.doubleValue
            return double == double.rounded() ? Int(double) : nil
        }
        if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private static func nonNull(_ value: Any?) -> Any? {
        value is NSNull ? nil : value
    }

    private static func truthy(_ value: Any?) -> Bool {
        switch value {
        case let number as NSNumber: return number.boolValue
        case let text as String: return !text.isEmpty
        case let list as [Any]: return !list.isEmpty
        case let dict as [String: Any]: return !dict.isEmpty
        default: return false
        }
    }

    /// The override is stored as local wall-clock time (`2026-07-13T18:00`),
    /// because schedules are local-time based. A time-zone suffix is ignored.
    public static func parseLocalTimestamp(_ text: String) -> Date? {
        let pattern = try! NSRegularExpression(
            pattern: "^(\\d{4})-(\\d{2})-(\\d{2})[T ](\\d{2}):(\\d{2})(?::(\\d{2}))?"
        )
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range) else { return nil }
        func group(_ i: Int) -> Int? {
            guard let r = Range(match.range(at: i), in: text) else { return nil }
            return Int(text[r])
        }
        var parts = DateComponents()
        parts.year = group(1)
        parts.month = group(2)
        parts.day = group(3)
        parts.hour = group(4)
        parts.minute = group(5)
        parts.second = group(6) ?? 0
        return Calendar.current.date(from: parts)
    }

    public static func formatLocalTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter.string(from: date)
    }
}

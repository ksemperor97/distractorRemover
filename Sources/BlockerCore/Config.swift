import Foundation

/// Persisted user intent. Everything else (whether the schedule is active,
/// which domains to block) is derived from it at a given moment.
public struct Config: Equatable {
    public var sites: [String]
    public var manualEnabled: Bool
    public var schedule: Schedule
    /// Pauses the schedule (not manual blocking) until this local time.
    public var scheduleOverrideUntil: Date?

    public init(
        sites: [String] = [],
        manualEnabled: Bool = false,
        schedule: Schedule = Schedule(),
        scheduleOverrideUntil: Date? = nil
    ) {
        self.sites = sites
        self.manualEnabled = manualEnabled
        self.schedule = schedule
        self.scheduleOverrideUntil = scheduleOverrideUntil
    }

    public enum ActiveReason: String {
        case none = "None", manual = "Manual", schedule = "Schedule", both = "Manual + Schedule"
    }

    /// The override, if it has not expired yet.
    public func activeOverride(at now: Date) -> Date? {
        guard let until = scheduleOverrideUntil, until > now else { return nil }
        return until
    }

    public func scheduleActive(at now: Date, calendar: Calendar = .current) -> Bool {
        ScheduleMath.isActive(now, schedule: schedule, overrideUntil: activeOverride(at: now), calendar: calendar)
    }

    public func blockingRequested(at now: Date, calendar: Calendar = .current) -> Bool {
        manualEnabled || scheduleActive(at: now, calendar: calendar)
    }

    public func desiredBlocking(at now: Date, calendar: Calendar = .current) -> Bool {
        !sites.isEmpty && blockingRequested(at: now, calendar: calendar)
    }

    /// Exactly what the managed hosts section should contain right now.
    public func blockDomains(at now: Date, calendar: Calendar = .current) -> [String] {
        desiredBlocking(at: now, calendar: calendar) ? Domains.expanded(sites) : []
    }

    public func activeReason(at now: Date, calendar: Calendar = .current) -> ActiveReason {
        switch (manualEnabled, scheduleActive(at: now, calendar: calendar)) {
        case (true, true): return .both
        case (true, false): return .manual
        case (false, true): return .schedule
        case (false, false): return .none
        }
    }

    public func nextScheduleChange(after now: Date, calendar: Calendar = .current) -> Date? {
        guard schedule.enabled else { return nil }
        return ScheduleMath.nextTransition(
            after: now, schedule: schedule, overrideUntil: activeOverride(at: now), calendar: calendar
        )
    }

    /// Drops an expired override and a schedule that has no windows.
    public func normalized(at now: Date) -> Config {
        var copy = self
        copy.scheduleOverrideUntil = activeOverride(at: now)
        if copy.schedule.windows.isEmpty { copy.schedule.enabled = false }
        return copy
    }

    // MARK: - Transitions used by the UI

    /// Manual off; an active schedule window is paused until it ends. A
    /// schedule that never turns off on its own is disabled instead.
    public func turningOffAll(at now: Date, calendar: Calendar = .current) -> Config {
        var copy = self
        copy.manualEnabled = false
        if scheduleActive(at: now, calendar: calendar) {
            let end = ScheduleMath.nextTransition(
                after: now, schedule: schedule, overrideUntil: nil, calendar: calendar
            )
            if let end {
                copy.scheduleOverrideUntil = end
            } else {
                copy.schedule.enabled = false
                copy.scheduleOverrideUntil = nil
            }
        }
        return copy
    }

    public func withSchedule(enabled: Bool) -> Config {
        var copy = self
        copy.schedule.enabled = enabled && !schedule.windows.isEmpty
        copy.scheduleOverrideUntil = nil
        return copy
    }

    public func withScheduleWindows(_ windows: [ScheduleWindow]) -> Config {
        var copy = self
        copy.schedule.windows = windows
        if windows.isEmpty { copy.schedule.enabled = false }
        copy.scheduleOverrideUntil = nil
        return copy
    }
}

public enum SiteEditPolicy {
    /// While hosts actually blocks, entries can be added but not removed.
    public static func removedSites(from old: [String], to new: [String]) -> [String] {
        old.filter { !new.contains($0) }
    }

    public static func isAllowed(old: [String], new: [String], actuallyBlocking: Bool) -> Bool {
        !actuallyBlocking || removedSites(from: old, to: new).isEmpty
    }
}

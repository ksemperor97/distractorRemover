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

    /// Start Blocking: manual on, and a paused schedule window resumes too.
    public func startingBlocking() -> Config {
        var copy = self
        copy.manualEnabled = true
        copy.scheduleOverrideUntil = nil
        return copy
    }

    /// Stop Blocking turns off both kinds: manual off, and an active schedule
    /// window is paused until it ends, so the schedule still applies next time.
    /// A schedule that never turns off on its own is disabled instead.
    public func stoppingBlocking(at now: Date, calendar: Calendar = .current) -> Config {
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

    /// Saving the schedule editor. A schedule without windows is off.
    public func withSchedule(enabled: Bool, windows: [ScheduleWindow]) -> Config {
        var copy = self
        copy.schedule = Schedule(enabled: enabled && !windows.isEmpty, windows: windows)
        if copy.schedule != schedule { copy.scheduleOverrideUntil = nil }
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

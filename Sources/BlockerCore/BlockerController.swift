import Foundation

public enum ApplyStatus: String {
    case pending, ok, retrying, error

    public var isFailing: Bool { self == .retrying || self == .error }
}

public enum Outcome: Equatable {
    case ok
    case cancelled
    case failed(String)

    public var succeeded: Bool { self == .ok }
}

/// Owns the user's intent (`config`) and keeps the hosts file in line with it.
///
/// Every change goes through one path: build a candidate config, make hosts
/// match it, verify by re-reading, then adopt and persist it. A cancelled
/// administrator prompt leaves the current config untouched, so there is no
/// revert bookkeeping. Operations are serialized, and all blocking work
/// (reading hosts, sudo, osascript) runs off the main thread.
///
/// A damaged settings file is set aside and replaced with defaults. A hosts
/// file whose markers are damaged is never rewritten: the user fixes it in
/// the hosts editor, so none of their own lines can be lost.
@MainActor
public final class BlockerController {
    public private(set) var config: Config
    /// Set only if a damaged settings file could not even be set aside.
    public private(set) var configLoadError: String?
    /// One-time message for the user (e.g. a damaged settings file was replaced).
    public private(set) var startupNotice: String?
    public private(set) var actualBlocking = false
    public private(set) var applyStatus: ApplyStatus
    public private(set) var lastError = ""
    public private(set) var retryCount = 0
    /// The hosts markers are missing, reversed or nested; only a manual edit fixes it.
    public private(set) var hostsNeedManualFix = false

    /// Called on the main actor after any visible state change.
    public var onChange: (() -> Void)?

    /// Read on every use, so a time zone change applies immediately.
    public var calendar: Calendar { calendarProvider() }
    private let calendarProvider: () -> Calendar
    private let followsSystemTimeZone: Bool
    private var lastTimeZone: String
    private let store: ConfigStoring
    private let backend: HostsBackend
    private let logger: AppLogger
    private let statusWriter: RuntimeStatusWriter?
    private let version: String
    private let now: () -> Date
    private let uptime: () -> TimeInterval

    private var nextRetryAt: TimeInterval = 0
    private var lastVerifyAt: TimeInterval = -.infinity
    private var pendingSave = false
    private var lastAppliedDomains: [String]?
    private var queueTail: Task<Void, Never>?
    private var operationsInFlight = 0

    public init(
        store: ConfigStoring,
        backend: HostsBackend,
        logger: AppLogger,
        statusWriter: RuntimeStatusWriter? = nil,
        version: String = "development",
        calendar fixedCalendar: Calendar? = nil,
        now: @escaping () -> Date = Date.init,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.store = store
        self.backend = backend
        self.logger = logger
        self.statusWriter = statusWriter
        self.version = version
        calendarProvider = fixedCalendar.map { calendar in { calendar } } ?? { Calendar.current }
        followsSystemTimeZone = fixedCalendar == nil
        lastTimeZone = (fixedCalendar ?? Calendar.current).timeZone.identifier
        self.now = now
        self.uptime = uptime
        applyStatus = .pending
        do {
            config = try store.load()
        } catch {
            let reason = (error as? ConfigLoadError)?.description ?? "\(error)"
            logger.error("settings file unreadable: \(reason)")
            do {
                let (fresh, backup) = try store.quarantineAndReset()
                config = fresh
                startupNotice = "Your settings file was damaged, so distractorRemover started with empty settings. "
                    + "The old file was kept at:\n\(backup.path)"
                logger.warning("damaged settings moved to \(backup.path)")
            } catch {
                config = Config()
                configLoadError = reason
                applyStatus = .error
                lastError = reason
                logger.error("could not set the damaged settings file aside: \(error)")
            }
        }
        if let content = try? backend.readHosts() {
            actualBlocking = HostsFile.isBlocking(content)
        }
        recordStatus()
    }

    public func clearStartupNotice() { startupNotice = nil }

    // MARK: - Derived state for the UI

    public var isBusy: Bool { operationsInFlight > 0 }
    public var currentTime: Date { now() }

    public func desiredBlocking() -> Bool {
        config.desiredBlocking(at: now(), calendar: calendar)
    }

    public func activeReason() -> Config.ActiveReason {
        config.activeReason(at: now(), calendar: calendar)
    }

    public func scheduleActive() -> Bool {
        config.scheduleActive(at: now(), calendar: calendar)
    }

    public func nextScheduleChange() -> Date? {
        config.nextScheduleChange(after: now(), calendar: calendar)
    }

    public func formatMoment(_ date: Date?) -> String {
        ScheduleMath.formatMoment(date, now: now(), calendar: calendar)
    }

    public func statusTitle() -> String {
        if configLoadError != nil { return "Settings file is damaged — see app.log" }
        if hostsNeedManualFix { return "Hosts file needs fixing — click to edit" }
        if applyStatus.isFailing { return "Couldn’t update blocking — click to retry" }
        let next = nextScheduleChange()
        if actualBlocking {
            if !config.manualEnabled, scheduleActive(), let next {
                return "Blocking until \(formatMoment(next)) (schedule)"
            }
            return "Blocking"
        }
        if let next, !scheduleActive() {
            return "Not blocking · schedule starts \(formatMoment(next))"
        }
        return "Not blocking"
    }

    // MARK: - Operations

    /// Applies a user change. `transform` receives the latest config at the
    /// moment the operation runs (after any queued work), so concurrent clicks
    /// never overwrite each other with stale state.
    @discardableResult
    public func update(
        reason: String,
        allowPrompt: Bool = true,
        _ transform: @escaping (Config, Date) -> Config
    ) async -> Outcome {
        await enqueue {
            let candidate = transform(self.config, self.now())
            return await self.apply(candidate, reason: reason, allowPrompt: allowPrompt, adoptOnFailure: true)
        }
    }

    /// Re-applies the current config and verifies the hosts file.
    @discardableResult
    public func reconcile(reason: String, allowPrompt: Bool = false) async -> Outcome {
        await enqueue {
            await self.apply(self.config, reason: reason, allowPrompt: allowPrompt, adoptOnFailure: true)
        }
    }

    /// Periodic check. Cheap when nothing is due: no sudo, no disk writes.
    public func tick(reason: String = "timer", force: Bool = false) async {
        guard configLoadError == nil, force || operationsInFlight == 0 else { return }
        // Foundation caches the system zone; re-read it so a change is noticed
        // within one tick even if the change notification never arrives.
        if followsSystemTimeZone { NSTimeZone.resetSystemTimeZone() }
        let zone = calendar.timeZone.identifier
        let zoneChanged = zone != lastTimeZone
        if zoneChanged {
            logger.info("time zone changed from \(lastTimeZone) to \(zone)")
            lastTimeZone = zone
        }
        let moment = now()
        let normalized = config.normalized(at: moment)
        let domains = normalized.blockDomains(at: moment, calendar: calendar)
        let due: Bool
        if force || zoneChanged {
            due = true
        } else if applyStatus.isFailing {
            due = uptime() >= nextRetryAt   // back off: 5 s, 15 s, then every 30 s
        } else {
            due = normalized != config
                || domains != lastAppliedDomains
                || pendingSave
                || uptime() - lastVerifyAt >= AppConstants.verifyInterval
        }
        if due { await reconcile(reason: reason) }
    }

    /// The system time zone changed: re-evaluate the schedule in the new local time now.
    public func timeZoneDidChange() async {
        await tick(reason: "time-zone-change", force: true)
    }

    /// Saves a hand-edited hosts file (after a backup), then re-applies the
    /// managed section so it matches the block list again.
    public func saveEditedHosts(_ text: String) async -> Result<URL, BlockerError> {
        await enqueue {
            let backup: URL
            do {
                backup = try await self.offMain { try self.backend.replaceHosts(with: text) }
            } catch BlockerError.cancelled {
                return .failure(.cancelled)
            } catch {
                return .failure(.failed("\(error)"))
            }
            self.lastAppliedDomains = nil
            _ = await self.apply(self.config, reason: "hosts-edited", allowPrompt: true, adoptOnFailure: true)
            return .success(backup)
        }
    }

    public func readHostsText() async throws -> String {
        try await offMain { try self.backend.readHosts() }
    }

    // MARK: - Core

    private func apply(
        _ proposed: Config, reason: String, allowPrompt: Bool, adoptOnFailure: Bool
    ) async -> Outcome {
        if let loadError = configLoadError {
            applyStatus = .error
            lastError = loadError
            notify()
            return .failed(loadError)
        }
        let moment = now()
        let candidate = proposed.normalized(at: moment)
        let domains = candidate.blockDomains(at: moment, calendar: calendar)
        do {
            var content = try await offMain { try self.backend.readHosts() }
            hostsNeedManualFix = !HostsFile.inspect(content).isWellFormed
            if hostsNeedManualFix {
                throw BlockerError.failed(
                    "The distractorRemover marker lines in the hosts file are missing, reversed or nested, "
                        + "so the file was left unchanged. Open Edit Hosts File… and delete every line from the "
                        + "START marker through the END marker; blocking is then written again."
                )
            }
            if !HostsFile.matches(content, domains: domains) {
                try await offMain { try self.backend.write(domains: domains, allowPrompt: allowPrompt) }
                content = try await offMain { try self.backend.readHosts() }
                guard HostsFile.matches(content, domains: domains) else {
                    throw BlockerError.failed("The hosts file did not match the requested state after applying.")
                }
            }
            actualBlocking = HostsFile.isBlocking(content)
        } catch BlockerError.cancelled {
            await refreshActualState()
            notify()
            return .cancelled
        } catch {
            if adoptOnFailure {
                // Keep the user's intent so the retry loop can finish the job.
                adopt(candidate)
                persistPending()
            }
            markFailure("\(error)")
            await refreshActualState()
            notify()
            return .failed("\(error)")
        }

        let wasHealthy = applyStatus == .ok && lastAppliedDomains == domains
        adopt(candidate)
        lastAppliedDomains = domains
        if let saveError = persistPending() {
            let message = "Could not save settings after \(reason): \(saveError)"
            markFailure(message)
            notify()
            return .failed(message)
        }
        applyStatus = .ok
        lastError = ""
        retryCount = 0
        nextRetryAt = 0
        lastVerifyAt = uptime()
        if !wasHealthy {
            logger.info("hosts reconciled (\(reason)), active=\(actualBlocking), domains=\(domains.count)")
        }
        notify()
        return .ok
    }

    private func adopt(_ candidate: Config) {
        if candidate != config {
            config = candidate
            pendingSave = true
        }
    }

    @discardableResult
    private func persistPending() -> Error? {
        guard pendingSave else { return nil }
        do {
            try store.save(config)
            pendingSave = false
            return nil
        } catch {
            return error
        }
    }

    private func markFailure(_ message: String) {
        retryCount += 1
        let delays = AppConstants.retryDelays
        nextRetryAt = uptime() + delays[min(retryCount - 1, delays.count - 1)]
        applyStatus = .retrying
        lastError = message
        logger.error("hosts reconciliation failed: \(message)")
    }

    private func refreshActualState() async {
        if let content = try? await offMain({ try self.backend.readHosts() }) {
            actualBlocking = HostsFile.isBlocking(content)
        }
    }

    private func notify() {
        recordStatus()
        onChange?()
    }

    private func recordStatus() {
        guard let statusWriter else { return }
        do {
            try statusWriter.record(RuntimeStatus(
                version: version,
                applyStatus: applyStatus.rawValue,
                desiredBlocking: desiredBlocking(),
                actualBlocking: actualBlocking,
                retryCount: retryCount,
                lastError: lastError,
                configRecoveryRequired: configLoadError != nil
            ))
        } catch {
            logger.warning("could not write runtime status: \(error)")
        }
    }

    // MARK: - Concurrency helpers

    /// Runs operations one at a time, in submission order.
    private func enqueue<T>(_ operation: @escaping @MainActor () async -> T) async -> T {
        operationsInFlight += 1
        let previous = queueTail
        let task = Task { @MainActor () -> T in
            await previous?.value
            return await operation()
        }
        queueTail = Task { _ = await task.value }
        let result = await task.value
        operationsInFlight -= 1
        return result
    }

    private nonisolated func offMain<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}

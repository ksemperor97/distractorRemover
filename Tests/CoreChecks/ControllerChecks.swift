@testable import BlockerCore
import Foundation

/// A controller wired to the real helper script running against a scratch
/// hosts file, with a controllable clock.
@MainActor
final class Rig {
    let dir = temporaryDirectory()
    var hosts: URL { dir.appendingPathComponent("hosts") }
    var configURL: URL { dir.appendingPathComponent("config.json") }
    let broker: SandboxPrivilegeBroker
    let backend: HelperHostsBackend
    let counting: CountingBackend
    let store: ConfigStoring
    var now: Date
    var uptime: TimeInterval = 1000
    private(set) var controller: BlockerController!

    static let base = "127.0.0.1\tlocalhost\n"

    init(now: Date = at(2026, 7, 13, 10, 0), helperInstalled: Bool = true, config: String? = nil,
         store: ((URL) -> ConfigStoring)? = nil, systemCalendar: Bool = false) {
        self.now = now
        try! Rig.base.write(to: dir.appendingPathComponent("hosts"), atomically: true, encoding: .utf8)
        if let config { try! config.write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8) }
        broker = SandboxPrivilegeBroker(hostsFile: dir.appendingPathComponent("hosts"), scripts: scripts, stateDirectory: dir)
        if helperInstalled { try! scripts.bundledVersion!.write(to: dir.appendingPathComponent("sandbox-helper-version"), atomically: true, encoding: .utf8) }
        backend = HelperHostsBackend(hostsFile: dir.appendingPathComponent("hosts"), scripts: scripts,
                                     backupDirectory: dir.appendingPathComponent("backups"), broker: broker, logger: NullLogger())
        counting = CountingBackend(backend)
        self.store = store?(dir.appendingPathComponent("config.json")) ?? FileConfigStore(url: dir.appendingPathComponent("config.json"))
        controller = BlockerController(
            store: self.store, backend: counting, logger: NullLogger(), calendar: systemCalendar ? nil : seoul,
            now: { [unowned self] in self.now }, uptime: { [unowned self] in self.uptime }
        )
    }

    var hostsText: String { read(hosts) }
    var savedConfig: Config? { try? FileConfigStore(url: configURL).load() }

    func installHelper() {
        try! scripts.bundledVersion!.write(to: dir.appendingPathComponent("sandbox-helper-version"), atomically: true, encoding: .utf8)
        backend.refreshHelperStatus()
    }
}

final class CountingBackend: HostsBackend {
    let inner: HostsBackend
    var reads = 0
    var writes = 0
    init(_ inner: HostsBackend) { self.inner = inner }
    func readHosts() throws -> String { reads += 1; return try inner.readHosts() }
    func write(domains: [String], allowPrompt: Bool) throws { writes += 1; try inner.write(domains: domains, allowPrompt: allowPrompt) }
    func replaceHosts(with text: String) throws -> URL { try inner.replaceHosts(with: text) }
}

final class FlakyStore: ConfigStoring {
    let inner: FileConfigStore
    var failingSaves = 0
    init(url: URL) { inner = FileConfigStore(url: url) }
    func load() throws -> Config { try inner.load() }
    func save(_ config: Config) throws {
        if failingSaves > 0 {
            failingSaves -= 1
            throw StorageError("disk full (injected)")
        }
        try inner.save(config)
    }
    var failQuarantine = false
    func quarantineAndReset() throws -> (Config, URL) {
        if failQuarantine { throw StorageError("read-only (injected)") }
        return try inner.quarantineAndReset()
    }
}

func enablingManual(_ config: Config, _ now: Date) -> Config {
    var next = config
    next.sites = ["youtube.com"]
    next.manualEnabled = true
    return next
}

@MainActor
func runControllerChecks() async {
    await testAsync("startup with an empty config verifies an unblocked hosts file") {
        let rig = Rig()
        expectEqual(await rig.controller.reconcile(reason: "startup"), .ok)
        expectEqual(rig.controller.applyStatus, .ok)
        expectEqual(rig.hostsText, Rig.base)
        expectEqual(rig.counting.writes, 0)
    }

    await testAsync("manual blocking applies silently with the helper, then persists") {
        let rig = Rig()
        expectEqual(await rig.controller.update(reason: "test", enablingManual), .ok)
        check(rig.controller.actualBlocking)
        check(HostsFile.matches(rig.hostsText, domains: Domains.expanded(["youtube.com"])), rig.hostsText)
        expectEqual(rig.broker.promptCount, 0)
        expectEqual(rig.savedConfig?.manualEnabled, true)
    }

    await testAsync("without the helper a user change uses one administrator prompt") {
        let rig = Rig(helperInstalled: false)
        expectEqual(await rig.controller.update(reason: "test", enablingManual), .ok)
        expectEqual(rig.broker.promptCount, 1)
        check(rig.controller.actualBlocking)
    }

    await testAsync("a cancelled prompt leaves config, hosts and status untouched") {
        let rig = Rig(helperInstalled: false)
        _ = await rig.controller.reconcile(reason: "startup")
        rig.broker.promptResponse = .cancel
        expectEqual(await rig.controller.update(reason: "test", enablingManual), .cancelled)
        expectEqual(rig.controller.config, Config())
        expectEqual(rig.hostsText, Rig.base)
        expectEqual(rig.controller.applyStatus, .ok)
        check(!FileManager.default.fileExists(atPath: rig.configURL.path), "config was written")
    }

    await testAsync("silent change without the helper keeps intent and retries until it can apply") {
        let rig = Rig(helperInstalled: false)
        expectEqual(await rig.controller.update(reason: "test", allowPrompt: false, enablingManual),
                    .failed("Password-free mode is unavailable; automatic blocking cannot update hosts."))
        expectEqual(rig.controller.applyStatus, .retrying)
        check(rig.controller.config.manualEnabled, "intent dropped")
        expectEqual(rig.savedConfig?.manualEnabled, true)
        rig.installHelper()
        rig.uptime += 2
        await rig.controller.tick()
        expectEqual(rig.controller.applyStatus, .retrying, "retried before the backoff elapsed")
        rig.uptime += 5
        await rig.controller.tick()
        expectEqual(rig.controller.applyStatus, .ok)
        check(rig.controller.actualBlocking)
    }

    await testAsync("transient helper failure backs off and recovers") {
        let rig = Rig()
        rig.broker.failuresToInject = 2
        _ = await rig.controller.update(reason: "test", enablingManual)
        expectEqual(rig.controller.retryCount, 1)
        rig.uptime += 5
        await rig.controller.tick()
        expectEqual(rig.controller.retryCount, 2)
        rig.uptime += 10
        await rig.controller.tick()
        expectEqual(rig.controller.applyStatus, .retrying, "second delay should be 15 s")
        rig.uptime += 5
        await rig.controller.tick()
        expectEqual(rig.controller.applyStatus, .ok)
        expectEqual(rig.controller.retryCount, 0)
        check(rig.controller.lastError.isEmpty)
    }

    await testAsync("a failed save becomes a retryable error and is saved later") {
        var flaky: FlakyStore!
        let rig = Rig(store: { url in flaky = FlakyStore(url: url); return flaky })
        flaky.failingSaves = 1
        let outcome = await rig.controller.update(reason: "test", enablingManual)
        check({ if case .failed(let m) = outcome { return m.contains("Could not save settings") }; return false }(), "\(outcome)")
        expectEqual(rig.controller.applyStatus, .retrying)
        check(rig.controller.config.manualEnabled && rig.controller.actualBlocking)
        check(rig.savedConfig?.manualEnabled != true)
        rig.uptime += 5
        await rig.controller.tick()
        expectEqual(rig.controller.applyStatus, .ok)
        expectEqual(rig.savedConfig?.manualEnabled, true)
    }

    await testAsync("healthy ticks do no work until the verify interval") {
        let rig = Rig()
        _ = await rig.controller.update(reason: "test", enablingManual)
        let reads = rig.counting.reads
        rig.uptime += 5
        await rig.controller.tick()
        rig.uptime += 20
        await rig.controller.tick()
        expectEqual(rig.counting.reads, reads, "ticked work before verify interval")
        rig.uptime += 10
        await rig.controller.tick()
        expectEqual(rig.counting.reads, reads + 1)
        expectEqual(rig.counting.writes, 1)
    }

    await testAsync("an external edit is repaired at the next verification") {
        let rig = Rig()
        _ = await rig.controller.update(reason: "test", enablingManual)
        try Rig.base.write(to: rig.hosts, atomically: true, encoding: .utf8)
        rig.uptime += 31
        await rig.controller.tick()
        check(HostsFile.matches(rig.hostsText, domains: Domains.expanded(["youtube.com"])))
    }

    await testAsync("the schedule turns blocking on and off by itself") {
        let config = """
            {"sites": ["a.com"], "schedule": {"enabled": true,
             "windows": [{"days": [0], "start": "09:00", "end": "18:00"}]}}
            """
        let rig = Rig(now: at(2026, 7, 13, 8, 59), config: config)
        _ = await rig.controller.reconcile(reason: "startup")
        check(!rig.controller.actualBlocking)
        rig.now = at(2026, 7, 13, 9, 0)
        rig.uptime += 5
        await rig.controller.tick()
        check(rig.controller.actualBlocking, "did not start blocking at 09:00")
        expectEqual(rig.controller.activeReason(), .schedule)
        rig.now = at(2026, 7, 13, 18, 0)
        rig.uptime += 5
        await rig.controller.tick()
        check(!rig.controller.actualBlocking, "did not stop at 18:00")
        expectEqual(rig.counting.writes, 2)
    }

    await testAsync("stop blocking pauses the window; the schedule blocks again next time") {
        let config = """
            {"sites": ["a.com"], "manual_enabled": true, "schedule": {"enabled": true,
             "windows": [{"days": [0], "start": "09:00", "end": "18:00"}]}}
            """
        let rig = Rig(now: at(2026, 7, 13, 10, 0), config: config)
        _ = await rig.controller.reconcile(reason: "startup")
        check(rig.controller.actualBlocking)
        let calendar = seoul
        expectEqual(await rig.controller.update(reason: "off") { $0.stoppingBlocking(at: $1, calendar: calendar) }, .ok)
        check(!rig.controller.actualBlocking)
        expectEqual(rig.savedConfig?.scheduleOverrideUntil, at(2026, 7, 13, 18, 0))
        rig.now = at(2026, 7, 13, 18, 1)
        rig.uptime += 5
        await rig.controller.tick()
        check(rig.controller.config.scheduleOverrideUntil == nil)
        check(rig.savedConfig?.scheduleOverrideUntil == nil, "expired override not persisted")
        rig.now = at(2026, 7, 20, 9, 0)
        rig.uptime += 5
        await rig.controller.tick()
        check(rig.controller.actualBlocking, "next week's window did not block")
    }

    await testAsync("queued updates see each other's results") {
        let rig = Rig()
        async let first = rig.controller.update(reason: "a") { c, _ in var n = c; n.sites.append("a.com"); return n }
        async let second = rig.controller.update(reason: "b") { c, _ in var n = c; n.sites.append("b.com"); return n }
        _ = await (first, second)
        expectEqual(rig.controller.config.sites, ["a.com", "b.com"])
    }

    await testAsync("a damaged settings file is set aside and the app starts empty") {
        let rig = Rig(config: "{not json")
        check(rig.controller.configLoadError == nil)
        check(rig.controller.startupNotice?.contains("config.json.corrupt-") == true, "\(String(describing: rig.controller.startupNotice))")
        expectEqual(rig.controller.config, Config())
        let backups = try FileManager.default.contentsOfDirectory(atPath: rig.dir.path).filter { $0.hasPrefix("config.json.corrupt-") }
        expectEqual(backups.count, 1)
        if let name = backups.first { expectEqual(read(rig.dir.appendingPathComponent(name)), "{not json") }
        expectEqual(await rig.controller.update(reason: "x", enablingManual), .ok)
    }

    await testAsync("if the damaged file cannot be set aside, nothing is changed") {
        var flaky: FlakyStore!
        let rig = Rig(config: "{not json", store: { url in flaky = FlakyStore(url: url); flaky.failQuarantine = true; return flaky })
        check(rig.controller.configLoadError != nil)
        expectEqual(rig.controller.applyStatus, .error)
        check({ if case .failed = $0 { return true }; return false }(await rig.controller.update(reason: "x", enablingManual)))
        expectEqual(read(rig.configURL), "{not json")
        expectEqual(rig.hostsText, Rig.base)
    }

    await testAsync("damaged markers leave hosts untouched until the user fixes them") {
        let rig = Rig()
        _ = await rig.controller.update(reason: "test", enablingManual)
        let damaged = Rig.base + AppConstants.markEnd + "\n10.0.0.5 nas.local\n" + AppConstants.markStart
            + "\n192.168.0.7 printer.local\n"
        try damaged.write(to: rig.hosts, atomically: true, encoding: .utf8)
        let writes = rig.counting.writes
        rig.uptime += 31
        await rig.controller.tick()
        expectEqual(rig.hostsText, damaged)
        expectEqual(rig.counting.writes, writes, "wrote to a damaged file")
        check(rig.controller.hostsNeedManualFix)
        expectEqual(rig.controller.statusTitle(), "Hosts file needs fixing — click to edit")
        // Stopping blocking must not touch it either.
        let calendar = seoul
        _ = await rig.controller.update(reason: "stop") { $0.stoppingBlocking(at: $1, calendar: calendar) }
        expectEqual(rig.hostsText, damaged)
        // The user removes the marker lines in the hosts editor.
        let fixed = Rig.base + "10.0.0.5 nas.local\n192.168.0.7 printer.local\n"
        _ = await rig.controller.update(reason: "start") { c, _ in c.startingBlocking() }
        guard case .success = await rig.controller.saveEditedHosts(fixed) else { return check(false, "save failed") }
        check(!rig.controller.hostsNeedManualFix)
        check(rig.hostsText.hasPrefix(fixed), rig.hostsText)
        check(HostsFile.matches(rig.hostsText, domains: Domains.expanded(["youtube.com"])))
    }

    await testAsync("editing the hosts file by hand backs it up and keeps blocking in place") {
        let rig = Rig()
        _ = await rig.controller.update(reason: "test", enablingManual)
        let before = rig.hostsText
        // The user adds a line and deletes the managed section.
        guard case .success(let backup) = await rig.controller.saveEditedHosts("127.0.0.1\tlocalhost\n10.0.0.9 nas.local") else {
            return check(false, "save failed")
        }
        expectEqual(read(backup), before)
        check(rig.hostsText.contains("10.0.0.9 nas.local\n"), rig.hostsText)
        check(HostsFile.matches(rig.hostsText, domains: Domains.expanded(["youtube.com"])), "managed section not restored")
        expectEqual(rig.controller.applyStatus, .ok)

        rig.broker.promptResponse = .cancel
        let current = rig.hostsText
        expectEqual(await rig.controller.saveEditedHosts("garbage"), .failure(.cancelled))
        expectEqual(rig.hostsText, current)
    }

    await testAsync("a time zone change while running is picked up by the next tick") {
        let previous = ProcessInfo.processInfo.environment["TZ"]
        defer {
            if let previous { setenv("TZ", previous, 1) } else { unsetenv("TZ") }
            NSTimeZone.resetSystemTimeZone()
        }
        setenv("TZ", "Asia/Seoul", 1)
        NSTimeZone.resetSystemTimeZone()
        let config = """
            {"sites": ["a.com"], "schedule": {"enabled": true,
             "windows": [{"days": [0, 1, 2, 3, 4, 5, 6], "start": "09:00", "end": "18:00"}]}}
            """
        // 10:00 in Seoul is 21:00 the previous evening in New York.
        let rig = Rig(now: at(2026, 7, 13, 10, 0), config: config, systemCalendar: true)
        _ = await rig.controller.reconcile(reason: "startup")
        check(rig.controller.actualBlocking, "not blocking at 10:00 Seoul")
        setenv("TZ", "America/New_York", 1)   // no reset, no notification: only the timer
        rig.uptime += 5
        await rig.controller.tick()
        expectEqual(rig.controller.calendar.timeZone.identifier, "America/New_York")
        check(!rig.controller.actualBlocking, "still blocking at 21:00 New York")
        check(!HostsFile.isBlocking(rig.hostsText))
    }

    await testAsync("helper status and installation") {
        let rig = Rig(helperInstalled: false)
        expectEqual(rig.backend.helperStatus, .notInstalled)
        try rig.backend.installHelper(forUser: "someone")
        expectEqual(rig.backend.helperStatus, .ready(version: scripts.bundledVersion!))
        try "9".write(to: rig.dir.appendingPathComponent("sandbox-helper-version"), atomically: true, encoding: .utf8)
        expectEqual(rig.backend.refreshHelperStatus(), .unsupported(version: "9"))
        do {
            try rig.backend.installHelper(forUser: "bad user")
            check(false, "accepted unsafe user name")
        } catch {}
    }
}

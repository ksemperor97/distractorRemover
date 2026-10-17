@testable import BlockerCore
import Foundation

let seoul: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
    return calendar
}()

func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int, calendar: Calendar = seoul) -> Date {
    calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

func window(_ days: [Int], _ start: String, _ end: String) -> ScheduleWindow {
    ScheduleWindow(days: days, start: start, end: end)!
}

func runDomainChecks() {
    test("normalize strips scheme, www, path, query, user and port") {
        expectEqual(Domains.normalize("https://www.YouTube.com/feed?list=abc"), "youtube.com")
        expectEqual(Domains.normalize("http://user@Example.COM:8080/x#y"), "example.com")
        expectEqual(Domains.normalize("  reddit.com.  "), "reddit.com")
    }
    test("normalize rejects non-domains") {
        for raw in ["not a domain", "", "localhost", "bad_domain.com", "-x.com", "a..b"] {
            check(Domains.normalize(raw) == nil, "accepted \(raw)")
        }
    }
    test("normalize converts IDNs to punycode") {
        expectEqual(Domains.normalize("https://www.예시.한국/path"), "xn--vv4b11d.xn--3e0b707e")
        expectEqual(Domains.normalize("Bücher.de"), "xn--bcher-kva.de")
    }
    test("service presets canonicalize aliases and expand entry points") {
        expectEqual(Domains.canonicalSite("youtu.be"), "youtube.com")
        let expanded = Domains.expanded(["youtube.com"])
        check(expanded.contains("m.youtube.com") && expanded.contains("music.youtube.com") && expanded.contains("youtu.be"))
        expectEqual(Domains.expanded(["example.com"]), ["example.com", "www.example.com"])
        expectEqual(Domains.expanded(["youtu.be", "youtube.com"]).count, 6)
        expectEqual(Domains.displayName("youtube.com"), "YouTube — youtube.com (6 domains)")
    }
    test("text block list accepts domains, URLs and hosts lines") {
        let text = """
            # Paste either domains or lines copied from /etc/hosts
            youtube.com
            https://www.instagram.com/explore
            127.0.0.1 m.youtube.com youtu.be
            ::1 reddit.com
            """
        expectEqual(try Domains.parseSiteList(text), ["youtube.com", "instagram.com", "reddit.com"])
    }
    test("text block list reports the invalid line") {
        do {
            _ = try Domains.parseSiteList("youtube.com\nnot a domain\n")
            check(false, "no error")
        } catch {
            check("\(error)".contains("line 2"), "\(error)")
        }
    }
    test("sites can be added but not removed while blocking") {
        check(SiteEditPolicy.isAllowed(old: ["a.com"], new: ["a.com", "b.com"], actuallyBlocking: true))
        check(!SiteEditPolicy.isAllowed(old: ["a.com", "b.com"], new: ["a.com"], actuallyBlocking: true))
        check(SiteEditPolicy.isAllowed(old: ["a.com", "b.com"], new: ["a.com"], actuallyBlocking: false))
    }
}

func runHostsChecks() {
    let base = "127.0.0.1 localhost\n10.0.0.2 internal.test\n"
    let section = ([AppConstants.markStart] + HostsFile.sectionBody(for: ["a.com", "www.a.com"]) + [AppConstants.markEnd])
        .joined(separator: "\n")
    test("hosts match requires exactly the requested section") {
        check(HostsFile.matches(base, domains: []))
        check(!HostsFile.matches(base, domains: ["a.com"]))
        let blocked = base + section + "\n"
        check(HostsFile.matches(blocked, domains: ["a.com", "www.a.com"]))
        check(!HostsFile.matches(blocked, domains: ["a.com"]))
        check(!HostsFile.matches(blocked, domains: []))
        check(HostsFile.isBlocking(blocked) && !HostsFile.isBlocking(base))
    }
    test("incomplete or duplicated sections never match") {
        let broken = base + AppConstants.markStart + "\n127.0.0.1\ta.com\n"
        check(!HostsFile.matches(broken, domains: []))
        check(!HostsFile.matches(broken, domains: ["a.com"]))
        check(!HostsFile.inspect(broken).isComplete)
        let doubled = base + section + "\n" + section + "\n"
        check(!HostsFile.matches(doubled, domains: ["a.com", "www.a.com"]))
    }
    test("markers must be whole lines") {
        let inline = "# note: " + AppConstants.markStart + "\n"
        check(HostsFile.matches(inline, domains: []))
    }
}

func runScheduleChecks() {
    test("weekday indexing uses Monday = 0") {
        expectEqual(ScheduleMath.weekdayIndex(at(2026, 7, 13, 12, 0), calendar: seoul), 0)
        expectEqual(ScheduleMath.weekdayIndex(at(2026, 7, 19, 12, 0), calendar: seoul), 6)
    }
    test("daytime window boundaries") {
        let windows = [window([0, 1, 2, 3, 4], "09:00", "18:00")]
        check(!ScheduleMath.inAnyWindow(at(2026, 7, 13, 8, 59), windows, calendar: seoul))
        check(ScheduleMath.inAnyWindow(at(2026, 7, 13, 9, 0), windows, calendar: seoul))
        check(ScheduleMath.inAnyWindow(at(2026, 7, 13, 17, 59), windows, calendar: seoul))
        check(!ScheduleMath.inAnyWindow(at(2026, 7, 13, 18, 0), windows, calendar: seoul))
    }
    test("overnight windows and week rollover") {
        let mondayNight = [window([0], "22:00", "06:00")]
        check(ScheduleMath.inAnyWindow(at(2026, 7, 13, 22, 0), mondayNight, calendar: seoul))
        check(ScheduleMath.inAnyWindow(at(2026, 7, 14, 5, 59), mondayNight, calendar: seoul))
        check(!ScheduleMath.inAnyWindow(at(2026, 7, 14, 6, 0), mondayNight, calendar: seoul))
        let sundayNight = [window([6], "22:00", "06:00")]
        check(ScheduleMath.inAnyWindow(at(2026, 7, 13, 5, 59), sundayNight, calendar: seoul))
    }
    test("override pauses the schedule and next transition is exact") {
        let schedule = Schedule(enabled: true, windows: [window([0], "09:00", "18:00")])
        let now = at(2026, 7, 13, 10, 0)
        check(ScheduleMath.isActive(now, schedule: schedule, overrideUntil: nil, calendar: seoul))
        check(!ScheduleMath.isActive(now, schedule: schedule, overrideUntil: at(2026, 7, 13, 18, 0), calendar: seoul))
        expectEqual(ScheduleMath.nextTransition(after: now, schedule: schedule, overrideUntil: nil, calendar: seoul),
                    at(2026, 7, 13, 18, 0))
        expectEqual(ScheduleMath.nextTransition(after: at(2026, 7, 13, 19, 0), schedule: schedule, overrideUntil: nil, calendar: seoul),
                    at(2026, 7, 20, 9, 0))
    }
    test("a schedule that never turns off has no transition") {
        let always = Schedule(enabled: true, windows: [window(Array(0...6), "00:00", "12:00"), window(Array(0...6), "12:00", "00:00")])
        check(ScheduleMath.nextTransition(after: at(2026, 7, 13, 10, 0), schedule: always, overrideUntil: nil, calendar: seoul) == nil)
    }
    test("time parsing") {
        expectEqual(ScheduleWindow.parseTime("9:05"), 545)
        expectEqual(ScheduleWindow.parseTime("23:59"), 1439)
        for bad in ["24:00", "9:5", "aa:bb", "12", "", "１２:００"] {
            check(ScheduleWindow.parseTime(bad) == nil, "accepted \(bad)")
        }
        check(ScheduleWindow(days: [0], start: "09:00", end: "09:00") == nil)
        check(ScheduleWindow(days: [], start: "09:00", end: "10:00") == nil)
        check(ScheduleWindow(days: [7], start: "09:00", end: "10:00") == nil)
    }
    test("window formatting") {
        expectEqual(ScheduleMath.formatWindow(window([4, 0, 1, 2, 3], "09:00", "18:00")), "Mon–Fri  09:00–18:00")
        expectEqual(ScheduleMath.formatDays([6, 5]), "Sat–Sun")
        expectEqual(ScheduleMath.formatDays([0, 2]), "Mon, Wed")
    }
}

func runConfigChecks() {
    test("turning off all pauses an active window until it ends") {
        let config = Config(sites: ["a.com"], manualEnabled: true,
                            schedule: Schedule(enabled: true, windows: [window([0], "09:00", "18:00")]))
        let now = at(2026, 7, 13, 10, 0)
        let off = config.turningOffAll(at: now, calendar: seoul)
        check(!off.manualEnabled)
        expectEqual(off.scheduleOverrideUntil, at(2026, 7, 13, 18, 0))
        check(off.schedule.enabled)
        check(off.blockDomains(at: now, calendar: seoul).isEmpty)
        // The window comes back next week.
        check(!off.blockDomains(at: at(2026, 7, 20, 9, 30), calendar: seoul).isEmpty)
    }
    test("turning off an always-on schedule disables it") {
        let config = Config(sites: ["a.com"], schedule: Schedule(enabled: true, windows: [
            window(Array(0...6), "00:00", "12:00"), window(Array(0...6), "12:00", "00:00"),
        ]))
        let off = config.turningOffAll(at: at(2026, 7, 13, 10, 0), calendar: seoul)
        check(!off.schedule.enabled && off.scheduleOverrideUntil == nil)
    }
    test("normalization drops expired overrides and empty schedules") {
        var config = Config(schedule: Schedule(enabled: true, windows: []))
        config.scheduleOverrideUntil = at(2026, 7, 13, 9, 0)
        let normalized = config.normalized(at: at(2026, 7, 13, 10, 0))
        check(normalized.scheduleOverrideUntil == nil && !normalized.schedule.enabled)
        check(config.withScheduleWindows([]).schedule.enabled == false)
    }
    test("desired blocking needs sites") {
        let config = Config(sites: [], manualEnabled: true)
        check(config.blockingRequested(at: Date()) && !config.desiredBlocking(at: Date()))
    }
    test("v1 config migrates and canonicalizes") {
        let legacy = """
            {"sites": ["youtu.be", "youtube.com", "https://Example.com/x"], "manual_blocking": false,
             "scheduled_blocking": true,
             "schedule": {"enabled": true, "windows": [{"days": [0], "start": "9:00", "end": "18:00"}]}}
            """
        let config = try ConfigCodec.decode(Data(legacy.utf8))
        expectEqual(config.sites, ["youtube.com", "example.com"])
        check(!config.manualEnabled)
        check(config.schedule.enabled)
        expectEqual(config.schedule.windows, [window([0], "09:00", "18:00")])
        let blocking = try ConfigCodec.decode(Data(#"{"sites": ["a.com"], "blocking": true}"#.utf8))
        check(blocking.manualEnabled)
    }
    test("schedule without windows is not enabled") {
        let config = try ConfigCodec.decode(Data(#"{"schedule": {"enabled": true, "windows": []}}"#.utf8))
        check(!config.schedule.enabled)
    }
    test("config round-trips including the override") {
        let original = Config(sites: ["youtube.com", "a.com"], manualEnabled: true,
                              schedule: Schedule(enabled: true, windows: [window([0, 6], "22:00", "06:00")]),
                              scheduleOverrideUntil: Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 13, hour: 18)))
        let data = try ConfigCodec.encode(original)
        expectEqual(try ConfigCodec.decode(data), original)
        let json = String(decoding: data, as: UTF8.self)
        check(json.contains("\"schema_version\" : 2") && json.contains("\"2026-07-13T18:00\""), json)
    }
    test("malformed configurations are reported, not repaired silently") {
        let bad = [
            #"[1, 2]"#,
            #"{"sites": "youtube.com"}"#,
            #"{"sites": ["not a domain"]}"#,
            #"{"sites": [3]}"#,
            #"{"schedule": []}"#,
            #"{"schedule": {"windows": {}}}"#,
            #"{"schedule": {"windows": [{"days": [9], "start": "09:00", "end": "10:00"}]}}"#,
            #"{"schedule": {"windows": [{"days": [1], "start": "09:00", "end": "09:00"}]}}"#,
            #"{"schedule": {"windows": [{"days": [true], "start": "09:00", "end": "10:00"}]}}"#,
            #"{"schedule_override_until": 5}"#,
            #"{"sites": [}"#,
        ]
        for text in bad {
            do {
                _ = try ConfigCodec.decode(Data(text.utf8))
                check(false, "accepted \(text)")
            } catch {
                check(error is ConfigLoadError, "wrong error for \(text): \(error)")
            }
        }
    }
    test("override timestamps accept seconds and ignore a zone suffix") {
        let plain = ConfigCodec.parseLocalTimestamp("2026-07-13T18:00")
        expectEqual(ConfigCodec.parseLocalTimestamp("2026-07-13T18:00:00+09:00"), plain)
        check(ConfigCodec.parseLocalTimestamp("tomorrow") == nil)
    }
}

func runStorageChecks() {
    test("corrupt config is reported and left untouched") {
        let dir = temporaryDirectory()
        let url = dir.appendingPathComponent("config.json")
        try "{broken".write(to: url, atomically: true, encoding: .utf8)
        let store = FileConfigStore(url: url)
        do {
            _ = try store.load()
            check(false, "no error")
        } catch {
            check(error is ConfigLoadError)
        }
        expectEqual(read(url), "{broken")
    }
    test("missing config loads defaults") {
        let store = FileConfigStore(url: temporaryDirectory().appendingPathComponent("config.json"))
        expectEqual(try store.load(), Config())
    }
    test("quarantine backs up the original and writes defaults") {
        let dir = temporaryDirectory()
        let url = dir.appendingPathComponent("config.json")
        try "{broken".write(to: url, atomically: true, encoding: .utf8)
        let (config, backup) = try FileConfigStore(url: url).quarantineAndReset()
        expectEqual(config, Config())
        expectEqual(read(backup), "{broken")
        check(backup.lastPathComponent.hasPrefix("config.json.corrupt-"))
        expectEqual(try FileConfigStore(url: url).load(), Config())
    }
    test("quarantine restores the original when writing defaults fails") {
        let dir = temporaryDirectory()
        let url = dir.appendingPathComponent("config.json")
        try "{broken".write(to: url, atomically: true, encoding: .utf8)
        // A directory where the temp file should go makes the save fail.
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: url.path + ".tmp"), withIntermediateDirectories: false)
        do {
            _ = try FileConfigStore(url: url).quarantineAndReset()
            check(false, "no error")
        } catch {}
        expectEqual(read(url), "{broken")
    }
    test("runtime status is written only when it changes") {
        let url = temporaryDirectory().appendingPathComponent("runtime-state.json")
        let writer = RuntimeStatusWriter(url: url)
        let status = RuntimeStatus(version: "x", applyStatus: "ok", desiredBlocking: false, actualBlocking: false,
                                   retryCount: 0, lastError: "", configRecoveryRequired: false)
        try writer.record(status)
        check(read(url).contains("\"apply_status\" : \"ok\""))
        try FileManager.default.removeItem(at: url)
        try writer.record(status)
        check(!FileManager.default.fileExists(atPath: url.path), "rewrote an unchanged status")
        var changed = status
        changed.applyStatus = "retrying"
        try writer.record(changed)
        check(read(url).contains("retrying"))
    }
    test("hosts backup preserves exact bytes and is private") {
        let dir = temporaryDirectory()
        let source = dir.appendingPathComponent("hosts")
        let bytes = Data([0x31, 0x32, 0x37, 0x0a, 0xff, 0x00, 0x0a])
        try bytes.write(to: source)
        let backups = dir.appendingPathComponent("backups")
        let backup = try HostsBackup.create(from: source, in: backups)
        expectEqual(try Data(contentsOf: backup), bytes)
        let fileMode = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int
        let dirMode = try FileManager.default.attributesOfItem(atPath: backups.path)[.posixPermissions] as? Int
        expectEqual(fileMode, 0o600)
        expectEqual(dirMode, 0o700)
    }
    test("single-instance lock is exclusive") {
        let url = temporaryDirectory().appendingPathComponent("instance.lock")
        let first = InstanceLock(url: url)
        check(first != nil)
        check(InstanceLock(url: url) == nil, "second lock acquired")
        withExtendedLifetime(first) {}
    }
    test("log rotates by size") {
        let url = temporaryDirectory().appendingPathComponent("app.log")
        let logger = FileLogger(url: url, maxBytes: 200, backups: 2)
        for index in 0..<20 { logger.info("line \(index) padding padding padding") }
        check(FileManager.default.fileExists(atPath: url.path + ".1"))
        check(FileManager.default.fileExists(atPath: url.path + ".2"))
        check(!FileManager.default.fileExists(atPath: url.path + ".3"))
    }
    test("shell and AppleScript quoting") {
        expectEqual(ProcessRunner.shellQuote("it's"), #"'it'\''s'"#)
        expectEqual(ProcessRunner.appleScriptString(#"a "b" \c"#), #""a \"b\" \\c""#)
    }
}

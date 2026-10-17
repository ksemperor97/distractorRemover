@testable import BlockerCore
import Foundation

let scripts = HelperScripts(directory: repositoryRoot.appendingPathComponent("helper"))

/// Runs the real helper script unprivileged against a scratch hosts file.
func runHelper(_ hosts: URL, _ action: String, _ domains: [String] = []) -> ProcessResult {
    var env = ProcessInfo.processInfo.environment
    env["DISTRACTORREMOVER_TEST_HOSTS"] = hosts.path
    return ProcessRunner.run(
        "/bin/bash", [scripts.privilegedHelper.path, action],
        stdin: domains.map { $0 + "\n" }.joined(), environment: env, timeout: 15
    )
}

func runHelperChecks() {
    test("shell scripts agree with the app's constants") {
        let helper = read(scripts.privilegedHelper)
        check(helper.contains("MARK_START='\(AppConstants.markStart)'"), "start marker differs")
        check(helper.contains("MARK_END='\(AppConstants.markEnd)'"), "end marker differs")
        let installer = read(scripts.installer)
        check(installer.contains("HELPER=\(AppConstants.helperPath)"), "installer helper path differs")
        check(installer.contains("SUDOERS=\(AppConstants.sudoersPath)"), "installer sudoers path differs")
        check(!installer.contains("'ready 3'") && installer.contains("EXPECTED_VERSION"), "installer hardcodes a version")
        let uninstaller = read(scripts.uninstaller)
        check(uninstaller.contains(AppConstants.helperPath) && uninstaller.contains(AppConstants.sudoersPath))
        check(helper.contains("-le \(AppConstants.maxDomains)"), "domain limit differs")
    }
    test("helper version is the single bundled version") {
        let result = ProcessRunner.run("/bin/bash", [scripts.privilegedHelper.path, "--version"])
        check(result.succeeded, result.message)
        let version = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        expectEqual(scripts.bundledVersion, version)
        check(AppConstants.compatibleHelperVersions.contains(version), "bundled version \(version) not compatible")
    }
    test("shell scripts parse") {
        for script in [scripts.privilegedHelper, scripts.installer, scripts.uninstaller,
                       repositoryRoot.appendingPathComponent("build_app.sh"),
                       repositoryRoot.appendingPathComponent("uninstall.sh")] {
            let result = ProcessRunner.run("/bin/bash", ["-n", script.path])
            check(result.succeeded, "\(script.lastPathComponent): \(result.message)")
        }
    }
    test("apply and clear manage only the marked section") {
        let base = "127.0.0.1 localhost\n10.0.0.2 internal.test\n"
        let hosts = temporaryDirectory().appendingPathComponent("hosts")
        try base.write(to: hosts, atomically: true, encoding: .utf8)
        let domains = Domains.expanded(["youtube.com", "example.com"])
        let applied = runHelper(hosts, "--apply", domains)
        check(applied.succeeded, applied.message)
        let content = read(hosts)
        check(HostsFile.matches(content, domains: domains), content)
        check(content.hasPrefix(base))
        // Applying again is idempotent.
        check(runHelper(hosts, "--apply", domains).succeeded)
        expectEqual(read(hosts), content)
        let cleared = runHelper(hosts, "--clear")
        check(cleared.succeeded, cleared.message)
        expectEqual(read(hosts), base)
    }
    test("helper rejects invalid domains without modifying hosts") {
        let base = "127.0.0.1 localhost\n"
        let hosts = temporaryDirectory().appendingPathComponent("hosts")
        try base.write(to: hosts, atomically: true, encoding: .utf8)
        for bad in ["bad_domain.com", "-a.com", "nodot", "a..com", "a.com; rm -rf /"] {
            check(!runHelper(hosts, "--apply", [bad]).succeeded, "accepted \(bad)")
        }
        expectEqual(read(hosts), base)
    }
    test("reversed or nested markers are rejected without modification") {
        let start = AppConstants.markStart, end = AppConstants.markEnd
        let layouts = [
            "127.0.0.1 localhost\n\(end)\n10.0.0.5 nas.local\n\(start)\n192.168.0.7 printer.local\n",
            "127.0.0.1 localhost\n\(start)\n\(start)\n127.0.0.1\ta.com\n\(end)\n\(end)\n10.0.0.5 nas.local\n",
            "127.0.0.1 localhost\n\(start)\n127.0.0.1\ta.com\n\(end)\n\(end)\n10.0.0.5 nas.local\n",
        ]
        for layout in layouts {
            let hosts = temporaryDirectory().appendingPathComponent("hosts")
            try layout.write(to: hosts, atomically: true, encoding: .utf8)
            for action in ["--clear", "--apply"] {
                let result = runHelper(hosts, action, ["b.com"])
                expectEqual(result.status, 12, "\(action): \(result.message)")
                expectEqual(read(hosts), layout, action)
            }
        }
    }
    test("incomplete marker is rejected without modification") {
        let broken = "127.0.0.1 localhost\n" + AppConstants.markStart + "\n"
        let hosts = temporaryDirectory().appendingPathComponent("hosts")
        try broken.write(to: hosts, atomically: true, encoding: .utf8)
        check(!runHelper(hosts, "--clear").succeeded)
        expectEqual(read(hosts), broken)
    }
    test("reset repairs an incomplete marker and creates a backup") {
        let broken = "127.0.0.1 localhost\n" + AppConstants.markStart
            + "\n127.0.0.1\texample.com\n::1\texample.com\n10.0.0.2 internal.test\n"
        let dir = temporaryDirectory()
        let hosts = dir.appendingPathComponent("hosts")
        try broken.write(to: hosts, atomically: true, encoding: .utf8)
        let result = runHelper(hosts, "--reset")
        check(result.succeeded, result.message)
        check(result.stdout.contains("backup:"))
        let repaired = read(hosts)
        check(!repaired.contains(AppConstants.markStart) && !repaired.contains("example.com"), repaired)
        check(repaired.contains("10.0.0.2 internal.test"))
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("hosts.distractorremover-backup-") }
        expectEqual(backups.count, 1)
        if let name = backups.first { expectEqual(read(dir.appendingPathComponent(name)), broken) }
    }
}

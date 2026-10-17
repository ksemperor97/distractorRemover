import Foundation

public enum BlockerError: Error, Equatable, CustomStringConvertible {
    /// The user dismissed an administrator prompt.
    case cancelled
    /// A silent update was needed but password-free mode is unavailable.
    case authorizationRequired(String)
    /// The hosts markers are missing, reversed or nested; the file was left alone.
    case hostsMarkersDamaged
    /// After writing, the hosts file still did not show the requested state.
    case verifyMismatch
    case failed(String)

    public var description: String {
        switch self {
        case .cancelled: return "Cancelled."
        case .hostsMarkersDamaged:
            return "The distractorRemover markers in the hosts file are missing, reversed or nested; the file was left unchanged."
        case .verifyMismatch: return "The hosts file did not match the requested state after applying."
        case .authorizationRequired(let message), .failed(let message): return message
        }
    }
}

/// The scripts in `helper/`, bundled into the app's Resources.
public struct HelperScripts {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public var privilegedHelper: URL { directory.appendingPathComponent("privileged_helper.sh") }
    public var installer: URL { directory.appendingPathComponent("install_helper.sh") }
    public var uninstaller: URL { directory.appendingPathComponent("uninstall_helper.sh") }

    public var allPresent: Bool {
        [privilegedHelper, installer, uninstaller].allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    /// `VERSION=` in the bundled helper: the single source of the helper version.
    public var bundledVersion: String? {
        guard let text = try? String(contentsOf: privilegedHelper, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: "\n") where line.hasPrefix("VERSION=") {
            let value = String(line.dropFirst("VERSION=".count))
            return value.allSatisfy(\.isNumber) && !value.isEmpty ? value : nil
        }
        return nil
    }
}

public enum HelperStatus: Equatable {
    case notInstalled
    case ready(version: String)
    case unsupported(version: String)

    public var isUsable: Bool {
        if case .ready = self { return true }
        return false
    }

    public static func from(version: String?) -> HelperStatus {
        guard let version else { return .notInstalled }
        return AppConstants.compatibleHelperVersions.contains(version)
            ? .ready(version: version) : .unsupported(version: version)
    }
}

/// How root-level work gets done. The system implementation uses sudo and
/// osascript; the sandbox implementation runs the same scripts unprivileged
/// against a scratch hosts file (development mode and CoreChecks).
public protocol PrivilegeBroker: AnyObject {
    /// Version reported by the installed helper via password-free sudo, or nil.
    func installedHelperVersion() -> String?
    /// Runs the installed helper with `sudo -n`.
    func runInstalledHelper(_ action: String, stdinLines: [String]) -> ProcessResult
    /// Runs a bundled script as root after one native administrator prompt.
    func runAsAdministrator(_ script: URL, arguments: [String], stdinLines: [String]) -> ProcessResult
    /// Overwrites `destination` with `source` as root after one administrator
    /// prompt (the manual hosts editor). Never password-free.
    func replaceAsAdministrator(_ destination: URL, with source: URL) -> ProcessResult
}

public final class SystemPrivilegeBroker: PrivilegeBroker {
    public init() {}

    private func helperFileIsTrusted() -> Bool {
        var info = stat()
        guard lstat(AppConstants.helperPath, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG
            && info.st_uid == 0
            && (info.st_mode & 0o022) == 0
            && (info.st_mode & S_IXUSR) != 0
    }

    public func installedHelperVersion() -> String? {
        guard helperFileIsTrusted() else { return nil }
        let result = ProcessRunner.run(
            "/usr/bin/sudo", ["-n", AppConstants.helperPath, "--check"], timeout: 3
        )
        guard result.succeeded else { return nil }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.hasPrefix("ready ") else { return nil }
        let version = String(output.dropFirst("ready ".count))
        return !version.isEmpty && version.allSatisfy(\.isNumber) ? version : nil
    }

    public func runInstalledHelper(_ action: String, stdinLines: [String]) -> ProcessResult {
        ProcessRunner.run(
            "/usr/bin/sudo", ["-n", AppConstants.helperPath, action],
            stdin: stdinLines.isEmpty ? "" : stdinLines.joined(separator: "\n") + "\n",
            timeout: 15
        )
    }

    public func runAsAdministrator(_ script: URL, arguments: [String], stdinLines: [String]) -> ProcessResult {
        var command = (["/bin/bash", script.path] + arguments).map(ProcessRunner.shellQuote).joined(separator: " ")
        if !stdinLines.isEmpty {
            let printf = (["printf", "%s\\n"] + stdinLines).map(ProcessRunner.shellQuote).joined(separator: " ")
            command = "\(printf) | \(command)"
        }
        return runShellAsAdministrator(command)
    }

    public func replaceAsAdministrator(_ destination: URL, with source: URL) -> ProcessResult {
        // cp onto the existing file keeps its owner and mode.
        let copy = ["/bin/cp", source.path, destination.path].map(ProcessRunner.shellQuote).joined(separator: " ")
        return runShellAsAdministrator(
            "\(copy) && { dscacheutil -flushcache || true; killall -HUP mDNSResponder || true; }"
        )
    }

    private func runShellAsAdministrator(_ command: String) -> ProcessResult {
        let source = "do shell script \(ProcessRunner.appleScriptString(command)) with administrator privileges"
        return ProcessRunner.run("/usr/bin/osascript", ["-e", source])
    }
}

public final class SandboxPrivilegeBroker: PrivilegeBroker {
    public enum PromptResponse { case approve, cancel }

    private let hostsFile: URL
    private let scripts: HelperScripts
    private let stateFile: URL
    public var promptResponse: PromptResponse = .approve
    /// Makes the next N helper writes fail (retry testing).
    public var failuresToInject = 0
    public private(set) var promptCount = 0

    public init(hostsFile: URL, scripts: HelperScripts, stateDirectory: URL) {
        self.hostsFile = hostsFile
        self.scripts = scripts
        stateFile = stateDirectory.appendingPathComponent("sandbox-helper-version")
    }

    public func installedHelperVersion() -> String? {
        (try? String(contentsOf: stateFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runScript(_ script: URL, _ arguments: [String], _ stdinLines: [String]) -> ProcessResult {
        var environment = ProcessInfo.processInfo.environment
        environment["DISTRACTORREMOVER_TEST_HOSTS"] = hostsFile.path
        return ProcessRunner.run(
            "/bin/bash", [script.path] + arguments,
            stdin: stdinLines.isEmpty ? "" : stdinLines.joined(separator: "\n") + "\n",
            environment: environment, timeout: 15
        )
    }

    public func runInstalledHelper(_ action: String, stdinLines: [String]) -> ProcessResult {
        guard installedHelperVersion() != nil else {
            return ProcessResult(status: 1, stdout: "", stderr: "sudo: a password is required")
        }
        if failuresToInject > 0 {
            failuresToInject -= 1
            return ProcessResult(status: 1, stdout: "", stderr: "injected helper failure")
        }
        return runScript(scripts.privilegedHelper, [action], stdinLines)
    }

    public func runAsAdministrator(_ script: URL, arguments: [String], stdinLines: [String]) -> ProcessResult {
        promptCount += 1
        if promptResponse == .cancel {
            return ProcessResult(status: 1, stdout: "", stderr: "execution error: User canceled. (-128)")
        }
        switch script.lastPathComponent {
        case scripts.installer.lastPathComponent:
            try? FileManager.default.createDirectory(
                at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? (scripts.bundledVersion ?? "0").write(to: stateFile, atomically: true, encoding: .utf8)
            return ProcessResult(status: 0, stdout: "installed (sandbox)", stderr: "")
        case scripts.uninstaller.lastPathComponent:
            try? FileManager.default.removeItem(at: stateFile)
            return ProcessResult(status: 0, stdout: "removed", stderr: "")
        default:
            return runScript(script, arguments, stdinLines)
        }
    }

    public func replaceAsAdministrator(_ destination: URL, with source: URL) -> ProcessResult {
        promptCount += 1
        if promptResponse == .cancel {
            return ProcessResult(status: 1, stdout: "", stderr: "execution error: User canceled. (-128)")
        }
        do {
            try Data(contentsOf: source).write(to: destination)
            return ProcessResult(status: 0, stdout: "", stderr: "")
        } catch {
            return ProcessResult(status: 1, stdout: "", stderr: error.localizedDescription)
        }
    }
}

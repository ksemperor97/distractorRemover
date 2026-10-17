import Foundation

/// Values shared with the shell helpers in `helper/`. CoreChecks verifies that
/// the scripts agree with these, so a change on one side cannot drift silently.
public enum AppConstants {
    public static let appName = "distractorRemover"
    public static let bundleIdentifier = "com.sjk.distractorremover"

    public static let markStart = "# === distractorRemover START (managed automatically — do not edit) ==="
    public static let markEnd = "# === distractorRemover END ==="

    public static let helperPath = "/usr/local/bin/distractorremover-helper"
    public static let sudoersPath = "/etc/sudoers.d/distractorremover"
    public static let systemHostsPath = "/etc/hosts"

    /// LaunchAgent written by v1.x `enable_autostart.sh`; still honoured and cleaned up.
    public static let legacyLaunchAgentLabel = "com.sjk.distractorremover"

    public static let configSchemaVersion = 2
    /// Installed helper versions the app can drive. v4 adds the marker-order check;
    /// the app checks marker order itself before calling any version.
    public static let compatibleHelperVersions: Set<String> = ["2", "3", "4"]
    /// Limit enforced by `privileged_helper.sh`.
    public static let maxDomains = 512

    public static let retryDelays: [TimeInterval] = [5, 15, 30]
    public static let verifyInterval: TimeInterval = 30
    public static let tickInterval: TimeInterval = 5
}

/// Every on-disk location the app uses. A sandbox root redirects all of them
/// (including the hosts file) for development and automated checks.
public struct AppPaths {
    public let supportDirectory: URL
    public let hostsFile: URL
    public let isSandbox: Bool

    public var config: URL { supportDirectory.appendingPathComponent("config.json") }
    public var runtimeState: URL { supportDirectory.appendingPathComponent("runtime-state.json") }
    public var log: URL { supportDirectory.appendingPathComponent("app.log") }
    public var hostsBackups: URL { supportDirectory.appendingPathComponent("hosts-backups") }
    public var instanceLock: URL { supportDirectory.appendingPathComponent("instance.lock") }

    public var legacyLaunchAgent: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(AppConstants.legacyLaunchAgentLabel).plist")
    }

    public static func standard() -> AppPaths {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/distractorRemover")
        return AppPaths(
            supportDirectory: support,
            hostsFile: URL(fileURLWithPath: AppConstants.systemHostsPath),
            isSandbox: false
        )
    }

    public static func sandbox(root: URL) -> AppPaths {
        AppPaths(
            supportDirectory: root.appendingPathComponent("support"),
            hostsFile: root.appendingPathComponent("hosts"),
            isSandbox: true
        )
    }
}

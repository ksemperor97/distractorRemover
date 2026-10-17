import AppKit
import BlockerCore
import ServiceManagement

/// "Open at Login" via SMAppService, which shows up in System Settings →
/// General → Login Items. A v1.x LaunchAgent plist is still recognised and
/// removed when the user changes the setting.
enum LoginItem {
    static func legacyAgentInstalled(_ paths: AppPaths) -> Bool {
        FileManager.default.fileExists(atPath: paths.legacyLaunchAgent.path)
    }

    static func isEnabled(_ paths: AppPaths) -> Bool {
        SMAppService.mainApp.status == .enabled || legacyAgentInstalled(paths)
    }

    static func describe(_ paths: AppPaths) -> String {
        var text: String
        switch SMAppService.mainApp.status {
        case .enabled: text = "enabled"
        case .requiresApproval: text = "waiting for approval in System Settings"
        case .notRegistered: text = "off"
        case .notFound: text = "unavailable (run the installed app)"
        @unknown default: text = "unknown"
        }
        if legacyAgentInstalled(paths) { text += "; legacy LaunchAgent present" }
        return text
    }

    /// Returns a message for the user when approval is still needed.
    static func setEnabled(_ enabled: Bool, paths: AppPaths) throws -> String? {
        // Deleting the plist (without unloading it) avoids killing this process
        // when it was itself started by that agent; it simply won't load again.
        try? FileManager.default.removeItem(at: paths.legacyLaunchAgent)
        if enabled {
            try SMAppService.mainApp.register()
            if SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                return "Allow distractorRemover in System Settings → General → Login Items."
            }
        } else if SMAppService.mainApp.status != .notRegistered {
            try SMAppService.mainApp.unregister()
        }
        return nil
    }
}

enum SystemActions {
    static func openInTextEdit(_ file: URL) -> ProcessResult {
        ProcessRunner.run("/usr/bin/open", ["-a", "TextEdit", file.path])
    }

    static func openFolder(_ folder: URL) {
        try? FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        NSWorkspace.shared.open(folder)
    }

    /// Opens Terminal running `sudo nano` on the hosts file (fixed command).
    static func editInTerminal(_ file: URL, backup: URL, useSudo: Bool) -> ProcessResult {
        let editor = (useSudo ? "sudo /usr/bin/nano " : "/usr/bin/nano ") + ProcessRunner.shellQuote(file.path)
        let command = [
            "echo " + ProcessRunner.shellQuote("Backup created: \(backup.path)"),
            "echo " + ProcessRunner.shellQuote("nano: save with Control-O, Enter; exit with Control-X"),
            editor,
        ].joined(separator: " ; ")
        let script = """
        tell application "Terminal"
        activate
        do script \(ProcessRunner.appleScriptString(command))
        end tell
        """
        return ProcessRunner.run("/usr/bin/osascript", ["-e", script])
    }
}

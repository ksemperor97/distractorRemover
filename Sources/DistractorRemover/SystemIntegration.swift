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

    /// Returns true when the user still has to approve it in System Settings.
    static func setEnabled(_ enabled: Bool, paths: AppPaths) throws -> Bool {
        // Deleting the plist (without unloading it) avoids killing this process
        // when it was itself started by that agent; it simply won't load again.
        try? FileManager.default.removeItem(at: paths.legacyLaunchAgent)
        if enabled {
            try SMAppService.mainApp.register()
            if SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                return true
            }
        } else if SMAppService.mainApp.status != .notRegistered {
            try SMAppService.mainApp.unregister()
        }
        return false
    }
}

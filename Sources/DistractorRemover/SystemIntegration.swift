import ServiceManagement

/// "Open at Login" via SMAppService, which shows up in System Settings →
/// General → Login Items.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns true when the user still has to approve it in System Settings.
    static func setEnabled(_ enabled: Bool) throws -> Bool {
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

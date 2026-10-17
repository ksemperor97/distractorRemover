import AppKit
import BlockerCore
import ServiceManagement

// Used by uninstall.sh before the app bundle is deleted.
if CommandLine.arguments.contains("--unregister-login-item") {
    try? SMAppService.mainApp.unregister()
    exit(0)
}

let environment = AppEnvironment.make()

// One instance per user.
guard let instanceLock = InstanceLock(url: environment.paths.instanceLock) else {
    exit(0)   // another copy is already running
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate(environment: environment, instanceLock: instanceLock)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
    withExtendedLifetime(delegate) { app.run() }
}

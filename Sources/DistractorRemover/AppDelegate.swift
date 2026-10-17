import AppKit
import BlockerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let environment: AppEnvironment
    let logger: FileLogger
    let backend: HelperHostsBackend
    let controller: BlockerController
    private let instanceLock: InstanceLock

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var timer: Timer?
    var scheduleEditor: ScheduleEditor?

    init(environment: AppEnvironment, instanceLock: InstanceLock) {
        self.environment = environment
        self.instanceLock = instanceLock
        let paths = environment.paths
        logger = FileLogger(url: paths.log)
        backend = HelperHostsBackend(
            hostsFile: paths.hostsFile, scripts: environment.scripts, backupDirectory: paths.hostsBackups,
            broker: environment.broker, logger: logger
        )
        controller = BlockerController(
            store: FileConfigStore(url: paths.config),
            backend: backend,
            logger: logger,
            statusWriter: RuntimeStatusWriter(url: paths.runtimeState),
            version: environment.version
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("started v\(environment.version)\(environment.paths.isSandbox ? " (sandbox \(environment.paths.supportDirectory.deletingLastPathComponent().path))" : "")")
        if !environment.scripts.allPresent {
            logger.error("helper scripts missing in \(environment.scripts.directory.path)")
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        controller.onChange = { [weak self] in self?.updateIcon() }

        // Fires in .common mode so checks keep running while the menu is open.
        let timer = Timer(timeInterval: AppConstants.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.controller.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(clockDidChange), name: .NSSystemClockDidChange, object: nil)
        center.addObserver(self, selector: #selector(timeZoneDidChange), name: .NSSystemTimeZoneDidChange, object: nil)

        let backend = self.backend
        Task {
            // Warm the helper-status cache off the main thread (it runs sudo).
            await Task.detached { _ = backend.refreshHelperStatus() }.value
            await controller.reconcile(reason: "startup")
            if let notice = controller.startupNotice {
                controller.clearStartupNotice()
                Dialogs.warn("Settings were reset", notice)
            }
            if let show = environment.debugShow { debugShow(show) }
        }
    }

    @objc private func systemDidWake() {
        Task { await controller.tick(reason: "wake", force: true) }
    }

    @objc private func clockDidChange() {
        Task { await controller.tick(reason: "clock-change", force: true) }
    }

    @objc private func timeZoneDidChange() {
        Task { await controller.timeZoneDidChange() }
    }

    // MARK: Status item

    func updateIcon() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        let description: String
        if controller.applyStatus.isFailing {
            symbol = "exclamationmark.triangle.fill"
            description = "distractorRemover: update failed"
        } else if controller.actualBlocking {
            symbol = "shield.fill"
            description = "distractorRemover: blocking"
        } else {
            symbol = "shield"
            description = "distractorRemover: not blocking"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        image?.isTemplate = true
        button.image = image
        button.toolTip = controller.statusTitle()
    }

    /// The menu is built only when it opens, from current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menu.removeAllItems()
        for item in buildMenuItems() { menu.addItem(item) }
    }

    // MARK: Debug

    private func debugShow(_ what: String) {
        switch what {
        case "menu":
            // Popped at a fixed spot: a crowded menu bar may hide the status item.
            menuNeedsUpdate(menu)
            Dialogs.bringToFront()
            menu.popUp(positioning: nil, at: NSPoint(x: 200, y: 1000), in: nil)
        case "menu-dump":
            // Prints the menu as text and quits (used by CI and for review).
            menuNeedsUpdate(menu)
            for item in menu.items {
                let mark = item.state == .on ? "[x] " : ""
                print(item.isSeparatorItem ? "----" : "\(item.isEnabled ? "" : "(i) ")\(mark)\(item.title)")
            }
            fflush(stdout)
            NSApp.terminate(nil)
        case "schedule-editor": editSchedule()
        case "sites": editBlockedSites()
        case "hosts": editHostsFile()
        case "quit": quit()
        default: logger.warning("unknown DISTRACTORREMOVER_DEBUG_SHOW value: \(what)")
        }
    }
}

/// NSMenuItem that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", symbol: String? = nil, state: NSControl.StateValue = .off,
         handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        self.state = state
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

extension NSMenuItem {
    /// A disabled, informational line.
    static func note(_ title: String, symbol: String? = nil, indent: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.indentationLevel = indent
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    static func submenu(_ title: String, symbol: String? = nil, items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        let submenu = NSMenu(title: title)
        for child in items { submenu.addItem(child) }
        item.submenu = submenu
        return item
    }
}

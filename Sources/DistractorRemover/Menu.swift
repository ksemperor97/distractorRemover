import AppKit
import BlockerCore

extension AppDelegate {
    func buildMenuItems() -> [NSMenuItem] {
        let status = NSMenuItem.note(controller.statusTitle(), symbol: statusSymbol)
        if controller.configLoadError != nil {
            return [
                status,
                .separator(),
                ActionItem("Recover Damaged Configuration…") { [unowned self] in recoverDamagedConfig() },
                ActionItem("Reset Managed Hosts Section…") { [unowned self] in resetManagedHosts() },
                .submenu("Hosts File", symbol: "doc.text", items: hostsFileItems(includeBlockList: false)),
                .separator(),
                ActionItem("Status & Repair…") { [unowned self] in showStatus() },
                ActionItem("Quit distractorRemover", key: "q") { [unowned self] in quit() },
            ]
        }

        let config = controller.config
        var items: [NSMenuItem] = [status]
        if controller.applyStatus.isFailing {
            items.append(ActionItem("Retry Now", symbol: "arrow.clockwise") { [unowned self] in retryNow() })
        }
        items.append(.separator())

        var manualTitle = "Manual Blocking"
        if !config.manualEnabled && controller.scheduleActive() { manualTitle += " (schedule is blocking now)" }
        items.append(ActionItem(manualTitle, state: config.manualEnabled ? .on : .off) { [unowned self] in toggleManual() })
        items.append(ActionItem("Turn Off All Blocking…") { [unowned self] in turnOffAll() })
        items.append(.separator())

        items.append(ActionItem("Add Site…", key: "n", symbol: "plus") { [unowned self] in addSite() })
        let domainCount = Domains.expanded(config.sites).count
        items.append(.note("Blocked Services (\(config.sites.count)) · \(domainCount) domains"))
        if config.sites.isEmpty {
            items.append(.note("None yet — add one above", indent: 1))
        } else if controller.actualBlocking {
            // Locked while blocking: sites can be added, not removed.
            for site in config.sites {
                let item = ActionItem(Domains.displayName(site), symbol: "lock.fill") { [unowned self] in lockedRemove() }
                item.indentationLevel = 1
                items.append(item)
            }
        } else {
            for site in config.sites {
                let item = ActionItem(Domains.displayName(site), symbol: "xmark.circle") { [unowned self] in removeSite(site) }
                item.indentationLevel = 1
                item.toolTip = "Click to remove"
                items.append(item)
            }
        }
        items.append(.separator())

        items.append(.submenu("Schedule", symbol: "clock", items: scheduleItems()))
        items.append(.submenu("Hosts File", symbol: "doc.text", items: hostsFileItems(includeBlockList: true)))
        items.append(.separator())

        if environment.paths.isSandbox {
            items.append(.note("Open at Login (unavailable in sandbox)"))
        } else {
            items.append(ActionItem("Open at Login", state: LoginItem.isEnabled(environment.paths) ? .on : .off) { [unowned self] in
                toggleLoginItem()
            })
        }
        items.append(ActionItem("Status & Repair…") { [unowned self] in showStatus() })
        items.append(ActionItem("Reset Managed Hosts Section…") { [unowned self] in resetManagedHosts() })
        items.append(.separator())
        items.append(ActionItem("Quit distractorRemover", key: "q") { [unowned self] in quit() })
        return items
    }

    private var statusSymbol: String {
        if controller.configLoadError != nil || controller.applyStatus.isFailing { return "exclamationmark.triangle" }
        return controller.actualBlocking ? "shield.fill" : "shield"
    }

    private func scheduleItems() -> [NSMenuItem] {
        let config = controller.config
        let schedule = config.schedule
        var items: [NSMenuItem] = [
            ActionItem("Scheduled Blocking", state: schedule.enabled ? .on : .off) { [unowned self] in toggleSchedule() },
            .separator(),
        ]

        if schedule.enabled {
            let next = controller.formatMoment(controller.nextScheduleChange())
            if let pausedUntil = config.activeOverride(at: controller.currentTime) {
                items.append(.note("Paused until \(controller.formatMoment(pausedUntil))"))
                items.append(ActionItem("Resume Current Window") { [unowned self] in resumeSchedule() })
            } else if controller.scheduleActive() {
                items.append(.note("Active now · changes \(next)"))
            } else {
                items.append(.note("Inactive now · changes \(next)"))
            }
            items.append(.separator())
        }

        items.append(.note(schedule.windows.isEmpty ? "No time windows set" : "Blocked during:"))
        for window in schedule.windows {
            items.append(.note(ScheduleMath.formatWindow(window), indent: 1))
        }
        items.append(ActionItem("Edit Time Windows…") { [unowned self] in editSchedule() })
        items.append(.separator())

        let helperReady = backend.helperStatus.isUsable
        items.append(ActionItem("Password-Free Mode", state: helperReady ? .on : .off) { [unowned self] in togglePasswordFree() })
        if backend.helperNeedsUpgrade, let bundled = backend.bundledHelperVersion {
            items.append(ActionItem("Upgrade Helper to v\(bundled)…") { [unowned self] in upgradeHelper() })
        }
        return items
    }

    private func hostsFileItems(includeBlockList: Bool) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if includeBlockList {
            items.append(ActionItem("Edit Block List as Text…") { [unowned self] in editBlockListAsText() })
            items.append(.separator())
        }
        items.append(ActionItem("Open Hosts File in TextEdit…") { [unowned self] in viewHostsFile() })
        items.append(ActionItem("Edit Hosts File as Administrator…") { [unowned self] in editHostsFileDirectly() })
        items.append(ActionItem("Open Hosts Backup Folder…") { [unowned self] in
            SystemActions.openFolder(environment.paths.hostsBackups)
        })
        return items
    }
}

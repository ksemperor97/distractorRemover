import AppKit
import BlockerCore

extension AppDelegate {
    func buildMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        // Status line; it becomes a button only when something failed.
        if controller.applyStatus.isFailing && controller.configLoadError == nil {
            items.append(ActionItem(controller.statusTitle(), symbol: "exclamationmark.triangle") { [unowned self] in
                if controller.hostsNeedManualFix { editHostsFile() } else { retry() }
            })
        } else {
            items.append(.note(controller.statusTitle(), symbol: statusSymbol))
        }
        items.append(.separator())

        if controller.configLoadError == nil {
            if controller.actualBlocking || controller.desiredBlocking() {
                items.append(ActionItem("Stop Blocking…", symbol: "pause.circle") { [unowned self] in stopBlocking() })
            } else {
                items.append(ActionItem("Start Blocking", symbol: "play.circle") { [unowned self] in startBlocking() })
            }
            items.append(.separator())
            let count = controller.config.sites.count
            items.append(ActionItem("Edit Blocked Sites… (\(count))", key: "e", symbol: "list.bullet") { [unowned self] in
                editBlockedSites()
            })
            items.append(ActionItem("Schedule…", symbol: "clock") { [unowned self] in editSchedule() })
            items.append(.separator())
        }

        items.append(ActionItem("Edit Hosts File…", symbol: "doc.text") { [unowned self] in editHostsFile() })
        if environment.paths.isSandbox {
            items.append(.note("Open at Login (unavailable in sandbox)"))
        } else {
            items.append(ActionItem("Open at Login", state: LoginItem.isEnabled(environment.paths) ? .on : .off) { [unowned self] in
                toggleLoginItem()
            })
        }
        items.append(ActionItem("Quit distractorRemover…", key: "q") { [unowned self] in quit() })
        return items
    }

    private var statusSymbol: String {
        if controller.configLoadError != nil { return "exclamationmark.triangle" }
        return controller.actualBlocking ? "shield.fill" : "shield"
    }
}

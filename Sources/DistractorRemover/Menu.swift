import AppKit
import AppText
import BlockerCore

extension AppDelegate {
    /// Built every time the menu opens, so a language change shows immediately.
    func buildMenuItems() -> [NSMenuItem] {
        let text = Texts(calendar: controller.calendar)
        var items: [NSMenuItem] = []

        // Status line; it becomes a button only when something failed.
        let status = text.status(controller.status(), now: controller.currentTime)
        if controller.applyStatus.isFailing && controller.configLoadError == nil {
            items.append(ActionItem(status, symbol: "exclamationmark.triangle") { [unowned self] in
                if controller.hostsNeedManualFix { editHostsFile() } else { retry() }
            })
        } else {
            items.append(.note(status, symbol: statusSymbol))
        }
        items.append(.separator())

        if controller.configLoadError == nil {
            if controller.actualBlocking || controller.desiredBlocking() {
                items.append(ActionItem(text.stopBlocking, symbol: "pause.circle") { [unowned self] in stopBlocking() })
            } else {
                items.append(ActionItem(text.startBlocking, symbol: "play.circle") { [unowned self] in startBlocking() })
            }
            items.append(.separator())
            items.append(ActionItem(text.editSites(count: controller.config.sites.count), key: "e", symbol: "list.bullet") {
                [unowned self] in editBlockedSites()
            })
            items.append(ActionItem(text.schedule, symbol: "clock") { [unowned self] in editSchedule() })
            items.append(.separator())
        }

        items.append(ActionItem(text.editHosts, symbol: "doc.text") { [unowned self] in editHostsFile() })
        let loginEnabled = !environment.paths.isSandbox && LoginItem.isEnabled(environment.paths)
        items.append(ActionItem(text.openAtLogin, state: loginEnabled ? .on : .off) { [unowned self] in
            toggleLoginItem()
        })
        items.append(languageMenu())
        items.append(ActionItem(text.quit, key: "q") { [unowned self] in quit() })
        return items
    }

    /// Named in both languages so it can be found whichever language is showing.
    private func languageMenu() -> NSMenuItem {
        let current = Localizer.shared.preference
        let choices: [(LanguagePreference, String)] = [
            (.system, L("System Default", "시스템 설정 따름")),
            (.korean, "한국어"),
            (.english, "English"),
        ]
        let items = choices.map { preference, title in
            ActionItem(title, state: preference == current ? .on : .off) { [unowned self] in
                Localizer.shared.preference = preference
                updateIcon()
            }
        }
        return .submenu("언어 (Language)", symbol: "globe", items: items)
    }

    private var statusSymbol: String {
        if controller.configLoadError != nil { return "exclamationmark.triangle" }
        return controller.actualBlocking ? "shield.fill" : "shield"
    }
}

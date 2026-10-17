import AppKit
import BlockerCore

/// User flows behind the menu items. Each one hands a config transformation to
/// the controller, which applies it, or leaves everything unchanged if the
/// administrator prompt is cancelled.
extension AppDelegate {
    private func perform(_ body: @escaping @MainActor () async -> Void) {
        Task { @MainActor in await body() }
    }

    private func report(_ outcome: Outcome) {
        guard case .failed(let message) = outcome else { return }
        Dialogs.warn("Couldn’t update blocking", "\(message)\n\nThe app keeps retrying in the background.")
    }

    // MARK: Blocking

    func startBlocking() {
        guard !controller.config.sites.isEmpty else {
            Dialogs.info("No sites yet", "Add the sites you want to block first.")
            return editBlockedSites()
        }
        perform {
            self.report(await self.controller.update(reason: "start") { config, _ in config.startingBlocking() })
        }
    }

    /// Stops both manual and scheduled blocking. The schedule itself stays on
    /// and starts blocking again at its next window.
    func stopBlocking() {
        var message = "Sites will be unblocked now."
        let calendar = controller.calendar
        let stopped = controller.config.stoppingBlocking(at: controller.currentTime, calendar: calendar)
        if stopped.schedule.enabled,
           let next = stopped.nextScheduleChange(after: controller.currentTime, calendar: calendar) {
            message += " Your schedule starts blocking again \(controller.formatMoment(next))."
        }
        guard Dialogs.confirm("Stop blocking?", message, ok: "Stop Blocking", cancel: "Keep Blocking") else { return }
        perform {
            self.report(await self.controller.update(reason: "stop") { config, now in
                config.stoppingBlocking(at: now, calendar: calendar)
            })
        }
    }

    func retry() {
        perform { self.report(await self.controller.reconcile(reason: "retry", allowPrompt: true)) }
    }

    // MARK: Sites

    func editBlockedSites() {
        let original = controller.config.sites
        var draft = original.joined(separator: "\n") + (original.isEmpty ? "" : "\n")
        var sites: [String]
        while true {
            var note = "One site per line, e.g. youtube.com. Full URLs are fine. YouTube, Instagram, X, Reddit, "
                + "TikTok and Facebook also block their other domains. Lines starting with # are ignored."
            if controller.actualBlocking { note += "\n\nWhile blocking, you can add sites but not remove them." }
            guard let edited = Dialogs.editText("Blocked Sites", note, text: draft, ok: "Save") else { return }
            draft = edited
            do {
                sites = try Domains.parseSiteList(edited)
            } catch {
                Dialogs.warn("Check the list", "\(error)")
                continue
            }
            if !SiteEditPolicy.isAllowed(old: original, new: sites, actuallyBlocking: controller.actualBlocking) {
                let removed = SiteEditPolicy.removedSites(from: original, to: sites).joined(separator: ", ")
                Dialogs.warn("Can’t remove sites while blocking",
                             "Stop blocking first to remove: \(removed)")
                continue
            }
            break
        }
        guard sites != original else { return }
        let finalSites = sites
        perform {
            self.report(await self.controller.update(reason: "sites-edited") { config, _ in
                var next = config
                next.sites = finalSites
                return next
            })
        }
    }

    // MARK: Schedule

    func editSchedule() {
        if let editor = scheduleEditor {
            editor.show()
            return
        }
        let schedule = controller.config.schedule
        let editor = ScheduleEditor(enabled: schedule.enabled || schedule.windows.isEmpty,
                                    windows: schedule.windows) { [weak self] result in
            guard let self else { return }
            self.scheduleEditor = nil
            guard let (enabled, windows) = result else { return }   // cancelled
            self.perform { await self.saveSchedule(enabled: enabled, windows: windows) }
        }
        scheduleEditor = editor
        editor.show()
    }

    private func saveSchedule(enabled: Bool, windows: [ScheduleWindow]) async {
        var enabled = enabled && !windows.isEmpty
        // A schedule switches blocking on and off unattended, which needs the
        // password-free helper. It is installed once, with one password prompt.
        if enabled && !backend.helperStatus.isUsable {
            let agreed = Dialogs.confirm(
                "Allow scheduled blocking?",
                "To turn blocking on and off by itself, distractorRemover installs a small helper that can only "
                    + "edit its own section of the hosts file. You’ll be asked for your password once.",
                ok: "Continue", cancel: "Save Without Schedule"
            )
            if agreed {
                enabled = await installHelper()
            } else {
                enabled = false
            }
        }
        report(await controller.update(reason: "schedule-saved") { config, _ in
            config.withSchedule(enabled: enabled, windows: windows)
        })
    }

    /// Runs the installer behind one administrator prompt.
    private func installHelper() async -> Bool {
        let backend = self.backend
        let user = NSUserName()
        do {
            try await Task.detached { try backend.installHelper(forUser: user) }.value
            return true
        } catch BlockerError.cancelled {
            return false
        } catch {
            Dialogs.warn("Couldn’t set up scheduled blocking", "\(error)")
            return false
        }
    }

    // MARK: Hosts file

    /// For when something looks wrong: edit the whole hosts file as text.
    func editHostsFile() {
        perform {
            let current: String
            do {
                current = try await self.controller.readHostsText()
            } catch {
                return Dialogs.warn("Couldn’t read the hosts file", "\(error)")
            }
            var note = "The full \(self.environment.paths.hostsFile.path) file. A backup is saved before your changes, "
                + "and you’ll be asked for your password. The lines between the distractorRemover markers "
                + "follow your blocked sites and are rewritten automatically."
            if self.controller.hostsNeedManualFix {
                note = "The distractorRemover marker lines below are damaged (missing, reversed or nested), so the "
                    + "app left this file alone. Delete every line from “# === distractorRemover START” through "
                    + "“# === distractorRemover END ===”, keep your own lines, and Save. Blocking is then written "
                    + "again.\n\n" + note
            }
            guard let edited = Dialogs.editText("Hosts File", note, text: current, ok: "Save"),
                  edited != current else { return }
            switch await self.controller.saveEditedHosts(edited) {
            case .success:
                break
            case .failure(.cancelled):
                break
            case .failure(let error):
                Dialogs.warn("Couldn’t save the hosts file", "\(error)")
            }
        }
    }

    // MARK: App

    /// Quitting leaves the hosts file as it is and stops the schedule, so say so first.
    func quit() {
        let blocking = controller.actualBlocking
        let scheduled = controller.config.schedule.enabled
        guard blocking || scheduled else { return NSApp.terminate(nil) }
        var lines: [String] = []
        if blocking { lines.append("The sites stay blocked after distractorRemover quits.") }
        if scheduled { lines.append("Your schedule won’t turn blocking on or off until you open distractorRemover again.") }
        let buttons = blocking ? ["Quit", "Stop Blocking and Quit", "Cancel"] : ["Quit", "Cancel"]
        let choice = Dialogs.show("Quit distractorRemover?", lines.joined(separator: "\n\n"), buttons: buttons)
        switch buttons[choice] {
        case "Quit":
            NSApp.terminate(nil)
        case "Stop Blocking and Quit":
            let calendar = controller.calendar
            perform {
                let outcome = await self.controller.update(reason: "stop-and-quit") { config, now in
                    config.stoppingBlocking(at: now, calendar: calendar)
                }
                if outcome.succeeded { NSApp.terminate(nil) } else { self.report(outcome) }
            }
        default:
            break
        }
    }

    func toggleLoginItem() {
        let enable = !LoginItem.isEnabled(environment.paths)
        do {
            if let note = try LoginItem.setEnabled(enable, paths: environment.paths) {
                Dialogs.info("Approval needed", note)
            }
        } catch {
            Dialogs.warn("Couldn’t change Open at Login", "\(error.localizedDescription)\n\nInstall the app in /Applications and run it from there.")
        }
    }
}

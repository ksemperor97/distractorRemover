import AppKit
import BlockerCore

/// User flows behind the menu items. Each one confirms with the user, then
/// hands a config transformation to the controller, which applies it or
/// leaves everything unchanged if the administrator prompt is cancelled.
extension AppDelegate {
    private func perform(_ body: @escaping @MainActor () async -> Void) {
        Task { @MainActor in await body() }
    }

    private func report(_ outcome: Outcome, title: String = "Couldn’t update blocking") {
        guard case .failed(let message) = outcome else { return }
        Dialogs.warn(title, "\(message)\n\nThe app will keep retrying. Open Status & Repair for details.")
    }

    // MARK: Blocking

    func toggleManual() {
        let turningOn = !controller.config.manualEnabled
        if turningOn && controller.config.sites.isEmpty {
            Dialogs.info("No sites yet", "Add a site to block first.")
            return
        }
        if !turningOn {
            var message = "This turns off manual blocking."
            if controller.scheduleActive() {
                message += "\n\nThe current schedule window is still active, so sites will remain blocked."
            }
            guard Dialogs.confirm("Turn off manual blocking?", message, ok: "Turn Off", cancel: "Keep Blocking") else { return }
        }
        perform {
            let outcome = await self.controller.update(reason: "manual-toggle") { config, _ in
                var next = config
                next.manualEnabled = turningOn
                return next
            }
            self.report(outcome)
        }
    }

    @discardableResult
    func turnOffAll(confirm: Bool = true) -> Task<Outcome, Never>? {
        if !controller.desiredBlocking() && !controller.actualBlocking {
            if confirm { Dialogs.info("Already off", "No blocking is currently active.") }
            return Task { .ok }
        }
        if confirm {
            guard Dialogs.confirm(
                "Turn off all blocking?",
                "Manual blocking will turn off. If a schedule window is active, it will be paused until "
                    + "that window ends; future schedule windows stay enabled.",
                ok: "Turn Off All", cancel: "Keep Blocking"
            ) else { return nil }
        }
        let calendar = controller.calendar
        return Task { @MainActor in
            let outcome = await self.controller.update(reason: "turn-off-all") { config, now in
                config.turningOffAll(at: now, calendar: calendar)
            }
            self.report(outcome)
            return outcome
        }
    }

    // MARK: Sites

    func addSite() {
        guard let text = Dialogs.prompt(
            "Add a site to block",
            "Enter a website, e.g. youtube.com or instagram.com. Presets cover a service’s other domains.",
            placeholder: "youtube.com", ok: "Add"
        ) else { return }
        guard let domain = Domains.normalize(text) else {
            Dialogs.info("Not a website address", "“\(text.trimmingCharacters(in: .whitespaces))” doesn’t look like a website address. Try something like youtube.com.")
            return
        }
        let site = Domains.canonicalSite(domain)
        if controller.config.sites.contains(site) {
            Dialogs.info("Already added", "\(Domains.displayName(site)) is already in your list.")
            return
        }
        perform {
            let outcome = await self.controller.update(reason: "site-added") { config, _ in
                var next = config
                if !next.sites.contains(site) { next.sites.append(site) }
                return next
            }
            self.report(outcome)
        }
    }

    func removeSite(_ site: String) {
        guard !controller.actualBlocking else { return lockedRemove() }
        guard Dialogs.confirm("Remove \(site)?", "It will no longer be blocked.", ok: "Remove", destructive: true) else { return }
        perform {
            let outcome = await self.controller.update(reason: "site-removed") { config, _ in
                var next = config
                next.sites.removeAll { $0 == site }
                return next
            }
            self.report(outcome)
        }
    }

    func lockedRemove() {
        Dialogs.info(
            "Locked while blocking",
            "You can’t remove a site while blocking is on — you can only add.\n"
                + "Use “Turn Off All Blocking…” first, then remove it."
        )
    }

    func editBlockListAsText() {
        let original = controller.config.sites
        var draft = original.joined(separator: "\n") + (original.isEmpty ? "" : "\n")
        var sites: [String]
        while true {
            var note = "Enter one domain or URL per line. You can also paste 127.0.0.1/::1 lines copied "
                + "from the hosts file. Blank lines and # comments are ignored."
            if controller.actualBlocking { note += " Blocking is active, so existing entries cannot be removed." }
            guard let edited = Dialogs.editText("Edit block list as text", note, text: draft, ok: "Save") else { return }
            draft = edited
            do {
                sites = try Domains.parseSiteList(edited)
            } catch {
                Dialogs.warn("Invalid block list", "\(error)")
                continue
            }
            if !SiteEditPolicy.isAllowed(old: original, new: sites, actuallyBlocking: controller.actualBlocking) {
                Dialogs.warn(
                    "Locked while blocking",
                    "Existing entries cannot be removed while blocking is active. You can still add new entries."
                )
                continue
            }
            break
        }
        guard sites != original else { return }
        let finalSites = sites
        perform {
            let outcome = await self.controller.update(reason: "block-list-edited") { config, _ in
                var next = config
                next.sites = finalSites
                return next
            }
            self.report(outcome)
        }
    }

    // MARK: Schedule

    func toggleSchedule() {
        let schedule = controller.config.schedule
        if schedule.enabled {
            if controller.scheduleActive() && !Dialogs.confirm(
                "Disable the schedule?",
                "The current schedule window is active. Disabling it may unblock sites now.",
                ok: "Disable Schedule", cancel: "Keep Schedule"
            ) { return }
            perform {
                let outcome = await self.controller.update(reason: "schedule-disabled") { config, _ in
                    config.withSchedule(enabled: false)
                }
                self.report(outcome)
            }
            return
        }
        guard !schedule.windows.isEmpty else {
            Dialogs.info("Set a time window first", "Open “Edit Time Windows…” and add at least one, e.g. Mon–Fri 09:00–18:00.")
            return
        }
        perform {
            if !self.backend.helperStatus.isUsable {
                guard Dialogs.confirm(
                    "Enable password-free mode?",
                    "A schedule turns blocking on and off by itself, so it needs to update the hosts file "
                        + "without asking for your password each time.\n\nInstall the one-time helper now? "
                        + "(You’ll be asked for your password once. It only allows editing your hosts file.)",
                    ok: "Enable"
                ) else { return }
                guard await self.installHelper() else { return }
            }
            let outcome = await self.controller.update(reason: "schedule-enabled") { config, _ in
                config.withSchedule(enabled: true)
            }
            self.report(outcome)
        }
    }

    func resumeSchedule() {
        perform {
            let outcome = await self.controller.update(reason: "schedule-resumed") { config, _ in
                var next = config
                next.scheduleOverrideUntil = nil
                return next
            }
            self.report(outcome)
        }
    }

    func editSchedule() {
        if let editor = scheduleEditor {
            editor.show()
            return
        }
        let editor = ScheduleEditor(windows: controller.config.schedule.windows) { [weak self] windows in
            guard let self else { return }
            self.scheduleEditor = nil
            guard let windows else { return }   // cancelled
            self.perform {
                let outcome = await self.controller.update(reason: "schedule-edited") { config, _ in
                    config.withScheduleWindows(windows)
                }
                self.report(outcome)
                if outcome.succeeded, !windows.isEmpty, !self.controller.config.schedule.enabled,
                   Dialogs.confirm("Schedule saved", "Turn on scheduled blocking now?", ok: "Turn On", cancel: "Not Now") {
                    self.toggleSchedule()
                }
            }
        }
        scheduleEditor = editor
        editor.show()
    }

    // MARK: Password-free helper

    /// Runs the installer behind one administrator prompt.
    func installHelper() async -> Bool {
        let backend = self.backend
        let user = NSUserName()
        do {
            try await Task.detached { try backend.installHelper(forUser: user) }.value
            return true
        } catch BlockerError.cancelled {
            return false
        } catch {
            Dialogs.warn("Couldn’t enable password-free mode", "\(error)")
            return false
        }
    }

    func togglePasswordFree() {
        guard backend.helperStatus.isUsable else {
            guard Dialogs.confirm(
                "Enable password-free mode?",
                "This installs a small helper (one-time password) so distractorRemover can block and unblock — "
                    + "including on a schedule — without asking for your password each time.\n\n"
                    + "It only allows editing your hosts file.",
                ok: "Enable"
            ) else { return }
            perform { _ = await self.installHelper() }
            return
        }
        guard Dialogs.confirm(
            "Turn off password-free mode?",
            "Scheduled blocking will be turned off, and manual changes will ask for your password again.",
            ok: "Turn Off"
        ) else { return }

        let previous = controller.config
        let restore: (Config, Date) -> Config = { config, _ in
            var next = config
            next.schedule = previous.schedule
            next.scheduleOverrideUntil = previous.scheduleOverrideUntil
            return next
        }
        perform {
            // Turn the schedule off first, while the helper can still apply it silently.
            if previous.schedule.enabled {
                let outcome = await self.controller.update(reason: "helper-removal-preflight", allowPrompt: false) { config, _ in
                    config.withSchedule(enabled: false)
                }
                if case .failed(let message) = outcome {
                    await self.controller.update(reason: "helper-removal-reverted", allowPrompt: false, restore)
                    Dialogs.warn("Couldn’t turn off the schedule", message)
                    return
                }
            }
            let backend = self.backend
            do {
                try await Task.detached { try backend.uninstallHelper() }.value
                self.updateIcon()
            } catch {
                if previous.schedule.enabled {
                    await self.controller.update(reason: "helper-removal-cancelled", allowPrompt: false, restore)
                }
                if case BlockerError.cancelled = error { return }
                Dialogs.warn("Couldn’t remove the helper", "\(error)")
            }
        }
    }

    func upgradeHelper() {
        guard let bundled = backend.bundledHelperVersion else { return }
        guard Dialogs.confirm(
            "Upgrade password-free helper to v\(bundled)?",
            "Blocking keeps working with the installed helper. The upgrade adds backup-based recovery for a "
                + "damaged hosts section and is rolled back automatically if installation fails.",
            ok: "Upgrade", cancel: "Not Now"
        ) else { return }
        perform { _ = await self.installHelper() }
    }

    // MARK: Repair

    func retryNow() {
        if controller.configLoadError != nil { return recoverDamagedConfig() }
        perform { self.report(await self.controller.reconcile(reason: "manual-retry", allowPrompt: true)) }
    }

    func recoverDamagedConfig() {
        guard controller.configLoadError != nil else { return }
        guard Dialogs.confirm(
            "Recover damaged configuration?",
            "The unreadable file will be preserved with a .corrupt timestamp, then a safe empty configuration "
                + "will be created. Nothing is overwritten unless you confirm.",
            ok: "Back Up & Reset", cancel: "Keep Unchanged"
        ) else { return }
        perform {
            switch await self.controller.recoverDamagedConfig() {
            case .failure(let error):
                Dialogs.warn("Recovery failed", "\(error)")
            case .success(let backup):
                Dialogs.info(
                    "Configuration recovered",
                    "The original file was preserved at:\n\(backup.path)\n\nBlocking will now follow the new empty configuration."
                )
                self.report(await self.controller.reconcile(reason: "config-recovered", allowPrompt: true))
            }
        }
    }

    func resetManagedHosts() {
        guard Dialogs.confirm(
            "Reset managed hosts section?",
            "This removes distractorRemover’s marker lines, including an incomplete section. A backup of the "
                + "complete hosts file is created first. If blocking is requested, a clean section is applied again.",
            ok: "Back Up & Reset"
        ) else { return }
        perform {
            switch await self.controller.resetManagedSection(allowPrompt: true) {
            case .failure(.cancelled):
                return
            case .failure(let error):
                Dialogs.warn("Reset failed", "\(error)")
            case .success(let message):
                if self.controller.configLoadError == nil {
                    self.report(await self.controller.reconcile(reason: "managed-section-reset", allowPrompt: true))
                }
                Dialogs.info("Managed section reset", (message.isEmpty ? "A hosts backup was created." : message)
                    + "\n\nThe managed section was repaired.")
            }
        }
    }

    func showStatus() {
        perform {
            let backend = self.backend
            await Task.detached { _ = backend.refreshHelperStatus() }.value
            let paths = self.environment.paths
            let controller = self.controller
            let content = try? backend.readHosts()
            let matches = controller.configLoadError == nil && content.map {
                HostsFile.matches($0, domains: controller.config.blockDomains(at: controller.currentTime, calendar: controller.calendar))
            } == true
            let override = controller.config.activeOverride(at: controller.currentTime)
            var lines = [
                "Version: \(self.environment.version)\(paths.isSandbox ? " (sandbox)" : "")",
                "Requested: \(controller.desiredBlocking() ? "ON" : "OFF") (\(controller.activeReason().rawValue))",
                "Actual hosts: \(controller.actualBlocking ? "ON" : "OFF")",
                "State matches: \(matches ? "yes" : "NO")",
                "Apply status: \(controller.applyStatus.rawValue)",
                "Password-free helper: \(backend.helperDiagnostic)",
                "Schedule override: \(override.map(ConfigCodec.formatLocalTimestamp) ?? "none")",
                "Open at login: \(paths.isSandbox ? "n/a" : LoginItem.describe(paths))",
                "Hosts: \(paths.hostsFile.path)",
                "Config: \(paths.config.path)",
                "Runtime status: \(paths.runtimeState.path)",
                "Log: \(paths.log.path)",
            ]
            if controller.configLoadError != nil {
                lines.append("\nConfiguration is locked to prevent accidental data loss.")
            }
            if !controller.lastError.isEmpty {
                lines.append("\nLast error:\n\(controller.lastError)")
            }
            let repairTitle = controller.configLoadError != nil ? "Recover Configuration" : "Repair Now"
            let choice = Dialogs.show(
                "distractorRemover Status & Repair", lines.joined(separator: "\n"),
                buttons: ["Close", repairTitle, "Reset Managed Hosts Section"]
            )
            switch choice {
            case 1:
                if controller.configLoadError != nil {
                    self.recoverDamagedConfig()
                } else {
                    self.report(await controller.reconcile(reason: "diagnostic-repair", allowPrompt: true))
                }
            case 2:
                self.resetManagedHosts()
            default:
                break
            }
        }
    }

    // MARK: Hosts file

    func viewHostsFile() {
        let result = SystemActions.openInTextEdit(environment.paths.hostsFile)
        if !result.succeeded {
            Dialogs.warn("Couldn’t open the hosts file", result.message.isEmpty ? "TextEdit could not open the file." : result.message)
        }
    }

    func editHostsFileDirectly() {
        guard Dialogs.confirm(
            "Edit the hosts file directly?",
            "The complete file is backed up first, then Terminal opens sudo nano. Incorrect edits can affect "
                + "networking. Lines between the distractorRemover markers are managed by the app and may be "
                + "rewritten; use “Edit Block List as Text…” for lasting changes.\n\n"
                + "In nano: Control-O saves, Enter confirms, Control-X exits.",
            ok: "Back Up & Open Terminal"
        ) else { return }
        let paths = environment.paths
        do {
            let backup = try HostsBackup.create(from: paths.hostsFile, in: paths.hostsBackups)
            let result = SystemActions.editInTerminal(paths.hostsFile, backup: backup, useSudo: !paths.isSandbox)
            guard result.succeeded else {
                Dialogs.warn("Couldn’t open Terminal", result.message.isEmpty ? "Terminal could not be opened." : result.message)
                return
            }
            logger.info("opened direct hosts editor after backup to \(backup.path)")
        } catch {
            Dialogs.warn("Couldn’t open the editor", "\(error)")
        }
    }

    // MARK: App

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

    func quit() {
        if !controller.actualBlocking && !controller.config.schedule.enabled {
            NSApp.terminate(nil)
            return
        }
        let choice = Dialogs.show(
            "Quit distractorRemover?",
            "Keeping current blocking leaves the hosts rule in place, but scheduled changes stop until the app starts again.",
            buttons: ["Keep Blocking and Quit", "Unblock and Quit", "Cancel"]
        )
        switch choice {
        case 0:
            NSApp.terminate(nil)
        case 1:
            guard let task = turnOffAll(confirm: false) else { return }
            Task { @MainActor in
                if await task.value.succeeded { NSApp.terminate(nil) }
            }
        default:
            break
        }
    }
}

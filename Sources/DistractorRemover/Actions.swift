import AppKit
import AppText
import BlockerCore

/// User flows behind the menu items. Each one hands a config transformation to
/// the controller, which applies it, or leaves everything unchanged if the
/// administrator prompt is cancelled.
extension AppDelegate {
    private var text: Texts { Texts(calendar: controller.calendar) }

    private func perform(_ body: @escaping @MainActor () async -> Void) {
        Task { @MainActor in await body() }
    }

    private func report(_ outcome: Outcome) {
        guard case .failed(let message) = outcome else { return }
        let detail = controller.lastFailure.map(text.failure) ?? message
        Dialogs.warn(L("Couldn’t update blocking", "차단을 적용하지 못했어요"),
                     detail + L("\n\nThe app keeps retrying in the background.", "\n\n앱이 계속 다시 시도해요."))
    }

    // MARK: Blocking

    func startBlocking() {
        guard !controller.config.sites.isEmpty else {
            Dialogs.info(L("No sites yet", "사이트가 없어요"),
                         L("Add the sites you want to block first.", "먼저 차단할 사이트를 추가해 주세요."))
            return editBlockedSites()
        }
        perform {
            self.report(await self.controller.update(reason: "start") { config, _ in config.startingBlocking() })
        }
    }

    /// Stops both manual and scheduled blocking. The schedule itself stays on
    /// and starts blocking again at its next window.
    func stopBlocking() {
        let now = controller.currentTime
        let calendar = controller.calendar
        let stopped = controller.config.stoppingBlocking(at: now, calendar: calendar)
        var message = L("Sites will be unblocked now.", "지금 사이트 차단을 풀어요.")
        if stopped.schedule.enabled, let next = stopped.nextScheduleChange(after: now, calendar: calendar) {
            let when = text.moment(next, now: now)
            message += L(" Your schedule starts blocking again at \(when).", " 스케줄은 \(when)에 다시 차단해요.")
        }
        guard Dialogs.confirm(L("Stop blocking?", "차단을 해제할까요?"), message,
                              ok: L("Stop Blocking", "차단 해제"), cancel: L("Keep Blocking", "계속 차단"))
        else { return }
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
            var note = L(
                "One site per line, e.g. youtube.com. Full URLs are fine. YouTube, Instagram, X, Reddit, "
                    + "TikTok and Facebook also block their other domains. Lines starting with # are ignored.",
                "한 줄에 사이트 하나씩 적어요(예: youtube.com). 전체 URL도 괜찮아요. YouTube, Instagram, X, Reddit, "
                    + "TikTok, Facebook은 다른 도메인까지 함께 차단해요. #으로 시작하는 줄은 무시해요."
            )
            if controller.actualBlocking {
                note += L("\n\nWhile blocking, you can add sites but not remove them.",
                          "\n\n차단 중에는 사이트를 추가할 수만 있고 지울 수는 없어요.")
            }
            guard let edited = Dialogs.editText(L("Blocked Sites", "차단 사이트"), note, text: draft, ok: L("Save", "저장"))
            else { return }
            draft = edited
            do {
                sites = try Domains.parseSiteList(edited)
            } catch let error as Domains.ParseError {
                Dialogs.warn(L("Check the list", "목록을 확인해 주세요"), text.parseError(error))
                continue
            } catch {
                Dialogs.warn(L("Check the list", "목록을 확인해 주세요"), "\(error)")
                continue
            }
            if !SiteEditPolicy.isAllowed(old: original, new: sites, actuallyBlocking: controller.actualBlocking) {
                let removed = SiteEditPolicy.removedSites(from: original, to: sites).joined(separator: ", ")
                Dialogs.warn(L("Can’t remove sites while blocking", "차단 중에는 사이트를 지울 수 없어요"),
                             L("Stop blocking first to remove: \(removed)", "먼저 차단을 해제한 뒤 지워 주세요: \(removed)"))
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
                L("Allow scheduled blocking?", "스케줄 차단을 허용할까요?"),
                L("To turn blocking on and off by itself, distractorRemover installs a small helper that can only "
                    + "edit its own section of the hosts file. You’ll be asked for your password once.",
                  "차단을 스스로 켜고 끄려면 distractorRemover가 hosts 파일의 자기 구간만 고칠 수 있는 작은 helper를 "
                    + "설치해요. 암호는 한 번만 물어요."),
                ok: L("Continue", "계속"), cancel: L("Save Without Schedule", "스케줄 없이 저장")
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
            Dialogs.warn(L("Couldn’t set up scheduled blocking", "스케줄 차단을 설정하지 못했어요"), "\(error)")
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
                return Dialogs.warn(L("Couldn’t read the hosts file", "hosts 파일을 읽지 못했어요"), "\(error)")
            }
            let path = self.environment.paths.hostsFile.path
            var note = L(
                "The full \(path) file. A backup is saved before your changes, and you’ll be asked for your "
                    + "password. The lines between the distractorRemover markers follow your blocked sites and "
                    + "are rewritten automatically.",
                "\(path) 파일 전체예요. 바꾸기 전에 백업을 저장하고, 저장할 때 암호를 물어요. distractorRemover "
                    + "표시 줄 사이의 내용은 차단 사이트 목록에 맞춰 자동으로 다시 쓰여요."
            )
            if self.controller.hostsNeedManualFix {
                note = L(
                    "The distractorRemover marker lines below are damaged (missing, reversed or nested), so the "
                        + "app left this file alone. Delete every line from “# === distractorRemover START” through "
                        + "“# === distractorRemover END ===”, keep your own lines, and Save. Blocking is then "
                        + "written again.",
                    "아래 distractorRemover 표시 줄이 손상되어(빠짐, 순서 뒤바뀜, 겹침) 앱이 이 파일을 건드리지 "
                        + "않았어요. “# === distractorRemover START” 줄부터 “# === distractorRemover END ===” 줄까지 "
                        + "지우고, 직접 넣은 줄은 남긴 채 저장해 주세요. 그러면 차단이 다시 적용돼요."
                ) + "\n\n" + note
            }
            guard let edited = Dialogs.editText(L("Hosts File", "hosts 파일"), note, text: current, ok: L("Save", "저장")),
                  edited != current else { return }
            switch await self.controller.saveEditedHosts(edited) {
            case .success, .failure(.cancelled):
                break
            case .failure(let error):
                Dialogs.warn(L("Couldn’t save the hosts file", "hosts 파일을 저장하지 못했어요"), "\(error)")
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
        if blocking {
            lines.append(L("The sites stay blocked after distractorRemover quits.",
                           "distractorRemover를 종료해도 사이트는 계속 차단돼요."))
        }
        if scheduled {
            lines.append(L("Your schedule won’t turn blocking on or off until you open distractorRemover again.",
                           "distractorRemover를 다시 열 때까지 스케줄이 차단을 켜거나 끄지 않아요."))
        }
        let quitTitle = L("Quit", "종료")
        let stopTitle = L("Stop Blocking and Quit", "차단 해제 후 종료")
        let buttons = blocking ? [quitTitle, stopTitle, L("Cancel", "취소")] : [quitTitle, L("Cancel", "취소")]
        let choice = buttons[Dialogs.show(L("Quit distractorRemover?", "distractorRemover를 종료할까요?"),
                                          lines.joined(separator: "\n\n"), buttons: buttons)]
        if choice == quitTitle {
            NSApp.terminate(nil)
        } else if choice == stopTitle {
            let calendar = controller.calendar
            perform {
                let outcome = await self.controller.update(reason: "stop-and-quit") { config, now in
                    config.stoppingBlocking(at: now, calendar: calendar)
                }
                if outcome.succeeded { NSApp.terminate(nil) } else { self.report(outcome) }
            }
        }
    }

    func toggleLoginItem() {
        guard !environment.paths.isSandbox else {
            return Dialogs.info(L("Not in sandbox mode", "샌드박스 모드에서는 안 돼요"),
                                L("Open at Login only works for the installed app.", "로그인 시 열기는 설치된 앱에서만 동작해요."))
        }
        let enable = !LoginItem.isEnabled(environment.paths)
        do {
            if try LoginItem.setEnabled(enable, paths: environment.paths) {
                Dialogs.info(L("Approval needed", "승인이 필요해요"),
                             L("Allow distractorRemover in System Settings → General → Login Items.",
                               "시스템 설정 → 일반 → 로그인 항목에서 distractorRemover를 허용해 주세요."))
            }
        } catch {
            Dialogs.warn(L("Couldn’t change Open at Login", "로그인 시 열기를 바꾸지 못했어요"),
                         error.localizedDescription
                            + L("\n\nInstall the app in /Applications and run it from there.",
                                "\n\n앱을 /Applications에 설치하고 거기서 실행해 주세요."))
        }
    }
}

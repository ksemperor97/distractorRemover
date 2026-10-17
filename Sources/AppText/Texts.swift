import BlockerCore
import Foundation

/// Wording that depends on data: days, times, status and failures.
public struct Texts {
    public let language: Language
    public let calendar: Calendar

    public init(language: Language = Localizer.shared.language, calendar: Calendar = .current) {
        self.language = language
        self.calendar = calendar
    }

    private func t(_ english: String, _ korean: String) -> String {
        language == .korean ? korean : english
    }

    // MARK: Days and times

    /// Monday = 0 … Sunday = 6.
    public var dayNames: [String] {
        language == .korean
            ? ["월", "화", "수", "목", "금", "토", "일"]
            : ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    }

    public func days(_ days: [Int]) -> String {
        let sorted = Array(Set(days)).sorted()
        switch sorted {
        case [0, 1, 2, 3, 4]: return t("Mon–Fri", "평일")
        case [5, 6]: return t("Sat–Sun", "주말")
        case Array(0...6): return t("Every day", "매일")
        default: return sorted.map { dayNames[$0] }.joined(separator: ", ")
        }
    }

    /// The locale used for times and pickers: `9:00 AM` / `오전 9:00`.
    public var locale: Locale { Locale(identifier: language == .korean ? "ko_KR" : "en_US") }

    /// Minutes after midnight → `6:00 PM` / `오후 6:00`.
    public func time(minutes: Int) -> String {
        let hour = minutes / 60, minute = minutes % 60
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        let clock = String(format: "%d:%02d", hour12, minute)
        if language == .korean { return "\(hour < 12 ? "오전" : "오후") \(clock)" }
        return "\(clock) \(hour < 12 ? "AM" : "PM")"
    }

    public func window(_ window: ScheduleWindow) -> String {
        "\(days(window.days))  \(time(minutes: window.start))–\(time(minutes: window.end))"
    }

    /// `6:00 PM` today, otherwise `Tue 6:00 PM` / `화 오후 6:00`.
    public func moment(_ date: Date, now: Date) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let clock = time(minutes: (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
        if calendar.isDate(date, inSameDayAs: now) { return clock }
        return "\(dayNames[ScheduleMath.weekdayIndex(date, calendar: calendar)]) \(clock)"
    }

    // MARK: Menu names (also used inside messages that point to them)

    public var startBlocking: String { t("Start Blocking", "차단 시작") }
    public var stopBlocking: String { t("Stop Blocking…", "차단 해제…") }
    public func editSites(count: Int) -> String { t("Edit Blocked Sites… (\(count))", "차단 사이트 편집… (\(count))") }
    public var schedule: String { t("Schedule…", "스케줄…") }
    public var editHosts: String { t("Edit Hosts File…", "hosts 파일 편집…") }
    public var openAtLogin: String { t("Open at Login", "로그인 시 열기") }
    public var quit: String { t("Quit distractorRemover…", "distractorRemover 종료…") }

    // MARK: Status and failures

    public func status(_ summary: StatusSummary, now: Date) -> String {
        switch summary {
        case .settingsDamaged:
            return t("Settings file is damaged — see app.log", "설정 파일이 손상됨 — app.log 확인")
        case .hostsNeedFixing:
            return t("Hosts file needs fixing — click to edit", "hosts 파일 수정 필요 — 눌러서 편집")
        case .updateFailed:
            return t("Couldn’t update blocking — click to retry", "차단을 적용하지 못함 — 눌러서 다시 시도")
        case .blocking(let until?):
            return t("Blocking until \(moment(until, now: now)) (schedule)", "\(moment(until, now: now))까지 차단 중 (스케줄)")
        case .blocking(nil):
            return t("Blocking", "차단 중")
        case .notBlocking(let starts?):
            return t("Not blocking · schedule starts \(moment(starts, now: now))",
                     "차단 안 함 · 스케줄 시작 \(moment(starts, now: now))")
        case .notBlocking(nil):
            return t("Not blocking", "차단 안 함")
        }
    }

    public func parseError(_ error: Domains.ParseError) -> String {
        switch error.kind {
        case .invalidEntry:
            return t("Line \(error.line) isn’t one site: \(error.text)", "\(error.line)번째 줄은 사이트 하나가 아니에요: \(error.text)")
        case .invalidDomain:
            return t("Line \(error.line) isn’t a website address: \(error.text)", "\(error.line)번째 줄은 웹사이트 주소가 아니에요: \(error.text)")
        }
    }

    public func failure(_ failure: Failure) -> String {
        switch failure {
        case .helperUnavailable:
            return t("Scheduled blocking can’t update the hosts file without its helper. Open \(schedule) and save it to set the helper up again.",
                     "helper가 없어 스케줄 차단이 hosts 파일을 바꿀 수 없어요. \(schedule)을 열고 저장하면 helper를 다시 설치해요.")
        case .hostsMarkersDamaged:
            return t("The distractorRemover marker lines in the hosts file are missing, reversed or nested, so the file was left unchanged. Open \(editHosts) and delete every line from the START marker through the END marker.",
                     "hosts 파일의 distractorRemover 표시 줄이 빠졌거나 순서가 뒤바뀌었거나 겹쳐 있어서 파일을 건드리지 않았어요. \(editHosts)에서 START 줄부터 END 줄까지 지워 주세요.")
        case .hostsMismatch:
            return t("The hosts file didn’t show the requested state after the update.",
                     "적용한 뒤에도 hosts 파일이 요청한 상태와 달라요.")
        case .settingsNotSaved(let detail):
            return t("Couldn’t save your settings: \(detail)", "설정을 저장하지 못했어요: \(detail)")
        case .other(let detail):
            return detail
        }
    }
}

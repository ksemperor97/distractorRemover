import AppKit
import AppText
import BlockerCore

/// Non-modal schedule editor. Day toggles and time pickers mean the user can
/// only produce valid windows. Reports `nil` on cancel, else whether the
/// schedule is on and its windows.
@MainActor
final class ScheduleEditor: NSObject, NSWindowDelegate {
    private var windows: [ScheduleWindow]
    private var listWasEdited = false
    private var completion: (((Bool, [ScheduleWindow])?) -> Void)?
    private let calendar = Calendar.current

    private let window: NSWindow
    private let text = Texts()
    private let enabledBox = NSButton(checkboxWithTitle: L("Block sites during these times", "이 시간에 사이트 차단"),
                                      target: nil, action: nil)
    private let days = NSSegmentedControl()
    private let startPicker = NSDatePicker()
    private let endPicker = NSDatePicker()
    private let statusLabel = NSTextField(labelWithString: "")
    private let listStack = NSStackView()
    private let listDocument = FlippedView(frame: NSRect(x: 0, y: 0, width: 398, height: 130))
    private let listScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 404, height: 140))

    init(enabled: Bool, windows: [ScheduleWindow], completion: @escaping ((Bool, [ScheduleWindow])?) -> Void) {
        self.windows = windows
        enabledBox.state = enabled ? .on : .off
        self.completion = completion
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        super.init()
        build()
    }

    func show() {
        // A regular activation policy while open gives the window full keyboard focus.
        NSApp.setActivationPolicy(.regular)
        Dialogs.bringToFront()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Building

    private func build() {
        days.segmentCount = 7
        days.trackingMode = .selectAny
        for (index, name) in text.dayNames.enumerated() {
            days.setLabel(name, forSegment: index)
            days.setWidth(44, forSegment: index)
            days.setSelected(index < 5, forSegment: index)   // default Mon–Fri
        }

        let presetTitles = [L("Weekdays", "평일"), L("Weekends", "주말"), L("Every day", "매일"), L("Clear", "지우기")]
        let presets = NSStackView(views: presetTitles.enumerated().map { index, title in
            let button = small(NSButton(title: title, target: self, action: #selector(applyPreset(_:))))
            button.tag = index
            return button
        })
        presets.spacing = 6

        configure(startPicker, minutes: 9 * 60)
        configure(endPicker, minutes: 18 * 60)
        let addButton = small(NSButton(title: L("Add Window", "시간대 추가"), target: self, action: #selector(addWindow(_:))))
        let timeRow = NSStackView(views: [label(L("From", "시작")), startPicker, label(L("to", "끝")), endPicker, addButton])
        timeRow.spacing = 6

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .systemRed

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 6
        listDocument.addSubview(listStack)
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.borderType = .bezelBorder
        listScroll.documentView = listDocument
        listScroll.widthAnchor.constraint(equalToConstant: 404).isActive = true
        listScroll.heightAnchor.constraint(equalToConstant: 140).isActive = true

        let cancel = NSButton(title: L("Cancel", "취소"), target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: L("Save", "저장"), target: self, action: #selector(save(_:)))
        save.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottom = NSStackView(views: [spacer, cancel, save])
        bottom.spacing = 10

        let note = NSTextField(wrappingLabelWithString: L(
            "A window that ends before it starts runs overnight. Stop Blocking pauses only the current window; "
                + "the schedule starts again at the next one.",
            "끝이 시작보다 이르면 자정을 넘겨 이어져요. 차단 해제는 지금 진행 중인 시간대만 쉬게 하고, "
                + "다음 시간대부터 다시 차단해요."))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 404
        note.widthAnchor.constraint(equalToConstant: 404).isActive = true

        let root = NSStackView(views: [
            enabledBox,
            label(L("Pick days and times, click Add Window, then Save.", "요일과 시간을 고르고 시간대 추가를 누른 뒤 저장해요."),
                  size: 12, color: .secondaryLabelColor),
            days,
            presets,
            timeRow,
            statusLabel,
            note,
            label(L("Scheduled windows", "차단 시간대"), bold: true, size: 12),
            listScroll,
            bottom,
        ])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        bottom.widthAnchor.constraint(equalTo: listScroll.widthAnchor).isActive = true

        window.title = L("Schedule", "스케줄")
        window.contentView = root
        window.delegate = self
        window.isReleasedWhenClosed = false
        refreshList()
    }

    private func configure(_ picker: NSDatePicker, minutes: Int) {
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .hourMinute
        picker.datePickerMode = .single
        picker.isBezeled = true
        picker.locale = text.locale
        var parts = DateComponents()
        parts.year = 2000
        parts.month = 1
        parts.day = 1
        parts.hour = minutes / 60
        parts.minute = minutes % 60
        picker.dateValue = calendar.date(from: parts) ?? Date()
    }

    private func minutes(of picker: NSDatePicker) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: picker.dateValue)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private var selectedDays: [Int] { (0..<7).filter { days.isSelected(forSegment: $0) } }

    private func currentSelection() -> ScheduleWindow? {
        ScheduleWindow(days: selectedDays, start: minutes(of: startPicker), end: minutes(of: endPicker))
    }

    private func refreshList() {
        for view in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if windows.isEmpty {
            listStack.addArrangedSubview(label(L("(the selection above will be used)", "(위에서 고른 시간이 쓰여요)"),
                                               size: 12, color: .secondaryLabelColor))
        } else {
            for (index, item) in windows.enumerated() {
                let remove = small(NSButton(title: L("Remove", "삭제"), target: self, action: #selector(removeRow(_:))))
                remove.tag = index
                let row = NSStackView(views: [label(text.window(item)), remove])
                row.spacing = 12
                listStack.addArrangedSubview(row)
            }
        }
        let fit = listStack.fittingSize
        listDocument.frame = NSRect(x: 0, y: 0, width: 398, height: max(130, fit.height))
        listStack.frame = NSRect(x: 0, y: 0, width: 398, height: fit.height)
        listScroll.contentView.scroll(to: .zero)
        listScroll.reflectScrolledClipView(listScroll.contentView)
        if let content = window.contentView { window.setContentSize(content.fittingSize) }
    }

    // MARK: Actions

    @objc private func applyPreset(_ sender: NSButton) {
        let presets: [[Int]] = [[0, 1, 2, 3, 4], [5, 6], Array(0...6), []]
        let wanted = Set(presets[sender.tag])
        for index in 0..<7 { days.setSelected(wanted.contains(index), forSegment: index) }
    }

    @objc private func addWindow(_ sender: Any?) {
        guard let selection = currentSelection() else {
            statusLabel.stringValue = selectedDays.isEmpty
                ? L("Pick at least one day.", "요일을 하나 이상 골라 주세요.")
                : L("Start and end can’t be the same.", "시작과 끝이 같을 수 없어요.")
            NSSound.beep()
            return
        }
        guard !windows.contains(selection) else {
            statusLabel.stringValue = L("That time window is already in the list.", "이미 목록에 있는 시간대예요.")
            NSSound.beep()
            return
        }
        windows.append(selection)
        listWasEdited = true
        statusLabel.stringValue = ""
        refreshList()
    }

    @objc private func removeRow(_ sender: NSButton) {
        guard windows.indices.contains(sender.tag) else { return }
        windows.remove(at: sender.tag)
        listWasEdited = true
        refreshList()
    }

    @objc private func save(_ sender: Any?) {
        var result = windows
        if result.isEmpty && !listWasEdited, let selection = currentSelection() {
            result = [selection]   // new schedule: use the current selection
        }
        finish((enabledBox.state == .on && !result.isEmpty, result))
    }

    @objc private func cancel(_ sender: Any?) {
        finish(nil)
    }

    func windowWillClose(_ notification: Notification) {
        finish(nil)   // red close button == cancel
    }

    private func finish(_ result: (Bool, [ScheduleWindow])?) {
        guard let completion else { return }
        self.completion = nil
        window.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)   // back to menu-bar-only
        completion(result)
    }

    // MARK: View helpers

    private func label(_ text: String, bold: Bool = false, size: CGFloat = 13, color: NSColor? = nil) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        if let color { field.textColor = color }
        return field
    }

    private func small(_ button: NSButton) -> NSButton {
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        return button
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

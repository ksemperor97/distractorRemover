import AppKit
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
    private let enabledBox = NSButton(checkboxWithTitle: "Block sites during these times", target: nil, action: nil)
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
        for (index, name) in ScheduleMath.dayNames.enumerated() {
            days.setLabel(name, forSegment: index)
            days.setWidth(44, forSegment: index)
            days.setSelected(index < 5, forSegment: index)   // default Mon–Fri
        }

        let presets = NSStackView(views: ["Weekdays", "Weekends", "Every day", "Clear"].enumerated().map { index, title in
            let button = small(NSButton(title: title, target: self, action: #selector(applyPreset(_:))))
            button.tag = index
            return button
        })
        presets.spacing = 6

        configure(startPicker, minutes: 9 * 60)
        configure(endPicker, minutes: 18 * 60)
        let addButton = small(NSButton(title: "Add Window", target: self, action: #selector(addWindow(_:))))
        let timeRow = NSStackView(views: [label("From"), startPicker, label("to"), endPicker, addButton])
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

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(save(_:)))
        save.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottom = NSStackView(views: [spacer, cancel, save])
        bottom.spacing = 10

        let note = NSTextField(wrappingLabelWithString:
            "A window that ends before it starts runs overnight. Stop Blocking pauses only the current window; "
                + "the schedule starts again at the next one.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 404
        note.widthAnchor.constraint(equalToConstant: 404).isActive = true

        let root = NSStackView(views: [
            enabledBox,
            label("Pick days and times, click Add Window, then Save.", size: 12, color: .secondaryLabelColor),
            days,
            presets,
            timeRow,
            statusLabel,
            note,
            label("Scheduled windows", bold: true, size: 12),
            listScroll,
            bottom,
        ])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        bottom.widthAnchor.constraint(equalTo: listScroll.widthAnchor).isActive = true

        window.title = "Schedule"
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
            listStack.addArrangedSubview(label("(the selection above will be used)", size: 12, color: .secondaryLabelColor))
        } else {
            for (index, item) in windows.enumerated() {
                let remove = small(NSButton(title: "Remove", target: self, action: #selector(removeRow(_:))))
                remove.tag = index
                let row = NSStackView(views: [label(ScheduleMath.formatWindow(item)), remove])
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
            statusLabel.stringValue = selectedDays.isEmpty ? "Pick at least one day." : "Start and end can’t be the same."
            NSSound.beep()
            return
        }
        guard !windows.contains(selection) else {
            statusLabel.stringValue = "That time window is already in the list."
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

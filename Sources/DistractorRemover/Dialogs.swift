import AppKit

/// Thin wrappers around NSAlert. A menu-bar-only app must activate itself
/// first, or the alert opens behind the frontmost app without key focus.
@MainActor
enum Dialogs {
    static func bringToFront() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Returns the index of the clicked button (0 = first).
    @discardableResult
    static func show(
        _ title: String,
        _ message: String,
        buttons: [String] = ["OK"],
        destructiveIndex: Int? = nil,
        style: NSAlert.Style = .informational,
        accessory: NSView? = nil,
        firstResponder: NSView? = nil
    ) -> Int {
        bringToFront()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        for (index, label) in buttons.enumerated() {
            let button = alert.addButton(withTitle: label)
            if index == destructiveIndex { button.hasDestructiveAction = true }
        }
        if let accessory {
            alert.accessoryView = accessory
            alert.layout()
        }
        if let firstResponder { alert.window.initialFirstResponder = firstResponder }
        return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    static func info(_ title: String, _ message: String) {
        show(title, message)
    }

    static func warn(_ title: String, _ message: String) {
        show(title, message, style: .warning)
    }

    static func confirm(_ title: String, _ message: String, ok: String, cancel: String = "Cancel", destructive: Bool = false) -> Bool {
        show(title, message, buttons: [ok, cancel], destructiveIndex: destructive ? 0 : nil) == 0
    }

    static func prompt(_ title: String, _ message: String, placeholder: String, ok: String) -> String? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = placeholder
        let choice = show(title, message, buttons: [ok, "Cancel"], accessory: field, firstResponder: field)
        return choice == 0 ? field.stringValue : nil
    }

    /// Multi-line monospaced editor. Returns the edited text, or nil on cancel.
    static func editText(_ title: String, _ message: String, text: String, ok: String) -> String? {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 260))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let textView = NSTextView(frame: scroll.bounds)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.autoresizingMask = [.width]
        textView.string = text
        scroll.documentView = textView
        let choice = show(title, message, buttons: [ok, "Cancel"], accessory: scroll, firstResponder: textView)
        return choice == 0 ? textView.string : nil
    }
}

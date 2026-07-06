"""Native (AppKit) schedule editor for distractorRemover.

A normal (non-modal) window with day toggle buttons and time pickers, so the
user can only ever produce valid time windows. Non-modal on purpose: running a
nested modal loop from a status-bar menu callback is fragile, so instead we
show a regular window and report the result through a callback.

open_editor(existing, callback) -> editor object (the caller MUST keep a strong
reference to it until the callback fires). The callback is invoked on the main
thread with a list of {"days":[0-6], "start":"HH:MM", "end":"HH:MM"} windows,
or None if the user cancelled.
"""

import objc
from AppKit import (
    NSAlert, NSApplication, NSBackingStoreBuffered, NSBeep, NSButton, NSColor,
    NSControlSizeSmall, NSDatePicker, NSDatePickerElementFlagHourMinute,
    NSDatePickerModeSingle, NSDatePickerStyleTextFieldAndStepper, NSFont,
    NSLayoutAttributeLeading, NSSegmentedControl, NSSegmentSwitchTrackingSelectAny,
    NSStackView, NSTextField, NSUserInterfaceLayoutOrientationHorizontal,
    NSUserInterfaceLayoutOrientationVertical, NSView, NSWindow,
    NSWindowStyleMaskClosable, NSWindowStyleMaskTitled,
)
from Foundation import (
    NSCalendar, NSCalendarUnitHour, NSCalendarUnitMinute, NSDateComponents,
    NSMakeRect, NSObject,
)

DAY_ABBR = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
_PRESETS = {0: [0, 1, 2, 3, 4], 1: [5, 6], 2: [0, 1, 2, 3, 4, 5, 6], 3: []}


def _label(text, bold=False, size=13, color=None):
    tf = NSTextField.labelWithString_(text)
    tf.setFont_(NSFont.boldSystemFontOfSize_(size) if bold else NSFont.systemFontOfSize_(size))
    if color is not None:
        tf.setTextColor_(color)
    return tf


def _fmt_days(days):
    s = sorted(set(days))
    if s == [0, 1, 2, 3, 4]:
        return "Mon–Fri"
    if s == [5, 6]:
        return "Sat–Sun"
    if s == [0, 1, 2, 3, 4, 5, 6]:
        return "Every day"
    return ", ".join(DAY_ABBR[d] for d in s)


def _fmt_window(w):
    return f"{_fmt_days(w['days'])}   {w['start']} – {w['end']}"


class ScheduleEditor(NSObject):
    def initWithWindows_callback_(self, windows, callback):
        self = objc.super(ScheduleEditor, self).init()
        if self is None:
            return None
        self.windows = [dict(w) for w in (windows or [])]
        self._callback = callback
        self._done = False
        self._prev_policy = None
        self._cal = NSCalendar.currentCalendar()
        self.window = None
        self._build()
        return self

    # --- time <-> NSDate helpers ------------------------------------------

    @objc.python_method
    def _date(self, h, m):
        c = NSDateComponents.alloc().init()
        c.setYear_(2000)
        c.setMonth_(1)
        c.setDay_(1)
        c.setHour_(h)
        c.setMinute_(m)
        return self._cal.dateFromComponents_(c)

    @objc.python_method
    def _hm(self, picker):
        comps = self._cal.components_fromDate_(
            NSCalendarUnitHour | NSCalendarUnitMinute, picker.dateValue()
        )
        return comps.hour(), comps.minute()

    @objc.python_method
    def _picker(self, h, m):
        dp = NSDatePicker.alloc().initWithFrame_(NSMakeRect(0, 0, 84, 24))
        dp.setDatePickerStyle_(NSDatePickerStyleTextFieldAndStepper)
        dp.setDatePickerElements_(NSDatePickerElementFlagHourMinute)
        dp.setDatePickerMode_(NSDatePickerModeSingle)
        dp.setBezeled_(True)
        dp.setDateValue_(self._date(h, m))
        return dp

    @objc.python_method
    def _small(self, button):
        button.setControlSize_(NSControlSizeSmall)
        button.setFont_(NSFont.systemFontOfSize_(11))
        return button

    @objc.python_method
    def _current_window(self):
        """A valid window dict from the current day/time selection, or None."""
        days = [i for i in range(7) if self.seg.isSelectedForSegment_(i)]
        if not days:
            return None
        sh, sm = self._hm(self.startP)
        eh, em = self._hm(self.endP)
        start, end = "%02d:%02d" % (sh, sm), "%02d:%02d" % (eh, em)
        if start == end:
            return None
        return {"days": days, "start": start, "end": end}

    # --- build UI ----------------------------------------------------------

    @objc.python_method
    def _build(self):
        seg = NSSegmentedControl.alloc().initWithFrame_(NSMakeRect(0, 0, 322, 24))
        seg.setSegmentCount_(7)
        seg.setTrackingMode_(NSSegmentSwitchTrackingSelectAny)
        for i, lab in enumerate(DAY_ABBR):
            seg.setLabel_forSegment_(lab, i)
            seg.setWidth_forSegment_(44, i)
            seg.setSelected_forSegment_(i < 5, i)   # default Mon–Fri
        self.seg = seg

        presets = NSStackView.stackViewWithViews_([
            self._small(NSButton.buttonWithTitle_target_action_(t, self, "applyPreset:"))
            for t in ("Weekdays", "Weekends", "Every day", "Clear")
        ])
        for i, b in enumerate(presets.arrangedSubviews()):
            b.setTag_(i)
        presets.setSpacing_(6)

        self.startP = self._picker(9, 0)
        self.endP = self._picker(18, 0)
        add_btn = self._small(
            NSButton.buttonWithTitle_target_action_("＋ Add another", self, "addWindow:"))
        time_row = NSStackView.stackViewWithViews_([
            _label("From"), self.startP, _label("to"), self.endP, add_btn
        ])
        time_row.setSpacing_(6)

        self.status = _label("", size=11, color=NSColor.systemRedColor())

        self.listStack = NSStackView.alloc().init()
        self.listStack.setOrientation_(NSUserInterfaceLayoutOrientationVertical)
        self.listStack.setAlignment_(NSLayoutAttributeLeading)
        self.listStack.setSpacing_(6)

        cancel = NSButton.buttonWithTitle_target_action_("Cancel", self, "cancel:")
        cancel.setKeyEquivalent_("\x1b")                # Esc
        save = NSButton.buttonWithTitle_target_action_("Save", self, "save:")
        save.setKeyEquivalent_("\r")                    # Return → default button
        spacer = NSView.alloc().init()
        spacer.setContentHuggingPriority_forOrientation_(1, NSUserInterfaceLayoutOrientationHorizontal)
        bottom = NSStackView.stackViewWithViews_([spacer, cancel, save])
        bottom.setSpacing_(10)

        root = NSStackView.stackViewWithViews_([
            _label("Block distracting sites on a schedule", bold=True, size=14),
            _label("Pick the days and a time range, then click Save.",
                   size=12, color=NSColor.secondaryLabelColor()),
            seg,
            presets,
            time_row,
            self.status,
            _label("Scheduled windows", bold=True, size=12),
            self.listStack,
            bottom,
        ])
        root.setOrientation_(NSUserInterfaceLayoutOrientationVertical)
        root.setAlignment_(NSLayoutAttributeLeading)
        root.setSpacing_(10)
        root.setEdgeInsets_((18.0, 18.0, 18.0, 18.0))

        style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        win = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(0, 0, 440, 420), style, NSBackingStoreBuffered, False
        )
        win.setTitle_("Blocking Schedule")
        win.setContentView_(root)
        win.setDelegate_(self)
        win.setReleasedWhenClosed_(False)
        self.window = win
        self._refresh_list()

    @objc.python_method
    def _refresh_list(self):
        for v in list(self.listStack.arrangedSubviews()):
            self.listStack.removeArrangedSubview_(v)
            v.removeFromSuperview()
        if not self.windows:
            self.listStack.addArrangedSubview_(
                _label("(the selection above will be used)", size=12,
                       color=NSColor.secondaryLabelColor()))
        else:
            for i, w in enumerate(self.windows):
                rm = self._small(
                    NSButton.buttonWithTitle_target_action_("Remove", self, "removeRow:"))
                rm.setTag_(i)
                row = NSStackView.stackViewWithViews_([_label(_fmt_window(w)), rm])
                row.setSpacing_(12)
                self.listStack.addArrangedSubview_(row)
        if self.window is not None:
            self.window.setContentSize_(self.window.contentView().fittingSize())

    # --- lifecycle ---------------------------------------------------------

    @objc.python_method
    def show(self):
        app = NSApplication.sharedApplication()
        if self._prev_policy is None:
            self._prev_policy = app.activationPolicy()
        app.setActivationPolicy_(0)                     # regular: full keyboard focus
        app.activateIgnoringOtherApps_(True)
        self.window.center()
        self.window.makeKeyAndOrderFront_(None)

    @objc.python_method
    def _finish(self, result):
        if self._done:
            return
        self._done = True
        if self.window is not None:
            self.window.orderOut_(None)
        app = NSApplication.sharedApplication()
        if self._prev_policy is not None:
            app.setActivationPolicy_(self._prev_policy)  # back to menu-bar-only
        cb, self._callback = self._callback, None
        if cb is not None:
            cb(result)

    @objc.python_method
    def _confirm_clear(self):
        a = NSAlert.alloc().init()
        a.setMessageText_("No time windows")
        a.setInformativeText_("Turn the schedule off (no automatic blocking)?")
        a.addButtonWithTitle_("Turn off schedule")
        a.addButtonWithTitle_("Keep editing")
        return a.runModal() == 1000                      # NSAlertFirstButtonReturn

    # --- actions -----------------------------------------------------------

    def applyPreset_(self, sender):
        want = set(_PRESETS.get(sender.tag(), []))
        for i in range(7):
            self.seg.setSelected_forSegment_(i in want, i)

    def addWindow_(self, sender):
        cur = self._current_window()
        if cur is None:
            days = [i for i in range(7) if self.seg.isSelectedForSegment_(i)]
            self.status.setStringValue_(
                "Pick at least one day." if not days else "Start and end can’t be the same.")
            NSBeep()
            return
        self.windows.append(cur)
        self.status.setStringValue_("")
        self._refresh_list()

    def removeRow_(self, sender):
        i = sender.tag()
        if 0 <= i < len(self.windows):
            del self.windows[i]
            self._refresh_list()

    def save_(self, sender):
        windows = list(self.windows)
        if not windows:                       # nothing added → use current selection
            cur = self._current_window()
            if cur is not None:
                windows = [cur]
        if not windows:
            if self._confirm_clear():
                self._finish([])
            else:
                self.status.setStringValue_("Pick days and a time, then Save.")
            return
        self._finish(windows)

    def cancel_(self, sender):
        self._finish(None)

    def windowWillClose_(self, note):
        self._finish(None)                    # red close button == cancel


def open_editor(existing, callback):
    editor = ScheduleEditor.alloc().initWithWindows_callback_(existing or [], callback)
    editor.show()
    return editor

#!/usr/bin/env python3
"""distractorRemover — a macOS menu bar app to block distracting websites.

Blocks sites by managing a marked section of /etc/hosts. Two ways to apply:

  * If "password-free mode" is enabled, a small root-owned helper (installed
    once, guarded by a NOPASSWD sudoers rule) does the write silently. This is
    what lets the time-of-day schedule flip blocking on/off unattended.
  * Otherwise each change uses a native admin prompt (password / Touch ID).
"""

import getpass
import json
import os
import re
import shlex
import subprocess
from datetime import datetime

import rumps

APP_NAME = "distractorRemover"
APP_DIR = os.path.dirname(os.path.abspath(__file__))
SUPPORT_DIR = os.path.expanduser("~/Library/Application Support/distractorRemover")
CONFIG_PATH = os.path.join(SUPPORT_DIR, "config.json")
STAGED_PATH = os.path.join(SUPPORT_DIR, "hosts.staged")
HOSTS_PATH = "/etc/hosts"

HELPER_PATH = "/usr/local/bin/distractorremover-helper"
INSTALL_HELPER_SH = os.path.join(APP_DIR, "install_helper.sh")
UNINSTALL_HELPER_SH = os.path.join(APP_DIR, "uninstall_helper.sh")

MARK_START = "# === distractorRemover START (managed automatically — do not edit) ==="
MARK_END = "# === distractorRemover END ==="

ICON_ON = "🛡️"
ICON_OFF = "⚪"

DOMAIN_RE = re.compile(r"^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$")
DAY_ABBR = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
DAY_LOOKUP = {name.lower(): i for i, name in enumerate(DAY_ABBR)}
TIME_RE = re.compile(r"^(\d{1,2}):(\d{2})$")


# ===========================================================================
# Pure helpers — no GUI / no side effects, easy to unit test.
# ===========================================================================

def normalize_domain(raw):
    """'https://www.YouTube.com/feed' -> 'youtube.com'; '' if not a domain."""
    if not raw:
        return ""
    d = raw.strip().lower()
    d = re.sub(r"^[a-z][a-z0-9+.-]*://", "", d)   # scheme
    d = d.split("/")[0]                            # path
    d = d.split("?")[0].split("#")[0]              # query / fragment
    d = d.split("@")[-1]                            # user@
    d = d.split(":")[0]                            # :port
    if d.startswith("www."):
        d = d[4:]
    d = d.strip(".")
    return d if DOMAIN_RE.match(d) else ""


def build_block_text(sites):
    lines = [MARK_START]
    for d in sites:
        for host in (d, f"www.{d}"):
            lines.append(f"127.0.0.1\t{host}")
            lines.append(f"::1\t{host}")
    lines.append(MARK_END)
    return "\n".join(lines)


def strip_marked(content):
    pattern = re.compile(
        re.escape(MARK_START) + r".*?" + re.escape(MARK_END) + r"\n?", re.DOTALL
    )
    return pattern.sub("", content)


def render_hosts(current, cfg):
    new = strip_marked(current).rstrip("\n") + "\n"
    if cfg.get("blocking") and cfg.get("sites"):
        new += build_block_text(cfg["sites"]) + "\n"
    return new


# --- schedule parsing / formatting -----------------------------------------

def _parse_time(s):
    m = TIME_RE.match(s.strip())
    if not m:
        raise ValueError(f"“{s}” isn't a time — use HH:MM (24-hour).")
    h, mi = int(m.group(1)), int(m.group(2))
    if h > 23 or mi > 59:
        raise ValueError(f"“{s}” isn't a valid time.")
    return f"{h:02d}:{mi:02d}"


def _day_index(tok):
    return DAY_LOOKUP.get(tok.strip().lower()[:3])


def _parse_day_token(tok):
    t = tok.strip().lower()
    if t in ("daily", "everyday", "every", "all", "allday"):
        return list(range(7))
    if t in ("weekday", "weekdays", "wd"):
        return [0, 1, 2, 3, 4]
    if t in ("weekend", "weekends", "we"):
        return [5, 6]
    if "-" in t:
        a, b = t.split("-", 1)
        ai, bi = _day_index(a), _day_index(b)
        if ai is None or bi is None:
            raise ValueError(f"Unknown day in “{tok}”.")
        return list(range(ai, bi + 1)) if ai <= bi else list(range(ai, 7)) + list(range(bi + 1))
    i = _day_index(t)
    if i is None:
        raise ValueError(f"Unknown day “{tok}”.")
    return [i]


def _parse_day_spec(spec):
    days = set()
    for tok in spec.split(","):
        if tok.strip():
            days.update(_parse_day_token(tok))
    if not days:
        raise ValueError("No days given.")
    return sorted(days)


def parse_schedule(text):
    """Parse windows separated by newlines or ';'. Each: '<days> HH:MM-HH:MM'."""
    windows = []
    for raw in re.split(r"[;\n]+", text):
        line = raw.strip()
        if not line:
            continue
        toks = line.split()
        time_tok = toks[-1]
        if "-" not in time_tok or ":" not in time_tok:
            raise ValueError(f"Missing a time range in “{line}” (e.g. 09:00-18:00).")
        day_spec = " ".join(toks[:-1]).strip()
        if not day_spec:
            raise ValueError(f"Missing days in “{line}”.")
        start_s, end_s = time_tok.split("-", 1)
        start, end = _parse_time(start_s), _parse_time(end_s)
        if start == end:
            raise ValueError(f"Start and end are the same in “{line}”.")
        windows.append({"days": _parse_day_spec(day_spec), "start": start, "end": end})
    return windows


def fmt_days(days):
    s = sorted(set(days))
    if s == [0, 1, 2, 3, 4]:
        return "Mon-Fri"
    if s == [5, 6]:
        return "Sat-Sun"
    if s == [0, 1, 2, 3, 4, 5, 6]:
        return "Daily"
    return ",".join(DAY_ABBR[d] for d in s)


def fmt_window(w):
    return f"{fmt_days(w['days'])} {w['start']}-{w['end']}"


def format_schedule(windows):
    return " ; ".join(fmt_window(w) for w in windows)


def _to_min(hhmm):
    h, m = hhmm.split(":")
    return int(h) * 60 + int(m)


def in_window(dt, windows):
    """True if the datetime falls in any window (handles overnight windows)."""
    wd = dt.weekday()
    cur = dt.hour * 60 + dt.minute
    for w in windows:
        s, e, days = _to_min(w["start"]), _to_min(w["end"]), w["days"]
        if s < e:
            if wd in days and s <= cur < e:
                return True
        else:  # overnight, e.g. 22:00-06:00
            if wd in days and cur >= s:
                return True
            if ((wd - 1) % 7) in days and cur < e:
                return True
    return False


# ===========================================================================
# Config persistence
# ===========================================================================

def _clean_schedule(sch):
    windows = []
    for w in (sch.get("windows") if isinstance(sch, dict) else []) or []:
        try:
            days = sorted({int(d) for d in w["days"] if 0 <= int(d) <= 6})
            start, end = _parse_time(w["start"]), _parse_time(w["end"])
            if days and start != end:
                windows.append({"days": days, "start": start, "end": end})
        except (KeyError, ValueError, TypeError):
            continue
    enabled = bool(sch.get("enabled", False)) if isinstance(sch, dict) else False
    return {"enabled": enabled and bool(windows), "windows": windows}


def load_config():
    try:
        with open(CONFIG_PATH) as f:
            cfg = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        cfg = {}
    seen, sites = set(), []
    for s in cfg.get("sites") or []:
        d = normalize_domain(s) if isinstance(s, str) else ""
        if d and d not in seen:
            seen.add(d)
            sites.append(d)
    return {
        "sites": sites,
        "blocking": bool(cfg.get("blocking", False)),
        "schedule": _clean_schedule(cfg.get("schedule")),
    }


def save_config(cfg):
    os.makedirs(SUPPORT_DIR, exist_ok=True)
    tmp = CONFIG_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(
            {"sites": cfg["sites"], "blocking": cfg["blocking"], "schedule": cfg["schedule"]},
            f, indent=2,
        )
    os.replace(tmp, CONFIG_PATH)


# ===========================================================================
# Applying to /etc/hosts (silent helper, or admin prompt)
# ===========================================================================

def helper_installed():
    return os.path.exists(HELPER_PATH)


def _osa_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def run_privileged_script(script_path, *args):
    """Run a bash script as root via one native admin prompt."""
    cmd = " ".join(shlex.quote(p) for p in ["/bin/bash", script_path, *args])
    osa = "do shell script " + _osa_str(cmd) + " with administrator privileges"
    return subprocess.run(["/usr/bin/osascript", "-e", osa], capture_output=True, text=True)


def apply_hosts(cfg):
    """Make /etc/hosts match cfg. Silent via helper if available, else prompts.

    Raises PermissionError if the user cancels a prompt, RuntimeError otherwise.
    """
    with open(HOSTS_PATH) as f:
        current = f.read()
    desired = render_hosts(current, cfg)
    if desired == current:
        return

    os.makedirs(SUPPORT_DIR, exist_ok=True)
    with open(STAGED_PATH, "w") as f:
        f.write(desired)
    try:
        if helper_installed():
            r = subprocess.run(
                ["/usr/bin/sudo", "-n", HELPER_PATH, STAGED_PATH],
                capture_output=True, text=True,
            )
            if r.returncode == 0:
                return
            err = (r.stderr or "").lower()
            if not ("password is required" in err or "a terminal is required" in err):
                raise RuntimeError((r.stderr or "").strip() or "helper failed")
            # NOPASSWD not effective — fall through to prompt.

        shell_cmd = (
            f"cp {shlex.quote(STAGED_PATH)} {shlex.quote(HOSTS_PATH)} && "
            "{ dscacheutil -flushcache || true; killall -HUP mDNSResponder || true; }"
        )
        osa = "do shell script " + _osa_str(shell_cmd) + " with administrator privileges"
        r = subprocess.run(["/usr/bin/osascript", "-e", osa], capture_output=True, text=True)
        if r.returncode != 0:
            err = (r.stderr or "").strip()
            if "-128" in err or "cancel" in err.lower():
                raise PermissionError("cancelled")
            raise RuntimeError(err or "Failed to update the hosts file.")
    finally:
        try:
            os.remove(STAGED_PATH)
        except OSError:
            pass


def _activate_app():
    try:
        from AppKit import NSApp
        NSApp.activateIgnoringOtherApps_(True)
    except Exception:
        pass


# ===========================================================================
# Menu bar app
# ===========================================================================

class DistractorRemover(rumps.App):
    def __init__(self):
        super().__init__(APP_NAME, title=ICON_OFF, quit_button=None)
        self.cfg = load_config()
        self._last_desired = None
        self._sched_editor = None
        self.rebuild()

    # --- state helpers -----------------------------------------------------

    def _active(self):
        return bool(self.cfg["blocking"] and self.cfg["sites"])

    def update_icon(self):
        self.title = ICON_ON if self._active() else ICON_OFF

    def _commit(self, revert):
        try:
            apply_hosts(self.cfg)
        except PermissionError:
            revert()
            return False
        except Exception as e:
            revert()
            rumps.alert("Couldn't update blocking", str(e))
            return False
        save_config(self.cfg)
        self.rebuild()
        return True

    # --- menu --------------------------------------------------------------

    def rebuild(self):
        self.menu.clear()
        n = len(self.cfg["sites"])

        toggle_title = ("🛡️  Blocking is ON  —  click to UNBLOCK all" if self._active()
                        else "⚪  Blocking is OFF  —  click to BLOCK all")

        header = rumps.MenuItem(f"Blocked sites ({n})")
        header.set_callback(None)

        site_items = []
        if n == 0:
            empty = rumps.MenuItem("    (none yet — add one above)")
            empty.set_callback(None)
            site_items.append(empty)
        elif self._active():
            # Blocking is ON: sites are locked — you can add, but not remove.
            for d in self.cfg["sites"]:
                site_items.append(rumps.MenuItem(f"    🔒 {d}", callback=self.locked_remove))
        else:
            for d in self.cfg["sites"]:
                site_items.append(rumps.MenuItem(f"    {d}      ✕", callback=self._remover(d)))

        structure = [
            rumps.MenuItem(toggle_title, callback=self.toggle_blocking),
            rumps.separator,
            rumps.MenuItem("➕  Add site…", callback=self.add_site),
            rumps.separator,
            header,
            *site_items,
            rumps.separator,
            ("⏰  Schedule", self._schedule_items()),
            rumps.separator,
            rumps.MenuItem("Quit distractorRemover", callback=lambda _: rumps.quit_application()),
        ]
        self.menu.update(structure)
        self.update_icon()

    def _schedule_items(self):
        sch = self.cfg["schedule"]
        items = []

        toggle = rumps.MenuItem(
            "Scheduling is ON — click to turn OFF" if sch["enabled"]
            else "Scheduling is OFF — click to turn ON",
            callback=self.toggle_schedule,
        )
        toggle.state = 1 if sch["enabled"] else 0
        items.append(toggle)
        items.append(rumps.separator)

        if sch["windows"]:
            head = rumps.MenuItem("Blocked during:")
        else:
            head = rumps.MenuItem("No time windows set")
        head.set_callback(None)
        items.append(head)
        for w in sch["windows"]:
            it = rumps.MenuItem("    " + fmt_window(w))
            it.set_callback(None)
            items.append(it)
        items.append(rumps.MenuItem("Edit time windows…", callback=self.edit_schedule))

        items.append(rumps.separator)
        if helper_installed():
            pf = rumps.MenuItem("Password-free mode is ON — click to turn OFF",
                                callback=self.toggle_pwfree)
            pf.state = 1
        else:
            pf = rumps.MenuItem("Enable password-free mode…", callback=self.toggle_pwfree)
        items.append(pf)
        return items

    def _remover(self, domain):
        return lambda _: self.remove_site(domain)

    # --- site actions ------------------------------------------------------

    def toggle_blocking(self, _):
        want = not self.cfg["blocking"]
        if want and not self.cfg["sites"]:
            rumps.alert("No sites yet", "Add a site to block first.")
            return
        if not want and self._active():          # unblocking while active → confirm
            if rumps.alert("Unblock all sites?",
                           "This stops blocking every site in your list.",
                           ok="Unblock", cancel="Keep blocking") != 1:
                return
        self.cfg["blocking"] = want
        self._commit(revert=lambda: self.cfg.update(blocking=not want))

    def locked_remove(self, _):
        rumps.alert(
            "Locked while blocking",
            "You can’t remove a site while blocking is on — you can only add.\n"
            "Use “Unblock all” first, then remove it.",
        )

    def add_site(self, _):
        _activate_app()
        resp = rumps.Window(
            title="Add a site to block",
            message="Enter a website (e.g. youtube.com or instagram.com):",
            default_text="", ok="Add", cancel="Cancel", dimensions=(300, 22),
        ).run()
        if not resp.clicked:
            return
        domain = normalize_domain(resp.text)
        if not domain:
            rumps.alert("Hmm", f"“{resp.text.strip()}” doesn't look like a website address. "
                               f"Try something like youtube.com.")
            return
        if domain in self.cfg["sites"]:
            rumps.alert("Already added", f"{domain} is already in your list.")
            return
        self.cfg["sites"].append(domain)
        if self.cfg["blocking"]:
            self._commit(revert=lambda: self.cfg["sites"].remove(domain))
        else:
            save_config(self.cfg)
            self.rebuild()

    def remove_site(self, domain):
        if domain not in self.cfg["sites"]:
            return
        if rumps.alert(f"Remove {domain}?", "It will no longer be blocked.",
                       ok="Remove", cancel="Cancel") != 1:
            return
        idx = self.cfg["sites"].index(domain)
        self.cfg["sites"].remove(domain)
        if self.cfg["blocking"]:
            self._commit(revert=lambda: self.cfg["sites"].insert(idx, domain))
        else:
            save_config(self.cfg)
            self.rebuild()

    # --- schedule actions --------------------------------------------------

    def toggle_schedule(self, _):
        sch = self.cfg["schedule"]
        if sch["enabled"]:
            sch["enabled"] = False
            save_config(self.cfg)
            self.rebuild()
            return
        if not sch["windows"]:
            rumps.alert("Set a time window first",
                        "Open “Edit time windows…” and add at least one, "
                        "e.g. Mon-Fri 09:00-18:00.")
            return
        if not helper_installed():
            if rumps.alert(
                "Enable password-free mode?",
                "A schedule turns blocking on and off by itself, so it needs to update the "
                "hosts file without asking for your password each time.\n\n"
                "Install the one-time helper now? (You'll be asked for your password once. "
                "It only allows editing your hosts file.)",
                ok="Enable", cancel="Cancel",
            ) != 1:
                return
            if not self._do_install_helper():
                return
        sch["enabled"] = True
        self._last_desired = None
        save_config(self.cfg)
        self._enforce_schedule(force=True)
        self.rebuild()

    def edit_schedule(self, _):
        if self._sched_editor is not None:      # already open → just bring it forward
            self._sched_editor.show()
            return
        try:
            import schedule_editor
        except Exception as e:
            rumps.alert("Schedule editor error", str(e))
            return

        def done(windows):
            self._sched_editor = None
            if windows is None:
                return                          # cancelled — leave everything as-is
            self.cfg["schedule"]["windows"] = windows
            if not windows:
                self.cfg["schedule"]["enabled"] = False
            self._last_desired = None
            save_config(self.cfg)
            self.rebuild()
            if windows and not self.cfg["schedule"]["enabled"]:
                if rumps.alert("Schedule saved", "Turn on scheduled blocking now?",
                               ok="Turn on", cancel="Not now") == 1:
                    self.toggle_schedule(None)  # handles password-free setup + enforce
            elif self.cfg["schedule"]["enabled"]:
                self._enforce_schedule(force=True)

        try:
            self._sched_editor = schedule_editor.open_editor(
                self.cfg["schedule"]["windows"], done)
        except Exception as e:
            self._sched_editor = None
            rumps.alert("Schedule editor error", str(e))

    def toggle_pwfree(self, _):
        if helper_installed():
            if rumps.alert(
                "Turn off password-free mode?",
                "Scheduled auto on/off will stop, and manual changes will ask for your "
                "password again.",
                ok="Turn off", cancel="Cancel",
            ) != 1:
                return
            r = run_privileged_script(UNINSTALL_HELPER_SH)
            if r.returncode != 0 and "-128" not in (r.stderr or ""):
                rumps.alert("Failed", (r.stderr or "").strip() or "Could not remove helper.")
                return
            if self.cfg["schedule"]["enabled"]:
                self.cfg["schedule"]["enabled"] = False  # can't run silently anymore
                save_config(self.cfg)
            self.rebuild()
        else:
            if rumps.alert(
                "Enable password-free mode?",
                "This installs a small helper (one-time password) so distractorRemover can "
                "block/unblock — including on a schedule — without asking for your password "
                "each time.\n\nIt only allows editing your hosts file.",
                ok="Enable", cancel="Cancel",
            ) != 1:
                return
            if self._do_install_helper():
                self.rebuild()

    def _do_install_helper(self):
        r = run_privileged_script(INSTALL_HELPER_SH, getpass.getuser())
        if r.returncode == 0 and helper_installed():
            return True
        err = (r.stderr or r.stdout or "").strip()
        if "-128" in err or "cancel" in err.lower():
            return False  # user cancelled
        rumps.alert("Couldn't enable password-free mode", err or "Unknown error.")
        return False

    def _enforce_schedule(self, force=False):
        sch = self.cfg["schedule"]
        if not sch["enabled"] or not sch["windows"]:
            return
        if not helper_installed():
            return  # scheduler only acts silently
        desired = in_window(datetime.now(), sch["windows"])
        if not force and desired == self._last_desired:
            return
        self._last_desired = desired
        if desired == self.cfg["blocking"]:
            return
        self.cfg["blocking"] = desired
        try:
            apply_hosts(self.cfg)
        except Exception:
            self.cfg["blocking"] = not desired
            return
        save_config(self.cfg)
        self.rebuild()

    # --- lifecycle ---------------------------------------------------------

    @rumps.timer(30)
    def _schedule_tick(self, _):
        self._enforce_schedule()

    @rumps.timer(0.3)
    def _on_startup(self, sender):
        sender.stop()  # run once
        try:
            from AppKit import NSApp
            NSApp.setActivationPolicy_(1)  # accessory: menu-bar-only, no dock icon
        except Exception:
            pass
        self._enforce_schedule(force=True)


if __name__ == "__main__":
    DistractorRemover().run()

#!/usr/bin/env python3
"""distractorRemover — a macOS menu bar app to block distracting websites.

Blocks sites by managing a marked section of /etc/hosts. Two ways to apply:

  * If "password-free mode" is enabled, a small root-owned helper (installed
    once, guarded by a NOPASSWD sudoers rule) does the write silently. This is
    what lets the time-of-day schedule flip blocking on/off unattended.
  * Otherwise each change uses a native admin prompt (password / Touch ID).
"""

import getpass
import fcntl
import json
import logging
import os
import re
import shlex
import stat
import subprocess
import sys
import time
from datetime import datetime, timedelta
from logging.handlers import RotatingFileHandler

import rumps

APP_NAME = "distractorRemover"
# PyInstaller extracts bundled data into ``sys._MEIPASS``.  Keeping this in one
# place lets the source version and the packaged .app find the same helpers.
APP_DIR = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
try:
    with open(os.path.join(APP_DIR, "VERSION")) as _version_file:
        APP_VERSION = _version_file.read().strip()
except OSError:
    APP_VERSION = "development"
SUPPORT_DIR = os.path.expanduser("~/Library/Application Support/distractorRemover")
CONFIG_PATH = os.path.join(SUPPORT_DIR, "config.json")
STAGED_PATH = os.path.join(SUPPORT_DIR, "hosts.staged")
LOG_PATH = os.path.join(SUPPORT_DIR, "app.log")
STATE_PATH = os.path.join(SUPPORT_DIR, "runtime-state.json")
HOSTS_BACKUP_DIR = os.path.join(SUPPORT_DIR, "hosts-backups")
LOCK_PATH = os.path.join(SUPPORT_DIR, "instance.lock")
HOSTS_PATH = "/etc/hosts"
CONFIG_SCHEMA_VERSION = 2
HELPER_VERSION = "3"
SUPPORTED_HELPER_VERSIONS = {"2", HELPER_VERSION}

HELPER_PATH = "/usr/local/bin/distractorremover-helper"
INSTALL_HELPER_SH = os.path.join(APP_DIR, "install_helper.sh")
UNINSTALL_HELPER_SH = os.path.join(APP_DIR, "uninstall_helper.sh")
PRIVILEGED_HELPER_SH = os.path.join(APP_DIR, "privileged_helper.sh")

MARK_START = "# === distractorRemover START (managed automatically — do not edit) ==="
MARK_END = "# === distractorRemover END ==="

ICON_ON = "🛡️"
ICON_OFF = "⚪"
ICON_ERROR = "⚠️"

DOMAIN_RE = re.compile(
    r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+"
    r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"
)
DAY_ABBR = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
DAY_LOOKUP = {name.lower(): i for i, name in enumerate(DAY_ABBR)}
TIME_RE = re.compile(r"^(\d{1,2}):(\d{2})$")
RETRY_DELAYS = (5, 15, 30)

# Hosts files cannot express wildcards.  These deliberately small presets cover
# alternate entry points without blocking broad CDNs shared by other services.
SERVICE_PRESETS = {
    "youtube.com": {
        "label": "YouTube",
        "domains": (
            "youtube.com", "www.youtube.com", "m.youtube.com",
            "music.youtube.com", "studio.youtube.com", "youtu.be",
        ),
    },
    "instagram.com": {
        "label": "Instagram",
        "domains": ("instagram.com", "www.instagram.com", "m.instagram.com"),
    },
    "x.com": {
        "label": "X / Twitter",
        "domains": (
            "x.com", "www.x.com", "mobile.x.com", "twitter.com",
            "www.twitter.com", "mobile.twitter.com",
        ),
    },
    "reddit.com": {
        "label": "Reddit",
        "domains": (
            "reddit.com", "www.reddit.com", "old.reddit.com",
            "new.reddit.com", "np.reddit.com", "redd.it",
        ),
    },
    "tiktok.com": {
        "label": "TikTok",
        "domains": ("tiktok.com", "www.tiktok.com", "m.tiktok.com"),
    },
    "facebook.com": {
        "label": "Facebook",
        "domains": ("facebook.com", "www.facebook.com", "m.facebook.com"),
    },
}
PRESET_ALIASES = {
    domain: canonical
    for canonical, preset in SERVICE_PRESETS.items()
    for domain in preset["domains"]
}

logger = logging.getLogger(APP_NAME)
_instance_lock_file = None


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
    try:
        d = d.encode("idna").decode("ascii")
    except UnicodeError:
        return ""
    return d if DOMAIN_RE.match(d) else ""


def parse_site_list_text(text):
    """Parse one-domain-per-line text or managed lines copied from hosts."""
    seen, sites = set(), []
    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        tokens = line.split()
        if tokens[0] in ("127.0.0.1", "::1"):
            candidates = tokens[1:]
        elif len(tokens) == 1:
            candidates = tokens
        else:
            candidates = []
        if not candidates:
            raise ValueError(
                f"Invalid entry on line {line_number}: {raw_line.strip() or '(empty)'}"
            )
        for candidate in candidates:
            domain = normalize_domain(candidate)
            if not domain:
                raise ValueError(
                    f"Invalid domain on line {line_number}: {candidate}"
                )
            canonical = canonical_site(domain)
            if canonical not in seen:
                seen.add(canonical)
                sites.append(canonical)
    return sites


def canonical_site(domain):
    return PRESET_ALIASES.get(domain, domain)


def expanded_block_domains(sites):
    """Return the exact hosts represented by user-visible site entries."""
    seen, domains = set(), []
    for raw in sites:
        site = canonical_site(raw)
        preset = SERVICE_PRESETS.get(site)
        candidates = preset["domains"] if preset else (site, f"www.{site}")
        for domain in candidates:
            if domain not in seen:
                seen.add(domain)
                domains.append(domain)
    return domains


def site_display_name(site):
    preset = SERVICE_PRESETS.get(site)
    if not preset:
        return site
    return f"{preset['label']} — {site} ({len(preset['domains'])} domains)"


def build_block_text(domains):
    lines = [MARK_START]
    for host in domains:
        lines.append(f"127.0.0.1\t{host}")
        lines.append(f"::1\t{host}")
    lines.append(MARK_END)
    return "\n".join(lines)


def strip_marked(content):
    if content.count(MARK_START) != content.count(MARK_END):
        raise ValueError("The distractorRemover section in /etc/hosts is incomplete.")
    pattern = re.compile(
        re.escape(MARK_START) + r".*?" + re.escape(MARK_END) + r"\n?", re.DOTALL
    )
    return pattern.sub("", content)


def render_hosts(current, cfg):
    new = strip_marked(current).rstrip("\n") + "\n"
    if effective_blocking(cfg) and cfg.get("sites"):
        new += build_block_text(expanded_block_domains(cfg["sites"])) + "\n"
    return new


def effective_blocking(cfg):
    return bool(cfg.get("manual_enabled", cfg.get("manual_blocking", False))
                or cfg.get("scheduled_blocking"))


def hosts_match_config(content, cfg):
    try:
        return render_hosts(content, cfg) == content
    except ValueError:
        return False


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


def _parse_override(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        return None
    # Config stores local wall-clock time because schedules are local-time based.
    return parsed.replace(tzinfo=None) if parsed.tzinfo is not None else parsed


def schedule_blocking_at(dt, schedule, override_until=None):
    if not schedule.get("enabled") or not schedule.get("windows"):
        return False
    override = _parse_override(override_until) if isinstance(override_until, str) else override_until
    if override is not None and dt < override:
        return False
    return in_window(dt, schedule["windows"])


def next_schedule_transition(dt, schedule, override_until=None):
    """Return the next minute at which the derived schedule state changes."""
    current = schedule_blocking_at(dt, schedule, override_until)
    probe = dt.replace(second=0, microsecond=0)
    # A weekly schedule must repeat within eight days unless it is always on/off.
    for _ in range(8 * 24 * 60):
        probe += timedelta(minutes=1)
        if schedule_blocking_at(probe, schedule, override_until) != current:
            return probe
    return None


def refresh_runtime_state(cfg, now=None):
    now = now or datetime.now()
    override = _parse_override(cfg.get("schedule_override_until"))
    if override is not None and override <= now:
        override = None
        cfg["schedule_override_until"] = None
    cfg["scheduled_blocking"] = schedule_blocking_at(
        now, cfg["schedule"], override
    )
    cfg["blocking"] = effective_blocking(cfg)
    return cfg["scheduled_blocking"]


def format_local_time(dt):
    if dt is None:
        return "none"
    if dt.date() == datetime.now().date():
        return dt.strftime("%H:%M")
    return dt.strftime("%a %H:%M")


# ===========================================================================
# Config persistence
# ===========================================================================

class ConfigLoadError(RuntimeError):
    """A configuration exists but cannot be read without risking data loss."""


def default_config(now=None):
    cfg = {
        "schema_version": CONFIG_SCHEMA_VERSION,
        "sites": [],
        "manual_enabled": False,
        "schedule": {"enabled": False, "windows": []},
        "schedule_override_until": None,
    }
    refresh_runtime_state(cfg, now=now)
    return cfg


def _validate_config_shape(cfg):
    sites = cfg.get("sites", [])
    if sites is None:
        sites = []
    if not isinstance(sites, list):
        raise ConfigLoadError("The configuration's sites value must be a list.")
    for site in sites:
        if not isinstance(site, str) or not normalize_domain(site):
            raise ConfigLoadError("The configuration contains an invalid site entry.")

    schedule = cfg.get("schedule", {})
    if schedule is None:
        schedule = {}
    if not isinstance(schedule, dict):
        raise ConfigLoadError("The configuration's schedule value must be an object.")
    windows = schedule.get("windows", [])
    if windows is None:
        windows = []
    if not isinstance(windows, list):
        raise ConfigLoadError("The configuration's schedule windows must be a list.")
    for index, window in enumerate(windows, start=1):
        try:
            if not isinstance(window, dict):
                raise TypeError
            days = window["days"]
            if not isinstance(days, (list, tuple)) or not days:
                raise ValueError
            normalized_days = [int(day) for day in days]
            if any(day < 0 or day > 6 for day in normalized_days):
                raise ValueError
            start = _parse_time(window["start"])
            end = _parse_time(window["end"])
            if start == end:
                raise ValueError
        except (KeyError, TypeError, ValueError) as exc:
            raise ConfigLoadError(
                f"The configuration contains an invalid schedule window at position {index}."
            ) from exc

    override = cfg.get("schedule_override_until")
    if override is not None and not isinstance(override, str):
        raise ConfigLoadError("The configuration contains an invalid schedule override.")

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


def load_config(path=CONFIG_PATH, now=None):
    try:
        with open(path) as f:
            cfg = json.load(f)
    except FileNotFoundError:
        cfg = {}
    except json.JSONDecodeError as exc:
        raise ConfigLoadError(
            f"The configuration file is damaged and was left unchanged: {exc}"
        ) from exc
    except OSError as exc:
        raise ConfigLoadError(
            f"The configuration file could not be read and was left unchanged: {exc}"
        ) from exc
    if not isinstance(cfg, dict):
        raise ConfigLoadError(
            "The configuration file must contain a JSON object and was left unchanged."
        )
    _validate_config_shape(cfg)
    seen, sites = set(), []
    for s in cfg.get("sites") or []:
        d = normalize_domain(s) if isinstance(s, str) else ""
        if d and d not in seen:
            canonical = canonical_site(d)
            if canonical not in seen:
                seen.add(canonical)
                sites.append(canonical)
    manual_enabled = bool(cfg.get(
        "manual_enabled", cfg.get("manual_blocking", cfg.get("blocking", False))
    ))
    result = {
        "schema_version": CONFIG_SCHEMA_VERSION,
        "sites": sites,
        "manual_enabled": manual_enabled,
        "schedule": _clean_schedule(cfg.get("schedule")),
        "schedule_override_until": cfg.get("schedule_override_until"),
    }
    refresh_runtime_state(result, now=now)
    return result


def save_config(cfg, path=CONFIG_PATH):
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    tmp = path + ".tmp"
    manual_enabled = bool(cfg.get("manual_enabled", cfg.get("manual_blocking", False)))
    try:
        with open(tmp, "w") as f:
            json.dump(
                {
                    "schema_version": CONFIG_SCHEMA_VERSION,
                    "sites": cfg["sites"],
                    "manual_enabled": manual_enabled,
                    "schedule": cfg["schedule"],
                    "schedule_override_until": cfg.get("schedule_override_until"),
                },
                f, indent=2,
            )
            f.flush()
            os.fsync(f.fileno())
        cfg["manual_enabled"] = manual_enabled
        cfg["blocking"] = effective_blocking(cfg)
        os.replace(tmp, path)
        directory_fd = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except Exception:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


def reset_corrupt_config(path=CONFIG_PATH, now=None, save_fn=None):
    """Back up a damaged config and atomically replace it with safe defaults.

    If writing the replacement fails, the original file is restored so that a
    recovery attempt can never turn a readable backup problem into data loss.
    """
    save_fn = save_fn or save_config
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    backup = f"{path}.corrupt-{stamp}"
    os.replace(path, backup)
    cfg = default_config(now=now)
    try:
        save_fn(cfg, path)
    except Exception:
        try:
            os.remove(path)
        except OSError:
            pass
        os.replace(backup, path)
        raise
    return cfg, backup


def save_runtime_status(payload, path=STATE_PATH):
    """Best-effort durable status snapshot used by Status & Repair and support."""
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    tmp = path + ".tmp"
    try:
        with open(tmp, "w") as handle:
            json.dump(payload, handle, indent=2)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


def backup_hosts_file(source_path=HOSTS_PATH, backup_dir=HOSTS_BACKUP_DIR):
    """Create a private, byte-for-byte user backup before direct editing."""
    os.makedirs(backup_dir, mode=0o700, exist_ok=True)
    directory_info = os.lstat(backup_dir)
    if not stat.S_ISDIR(directory_info.st_mode):
        raise RuntimeError("The hosts backup path is not a private directory.")
    os.chmod(backup_dir, 0o700)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    destination = os.path.join(backup_dir, f"hosts-{stamp}.backup")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(destination, flags, 0o600)
    try:
        with open(source_path, "rb") as source, os.fdopen(fd, "wb") as target:
            while True:
                chunk = source.read(64 * 1024)
                if not chunk:
                    break
                target.write(chunk)
            target.flush()
            os.fsync(target.fileno())
    except Exception:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.remove(destination)
        except OSError:
            pass
        raise
    return destination


# ===========================================================================
# Applying to /etc/hosts (silent helper, or admin prompt)
# ===========================================================================

def helper_file_valid():
    try:
        info = os.lstat(HELPER_PATH)
    except OSError:
        return False
    return (
        stat.S_ISREG(info.st_mode)
        and info.st_uid == 0
        and not (info.st_mode & 0o022)
        and bool(info.st_mode & stat.S_IXUSR)
    )


def installed_helper_version():
    if not helper_file_valid():
        return None
    try:
        result = subprocess.run(
            ["/usr/bin/sudo", "-n", HELPER_PATH, "--check"],
            capture_output=True, text=True, timeout=3,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    match = re.fullmatch(r"ready ([0-9]+)", result.stdout.strip())
    return match.group(1) if match else None


def helper_ready():
    return installed_helper_version() in SUPPORTED_HELPER_VERSIONS


def helper_needs_upgrade():
    version = installed_helper_version()
    return version in SUPPORTED_HELPER_VERSIONS and version != HELPER_VERSION


def helper_diagnostic_status():
    version = installed_helper_version()
    if version is None:
        return "not ready"
    if version == HELPER_VERSION:
        return f"ready v{version}"
    if version in SUPPORTED_HELPER_VERSIONS:
        return f"ready v{version}; v{HELPER_VERSION} recovery upgrade available"
    return f"unsupported v{version}"


def helper_installed():
    """Compatibility name used by the UI; means installed *and usable*."""
    return helper_ready()


def _osa_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def open_hosts_in_textedit(path=HOSTS_PATH):
    return subprocess.run(
        ["/usr/bin/open", "-a", "TextEdit", path],
        capture_output=True, text=True,
    )


def open_hosts_backup_folder(path=HOSTS_BACKUP_DIR):
    os.makedirs(path, mode=0o700, exist_ok=True)
    return subprocess.run(["/usr/bin/open", path], capture_output=True, text=True)


def launch_hosts_terminal_editor(path=HOSTS_PATH, backup_path=""):
    message = f"Backup created: {backup_path}" if backup_path else "Backup created."
    command = " ; ".join([
        f"echo {shlex.quote(message)}",
        f"echo {shlex.quote('nano: save with Control-O, Enter; exit with Control-X')}",
        f"sudo /usr/bin/nano {shlex.quote(path)}",
    ])
    script = (
        'tell application "Terminal"\n'
        "activate\n"
        f"do script {_osa_str(command)}\n"
        "end tell"
    )
    return subprocess.run(
        ["/usr/bin/osascript", "-e", script], capture_output=True, text=True
    )


def run_privileged_script(script_path, *args):
    """Run a bash script as root via one native admin prompt."""
    cmd = " ".join(shlex.quote(p) for p in ["/bin/bash", script_path, *args])
    osa = "do shell script " + _osa_str(cmd) + " with administrator privileges"
    return subprocess.run(["/usr/bin/osascript", "-e", osa], capture_output=True, text=True)


def reset_managed_hosts_section(allow_prompt=True):
    """Repair and remove even an incomplete managed section after a backup."""
    if installed_helper_version() == HELPER_VERSION:
        try:
            result = subprocess.run(
                ["/usr/bin/sudo", "-n", HELPER_PATH, "--reset"],
                capture_output=True, text=True, timeout=15,
            )
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError("Password-free helper timed out during reset.") from exc
    else:
        if not allow_prompt:
            raise RuntimeError("Administrator approval is required to reset the hosts section.")
        result = run_privileged_script(PRIVILEGED_HELPER_SH, "--reset")
    if result.returncode != 0:
        error = (result.stderr or result.stdout or "").strip()
        if "-128" in error or "cancel" in error.lower():
            raise PermissionError("cancelled")
        raise RuntimeError(error or "Could not reset the managed hosts section.")
    return (result.stdout or "").strip()


def apply_hosts(cfg, force=False, allow_prompt=True, hosts_path=HOSTS_PATH):
    """Make /etc/hosts match cfg. Silent via helper if available, else prompts.

    Raises PermissionError if the user cancels a prompt, RuntimeError otherwise.
    """
    with open(hosts_path) as f:
        current = f.read()
    desired = render_hosts(current, cfg)
    if desired == current and not force:
        return

    if hosts_path == HOSTS_PATH and helper_ready():
        domains = expanded_block_domains(cfg.get("sites") or [])
        should_block = effective_blocking(cfg) and bool(domains)
        action = "--apply" if should_block else "--clear"
        payload = "\n".join(domains) + ("\n" if domains else "")
        try:
            result = subprocess.run(
                ["/usr/bin/sudo", "-n", HELPER_PATH, action],
                input=payload if should_block else "",
                capture_output=True, text=True, timeout=15,
            )
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError("Password-free helper timed out.") from exc
        if result.returncode != 0:
            raise RuntimeError((result.stderr or result.stdout).strip() or "helper failed")
        with open(hosts_path) as f:
            applied = f.read()
        if not hosts_match_config(applied, cfg):
            raise RuntimeError("The hosts file did not match the requested state after applying.")
        return

    if not allow_prompt:
        raise RuntimeError("Password-free mode is unavailable; automatic blocking cannot update hosts.")

    os.makedirs(SUPPORT_DIR, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(STAGED_PATH, flags, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(desired)
        f.flush()
        os.fsync(f.fileno())
    try:
        shell_cmd = (
            f"cp {shlex.quote(STAGED_PATH)} {shlex.quote(hosts_path)} && "
            "{ dscacheutil -flushcache || true; killall -HUP mDNSResponder || true; }"
        )
        osa = "do shell script " + _osa_str(shell_cmd) + " with administrator privileges"
        r = subprocess.run(["/usr/bin/osascript", "-e", osa], capture_output=True, text=True)
        if r.returncode != 0:
            err = (r.stderr or "").strip()
            if "-128" in err or "cancel" in err.lower():
                raise PermissionError("cancelled")
            raise RuntimeError(err or "Failed to update the hosts file.")
        with open(hosts_path) as f:
            applied = f.read()
        if not hosts_match_config(applied, cfg):
            raise RuntimeError("The hosts file did not match the requested state after applying.")
    finally:
        try:
            os.remove(STAGED_PATH)
        except OSError:
            pass


def setup_logging():
    if logger.handlers:
        return
    os.makedirs(SUPPORT_DIR, exist_ok=True)
    handler = RotatingFileHandler(LOG_PATH, maxBytes=512_000, backupCount=2)
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)


def acquire_single_instance():
    global _instance_lock_file
    os.makedirs(SUPPORT_DIR, exist_ok=True)
    lock_file = open(LOCK_PATH, "a+")
    try:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        lock_file.close()
        return False
    _instance_lock_file = lock_file
    return True


def reconcile_once(cfg, read_hosts, apply_change, now=None):
    """Reconcile one desired/actual state transition using injected side effects."""
    refresh_runtime_state(cfg, now=now)
    content = read_hosts()
    if not hosts_match_config(content, cfg):
        apply_change()
        content = read_hosts()
    if not hosts_match_config(content, cfg):
        raise RuntimeError("The actual hosts state does not match the requested state.")
    return content


def read_hosts_text(path=HOSTS_PATH):
    with open(path) as handle:
        return handle.read()


def launch_agent_status():
    plist = os.path.expanduser(
        "~/Library/LaunchAgents/com.sjk.distractorremover.plist"
    )
    if not os.path.exists(plist):
        return "not installed"
    try:
        result = subprocess.run(
            [
                "/bin/launchctl", "print",
                f"gui/{os.getuid()}/com.sjk.distractorremover",
            ],
            capture_output=True, text=True, timeout=3,
        )
    except (OSError, subprocess.TimeoutExpired):
        return "installed; status unavailable"
    if result.returncode != 0:
        return "installed but not loaded"
    if "state = running" in result.stdout:
        return "loaded and running"
    return "loaded but not running"


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
        setup_logging()
        self.config_load_error = ""
        try:
            self.cfg = load_config()
        except ConfigLoadError as exc:
            self.cfg = default_config()
            self.config_load_error = str(exc)
        self._sched_editor = None
        self.actual_blocking = False
        self.apply_status = "error" if self.config_load_error else "pending"
        self.last_error = ""
        self.retry_count = 0
        self.next_retry_at = 0.0
        self.last_verify_at = 0.0
        self._last_failure_cancelled = False
        self._read_actual_state()
        if self.config_load_error:
            self.last_error = self.config_load_error
            logger.error("configuration recovery required: %s", self.config_load_error)
        self.rebuild()
        self._record_runtime_status()

    # --- state helpers -----------------------------------------------------

    def _sync_blocking(self):
        refresh_runtime_state(self.cfg)

    def _active(self):
        return self.actual_blocking

    def _desired_active(self):
        return bool(effective_blocking(self.cfg) and self.cfg["sites"])

    def _read_actual_state(self):
        try:
            with open(HOSTS_PATH) as f:
                content = f.read()
            self.actual_blocking = MARK_START in content and MARK_END in content
            return content
        except OSError as exc:
            self.actual_blocking = False
            self.last_error = str(exc)
            return None

    def _active_reason(self):
        manual = bool(self.cfg.get("manual_enabled"))
        scheduled = bool(self.cfg.get("scheduled_blocking"))
        if manual and scheduled:
            return "Manual + Schedule"
        if manual:
            return "Manual"
        if scheduled:
            return "Schedule"
        return "None"

    def _status_title(self):
        if self.config_load_error:
            return "⚠ Configuration damaged — recovery required"
        if self.apply_status in ("retrying", "error"):
            state = "blocking" if self.actual_blocking else "not blocking"
            return f"⚠ Update failed — currently {state}"
        if self.actual_blocking:
            return f"🛡 Blocking — {self._active_reason()}"
        if self.cfg["schedule"].get("enabled"):
            transition = next_schedule_transition(
                datetime.now(), self.cfg["schedule"], self.cfg.get("schedule_override_until")
            )
            return f"⚪ Not blocking — next change {format_local_time(transition)}"
        return "⚪ Not blocking"

    def update_icon(self):
        if self.apply_status in ("retrying", "error"):
            self.title = ICON_ERROR
        else:
            self.title = ICON_ON if self._active() else ICON_OFF

    def _mark_failure(self, error):
        self.retry_count += 1
        delay = RETRY_DELAYS[min(self.retry_count - 1, len(RETRY_DELAYS) - 1)]
        self.next_retry_at = time.monotonic() + delay
        self.apply_status = "retrying"
        self.last_error = str(error)
        logger.error("hosts reconciliation failed: %s", error)
        self._read_actual_state()
        self._record_runtime_status()

    def _record_runtime_status(self):
        try:
            save_runtime_status({
                "version": APP_VERSION,
                "updated_at": datetime.now().astimezone().isoformat(timespec="seconds"),
                "apply_status": self.apply_status,
                "desired_blocking": self._desired_active(),
                "actual_blocking": self.actual_blocking,
                "retry_count": self.retry_count,
                "last_error": self.last_error,
                "config_recovery_required": bool(self.config_load_error),
            })
        except Exception as exc:
            logger.warning("could not write runtime status: %s", exc)

    def _reconcile(self, reason, allow_prompt=False, show_alert=False):
        """Make actual hosts state match persisted user intent and verify it."""
        if self.config_load_error:
            self.apply_status = "error"
            self.last_error = self.config_load_error
            return False
        self._last_failure_cancelled = False
        try:
            content = reconcile_once(
                self.cfg,
                read_hosts=read_hosts_text,
                apply_change=lambda: apply_hosts(self.cfg, allow_prompt=allow_prompt),
            )
            self.actual_blocking = MARK_START in content and MARK_END in content
        except PermissionError:
            self._last_failure_cancelled = True
            self._read_actual_state()
            return False
        except Exception as e:
            self._mark_failure(e)
            if show_alert:
                rumps.alert(
                    "Couldn't update blocking",
                    f"{e}\n\nThe app will keep retrying. Open Status & Repair for details.",
                )
            self.rebuild()
            return False
        try:
            save_config(self.cfg)
        except Exception as exc:
            self._mark_failure(f"Could not save settings after {reason}: {exc}")
            if show_alert:
                rumps.alert(
                    "Couldn't save settings",
                    f"{exc}\n\nThe app will keep retrying. Open Status & Repair for details.",
                )
            self.rebuild()
            return False
        self.apply_status = "ok"
        self.last_error = ""
        self.retry_count = 0
        self.next_retry_at = 0.0
        self.last_verify_at = time.monotonic()
        logger.info("hosts reconciled (%s), active=%s", reason, self.actual_blocking)
        self._record_runtime_status()
        self.rebuild()
        return True

    def _persist_current_config(self, reason, show_alert=True):
        try:
            save_config(self.cfg)
            return True
        except Exception as exc:
            self._mark_failure(f"Could not save settings after {reason}: {exc}")
            if show_alert:
                rumps.alert(
                    "Couldn't save settings",
                    f"{exc}\n\nYour change is kept in memory and will be retried automatically.",
                )
            self.rebuild()
            return False

    def _apply_user_change(self, revert):
        if not self._persist_current_config("user change"):
            return False
        if self._reconcile("user", allow_prompt=True, show_alert=True):
            return True
        if self._last_failure_cancelled:
            revert()
            refresh_runtime_state(self.cfg)
            if not self._persist_current_config("cancelled user change", show_alert=False):
                return False
            self._reconcile("cancelled-user-change", allow_prompt=False)
        return False

    # --- menu --------------------------------------------------------------

    def rebuild(self):
        self.menu.clear()
        refresh_runtime_state(self.cfg)
        if self.config_load_error:
            status = rumps.MenuItem(self._status_title())
            status.set_callback(None)
            self.menu.update([
                status,
                rumps.separator,
                rumps.MenuItem(
                    "Recover damaged configuration…", callback=self.recover_damaged_config
                ),
                rumps.MenuItem(
                    "Reset managed hosts section…", callback=self.reset_managed_hosts
                ),
                ("📝  Hosts file", self._hosts_file_items(include_block_list=False)),
                rumps.separator,
                rumps.MenuItem("Status & Repair…", callback=self.show_diagnostics),
                rumps.MenuItem("Quit distractorRemover…", callback=self.quit_app),
            ])
            self.update_icon()
            return
        n = len(self.cfg["sites"])

        manual = bool(self.cfg.get("manual_enabled"))
        scheduled = bool(self.cfg.get("scheduled_blocking"))
        if manual:
            toggle_title = "🛡️  Manual blocking is ON  —  click to turn OFF"
        else:
            suffix = "  (schedule is blocking now)" if scheduled else ""
            toggle_title = f"⚪  Manual blocking is OFF  —  click to turn ON{suffix}"

        status = rumps.MenuItem(self._status_title())
        status.set_callback(None)

        header = rumps.MenuItem(
            f"Blocked services ({n}) · {len(expanded_block_domains(self.cfg['sites']))} domains"
        )
        header.set_callback(None)

        site_items = []
        if n == 0:
            empty = rumps.MenuItem("    (none yet — add one above)")
            empty.set_callback(None)
            site_items.append(empty)
        elif self._active():
            # Blocking is ON: sites are locked — you can add, but not remove.
            for d in self.cfg["sites"]:
                site_items.append(rumps.MenuItem(
                    f"    🔒 {site_display_name(d)}", callback=self.locked_remove
                ))
        else:
            for d in self.cfg["sites"]:
                site_items.append(rumps.MenuItem(
                    f"    {site_display_name(d)}      ✕", callback=self._remover(d)
                ))

        structure = [
            status,
            *([rumps.MenuItem("Retry blocking update now", callback=self.retry_now)]
              if self.apply_status in ("retrying", "error") else []),
            rumps.separator,
            rumps.MenuItem(toggle_title, callback=self.toggle_blocking),
            rumps.MenuItem("Turn off all blocking…", callback=self.turn_off_all),
            rumps.separator,
            rumps.MenuItem("➕  Add site…", callback=self.add_site),
            rumps.separator,
            header,
            *site_items,
            rumps.separator,
            ("⏰  Schedule", self._schedule_items()),
            ("📝  Hosts file", self._hosts_file_items()),
            rumps.separator,
            rumps.MenuItem("Status & Repair…", callback=self.show_diagnostics),
            rumps.MenuItem("Reset managed hosts section…", callback=self.reset_managed_hosts),
            rumps.MenuItem("Quit distractorRemover…", callback=self.quit_app),
        ]
        self.menu.update(structure)
        self.update_icon()

    def _hosts_file_items(self, include_block_list=True):
        items = []
        if include_block_list:
            items.append(rumps.MenuItem(
                "Edit app block list as text…", callback=self.edit_block_list_text
            ))
            items.append(rumps.separator)
        items.extend([
            rumps.MenuItem(
                "Open /etc/hosts in TextEdit…", callback=self.view_hosts_file
            ),
            rumps.MenuItem(
                "Edit /etc/hosts as administrator…", callback=self.edit_hosts_file_directly
            ),
            rumps.MenuItem(
                "Open hosts backup folder…", callback=self.open_hosts_backups
            ),
        ])
        return items

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

        if sch["enabled"]:
            now = datetime.now()
            transition = next_schedule_transition(
                now, sch, self.cfg.get("schedule_override_until")
            )
            override = _parse_override(self.cfg.get("schedule_override_until"))
            if override is not None and now < override:
                current_text = f"Paused until {format_local_time(override)}"
            elif self.cfg.get("scheduled_blocking"):
                current_text = f"Active now · changes {format_local_time(transition)}"
            else:
                current_text = f"Inactive now · changes {format_local_time(transition)}"
            current = rumps.MenuItem(current_text)
            current.set_callback(None)
            items.append(current)
            if override is not None and now < override:
                items.append(rumps.MenuItem("Resume current window", callback=self.resume_schedule))
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
        if helper_ready():
            pf = rumps.MenuItem("Password-free mode is ON — click to turn OFF",
                                callback=self.toggle_pwfree)
            pf.state = 1
        else:
            pf = rumps.MenuItem("Enable password-free mode…", callback=self.toggle_pwfree)
        items.append(pf)
        if helper_needs_upgrade():
            items.append(rumps.MenuItem(
                f"Upgrade helper to v{HELPER_VERSION} for hosts recovery…",
                callback=self.upgrade_helper,
            ))
        return items

    def _remover(self, domain):
        return lambda _: self.remove_site(domain)

    # --- site actions ------------------------------------------------------

    def toggle_blocking(self, _):
        old_manual = bool(self.cfg.get("manual_enabled"))
        want = not old_manual
        if want and not self.cfg["sites"]:
            rumps.alert("No sites yet", "Add a site to block first.")
            return
        if not want:
            msg = "This turns off manual blocking."
            if self.cfg.get("scheduled_blocking"):
                msg += "\n\nThe current schedule window is still active, so sites will remain blocked."
            if rumps.alert("Turn off manual blocking?", msg,
                           ok="Turn off", cancel="Keep blocking") != 1:
                return
        self.cfg["manual_enabled"] = want
        self._apply_user_change(revert=lambda: self.cfg.update(manual_enabled=old_manual))

    def locked_remove(self, _):
        rumps.alert(
            "Locked while blocking",
            "You can’t remove a site while blocking is on — you can only add.\n"
            "Use “Turn off all blocking…” first, then remove it.",
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
        domain = canonical_site(domain)
        if domain in self.cfg["sites"]:
            rumps.alert("Already added", f"{site_display_name(domain)} is already in your list.")
            return
        self.cfg["sites"].append(domain)
        refresh_runtime_state(self.cfg)
        if self._desired_active():
            self._apply_user_change(revert=lambda: self.cfg["sites"].remove(domain))
        else:
            if self._persist_current_config("site added"):
                self.rebuild()

    def edit_block_list_text(self, _):
        _activate_app()
        old_sites = list(self.cfg["sites"])
        draft = "\n".join(old_sites) + ("\n" if old_sites else "")
        locked = self._active()
        try:
            from AppKit import NSAlert, NSBezelBorder, NSFont, NSScrollView, NSTextView
            from Foundation import NSMakeRect

            while True:
                text_view = NSTextView.alloc().initWithFrame_(NSMakeRect(0, 0, 520, 260))
                text_view.setString_(draft)
                try:
                    text_view.setFont_(NSFont.monospacedSystemFontOfSize_weight_(12, 0))
                except Exception:
                    text_view.setFont_(NSFont.userFixedPitchFontOfSize_(12))
                scroll = NSScrollView.alloc().initWithFrame_(NSMakeRect(0, 0, 520, 260))
                scroll.setHasVerticalScroller_(True)
                scroll.setBorderType_(NSBezelBorder)
                scroll.setDocumentView_(text_view)

                alert = NSAlert.alloc().init()
                alert.setMessageText_("Edit app block list as text")
                note = (
                    "Enter one domain or URL per line. You can also paste 127.0.0.1/::1 "
                    "lines copied from /etc/hosts. Blank lines and # comments are ignored."
                )
                if locked:
                    note += " Blocking is active, so existing entries cannot be removed."
                alert.setInformativeText_(note)
                alert.setAccessoryView_(scroll)
                alert.addButtonWithTitle_("Save")
                alert.addButtonWithTitle_("Cancel")
                alert.window().setInitialFirstResponder_(text_view)
                if alert.runModal() != 1000:
                    return
                draft = str(text_view.string())
                try:
                    new_sites = parse_site_list_text(draft)
                except ValueError as exc:
                    rumps.alert("Invalid block list", str(exc))
                    continue
                removed = [site for site in old_sites if site not in new_sites]
                if self._active() and removed:
                    rumps.alert(
                        "Locked while blocking",
                        "Existing entries cannot be removed while blocking is active. "
                        "You can still add new entries.",
                    )
                    continue
                break
        except Exception as exc:
            rumps.alert("Text editor error", str(exc))
            return

        if new_sites == old_sites:
            return
        self.cfg["sites"] = new_sites
        refresh_runtime_state(self.cfg)
        if self._desired_active() or self._active():
            self._apply_user_change(
                revert=lambda: self.cfg.update(sites=old_sites)
            )
        elif self._persist_current_config("text block list edited"):
            self.rebuild()

    def view_hosts_file(self, _):
        result = open_hosts_in_textedit()
        if result.returncode != 0:
            rumps.alert(
                "Couldn't open /etc/hosts",
                (result.stderr or result.stdout or "TextEdit could not open the file.").strip(),
            )

    def edit_hosts_file_directly(self, _):
        _activate_app()
        if rumps.alert(
            "Edit the system hosts file directly?",
            "The complete file will be backed up first, then Terminal will open sudo nano. "
            "Incorrect edits can affect networking. Lines between distractorRemover markers "
            "are app-managed and may be rewritten; use “Edit app block list as text…” for "
            "persistent blocking changes.\n\nIn nano: Control-O saves, Enter confirms, and "
            "Control-X exits.",
            ok="Back up & open Terminal", cancel="Cancel",
        ) != 1:
            return
        try:
            backup = backup_hosts_file()
            result = launch_hosts_terminal_editor(backup_path=backup)
        except Exception as exc:
            rumps.alert("Couldn't open the editor", str(exc))
            return
        if result.returncode != 0:
            rumps.alert(
                "Couldn't open Terminal",
                (result.stderr or result.stdout or "Terminal could not be opened.").strip(),
            )
            return
        logger.info("opened direct hosts editor after backup to %s", backup)

    def open_hosts_backups(self, _):
        result = open_hosts_backup_folder()
        if result.returncode != 0:
            rumps.alert(
                "Couldn't open the backup folder",
                (result.stderr or result.stdout or "Finder could not open the folder.").strip(),
            )

    def remove_site(self, domain):
        if domain not in self.cfg["sites"]:
            return
        if rumps.alert(f"Remove {domain}?", "It will no longer be blocked.",
                       ok="Remove", cancel="Cancel") != 1:
            return
        idx = self.cfg["sites"].index(domain)
        self.cfg["sites"].remove(domain)
        refresh_runtime_state(self.cfg)
        if self._desired_active() or self._active():
            self._apply_user_change(revert=lambda: self.cfg["sites"].insert(idx, domain))
        else:
            if self._persist_current_config("site removed"):
                self.rebuild()

    def _turn_off_all(self, confirm=True):
        refresh_runtime_state(self.cfg)
        if not self._desired_active() and not self._active():
            if confirm:
                rumps.alert("Already off", "No blocking is currently active.")
            return True
        if confirm and rumps.alert(
            "Turn off all blocking?",
            "Manual blocking will turn off. If a schedule window is active, it will be "
            "paused until that window ends; future schedule windows stay enabled.",
            ok="Turn off all", cancel="Keep blocking",
        ) != 1:
            return False

        old_manual = bool(self.cfg.get("manual_enabled"))
        old_override = self.cfg.get("schedule_override_until")
        old_enabled = self.cfg["schedule"]["enabled"]
        now = datetime.now()
        self.cfg["manual_enabled"] = False
        if self.cfg.get("scheduled_blocking"):
            transition = next_schedule_transition(now, self.cfg["schedule"])
            if transition is None:
                # A schedule with no off transition is effectively always-on.
                self.cfg["schedule"]["enabled"] = False
                self.cfg["schedule_override_until"] = None
            else:
                self.cfg["schedule_override_until"] = transition.isoformat(timespec="minutes")
        refresh_runtime_state(self.cfg, now=now)
        return self._apply_user_change(
            revert=lambda: (
                self.cfg.update(
                    manual_enabled=old_manual,
                    schedule_override_until=old_override,
                ),
                self.cfg["schedule"].update(enabled=old_enabled),
            )
        )

    def turn_off_all(self, _):
        self._turn_off_all(confirm=True)

    def resume_schedule(self, _):
        old_override = self.cfg.get("schedule_override_until")
        self.cfg["schedule_override_until"] = None
        refresh_runtime_state(self.cfg)
        self._apply_user_change(
            revert=lambda: self.cfg.update(schedule_override_until=old_override)
        )

    # --- schedule actions --------------------------------------------------

    def toggle_schedule(self, _):
        sch = self.cfg["schedule"]
        if sch["enabled"]:
            refresh_runtime_state(self.cfg)
            if self.cfg.get("scheduled_blocking") and rumps.alert(
                "Disable the schedule?",
                "The current schedule window is active. Disabling it may unblock sites now.",
                ok="Disable schedule", cancel="Keep schedule",
            ) != 1:
                return
            old_enabled = sch["enabled"]
            old_override = self.cfg.get("schedule_override_until")
            sch["enabled"] = False
            self.cfg["schedule_override_until"] = None
            refresh_runtime_state(self.cfg)
            self._apply_user_change(
                revert=lambda: (
                    sch.update(enabled=old_enabled),
                    self.cfg.update(schedule_override_until=old_override),
                )
            )
            return
        if not sch["windows"]:
            rumps.alert("Set a time window first",
                        "Open “Edit time windows…” and add at least one, "
                        "e.g. Mon-Fri 09:00-18:00.")
            return
        if not helper_ready():
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
        self.cfg["schedule_override_until"] = None
        refresh_runtime_state(self.cfg)
        if not self._persist_current_config("schedule enabled"):
            return
        self._reconcile("schedule-enabled", allow_prompt=False, show_alert=True)

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
            old_windows = list(self.cfg["schedule"]["windows"])
            old_enabled = self.cfg["schedule"]["enabled"]
            old_override = self.cfg.get("schedule_override_until")
            self.cfg["schedule"]["windows"] = windows
            self.cfg["schedule_override_until"] = None
            if not windows:
                self.cfg["schedule"]["enabled"] = False
                refresh_runtime_state(self.cfg)
                self._apply_user_change(
                    revert=lambda: (
                        self.cfg["schedule"].update(windows=old_windows, enabled=old_enabled),
                        self.cfg.update(schedule_override_until=old_override),
                    )
                )
                return
            refresh_runtime_state(self.cfg)
            if not self._persist_current_config("schedule edited"):
                return
            self.rebuild()
            if windows and not self.cfg["schedule"]["enabled"]:
                if rumps.alert("Schedule saved", "Turn on scheduled blocking now?",
                               ok="Turn on", cancel="Not now") == 1:
                    self.toggle_schedule(None)  # handles password-free setup + enforce
            elif self.cfg["schedule"]["enabled"]:
                self._reconcile("schedule-edited", allow_prompt=False, show_alert=True)

        try:
            self._sched_editor = schedule_editor.open_editor(
                self.cfg["schedule"]["windows"], done)
        except Exception as e:
            self._sched_editor = None
            rumps.alert("Schedule editor error", str(e))

    def toggle_pwfree(self, _):
        if helper_ready():
            if rumps.alert(
                "Turn off password-free mode?",
                "Scheduled auto on/off will stop, and manual changes will ask for your "
                "password again.",
                ok="Turn off", cancel="Cancel",
            ) != 1:
                return

            old_enabled = self.cfg["schedule"]["enabled"]
            old_override = self.cfg.get("schedule_override_until")
            if old_enabled:
                self.cfg["schedule"]["enabled"] = False
                self.cfg["schedule_override_until"] = None
                refresh_runtime_state(self.cfg)
                if not self._persist_current_config("helper removal preflight"):
                    return
                if not self._reconcile("helper-removal-preflight", allow_prompt=False):
                    self.cfg["schedule"]["enabled"] = old_enabled
                    self.cfg["schedule_override_until"] = old_override
                    refresh_runtime_state(self.cfg)
                    if not self._persist_current_config(
                        "helper removal rollback", show_alert=False
                    ):
                        return
                    self._reconcile("helper-removal-reverted", allow_prompt=False)
                    rumps.alert("Couldn't turn off schedule", self.last_error)
                    return

            r = run_privileged_script(UNINSTALL_HELPER_SH)
            if r.returncode != 0:
                self.cfg["schedule"]["enabled"] = old_enabled
                self.cfg["schedule_override_until"] = old_override
                refresh_runtime_state(self.cfg)
                if not self._persist_current_config(
                    "cancelled helper removal", show_alert=False
                ):
                    return
                self._reconcile("helper-removal-cancelled", allow_prompt=False)
                err = (r.stderr or r.stdout or "").strip()
                if "-128" not in err and "cancel" not in err.lower():
                    rumps.alert("Failed", err or "Could not remove helper.")
                return
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

    def upgrade_helper(self, _):
        if rumps.alert(
            f"Upgrade password-free helper to v{HELPER_VERSION}?",
            "Existing automatic blocking continues to work with the installed helper. "
            "The upgrade adds backup-based recovery for a damaged hosts marker and can be "
            "rolled back automatically if installation fails.",
            ok="Upgrade", cancel="Not now",
        ) != 1:
            return
        if self._do_install_helper():
            self.rebuild()

    def _do_install_helper(self):
        r = run_privileged_script(INSTALL_HELPER_SH, getpass.getuser())
        if r.returncode == 0 and helper_ready():
            return True
        err = (r.stderr or r.stdout or "").strip()
        if "-128" in err or "cancel" in err.lower():
            return False  # user cancelled
        rumps.alert("Couldn't enable password-free mode", err or "Unknown error.")
        return False

    def retry_now(self, _):
        if self.config_load_error:
            self.recover_damaged_config(None)
            return
        self._reconcile("manual-retry", allow_prompt=True, show_alert=True)

    def recover_damaged_config(self, _):
        if not self.config_load_error:
            return
        _activate_app()
        if rumps.alert(
            "Recover damaged configuration?",
            "The unreadable file will be preserved with a .corrupt timestamp, then a safe "
            "empty configuration will be created. The app will not overwrite the original "
            "unless this is confirmed.",
            ok="Back up & reset", cancel="Keep unchanged",
        ) != 1:
            return
        try:
            cfg, backup = reset_corrupt_config(CONFIG_PATH)
        except Exception as exc:
            self.last_error = f"Configuration recovery failed: {exc}"
            self.apply_status = "error"
            logger.error("configuration recovery failed: %s", exc)
            rumps.alert("Recovery failed", str(exc))
            self.rebuild()
            return
        self.cfg = cfg
        self.config_load_error = ""
        self.apply_status = "pending"
        self.last_error = ""
        self.retry_count = 0
        self.next_retry_at = 0.0
        logger.warning("damaged configuration backed up to %s", backup)
        rumps.alert(
            "Configuration recovered",
            f"The original file was preserved at:\n{backup}\n\n"
            "Blocking will now be reconciled from the new empty configuration.",
        )
        self._reconcile("config-recovered", allow_prompt=True, show_alert=True)

    def reset_managed_hosts(self, _):
        _activate_app()
        if rumps.alert(
            "Reset managed hosts section?",
            "This repairs and removes distractorRemover marker lines, including an incomplete "
            "section. A backup of the complete hosts file is created first. If blocking is "
            "currently requested, the clean section is then applied again.",
            ok="Back up & reset", cancel="Cancel",
        ) != 1:
            return
        try:
            result = reset_managed_hosts_section(allow_prompt=True)
        except PermissionError:
            return
        except Exception as exc:
            self._mark_failure(f"Managed hosts reset failed: {exc}")
            rumps.alert("Reset failed", str(exc))
            self.rebuild()
            return
        self._read_actual_state()
        if self.config_load_error:
            self.apply_status = "error"
            self.last_error = self.config_load_error
            self.rebuild()
        else:
            self.apply_status = "pending"
            self.last_error = ""
            self._reconcile("managed-section-reset", allow_prompt=True, show_alert=True)
        rumps.alert(
            "Managed section reset",
            (result or "The hosts backup was created.")
            + "\n\nThe managed section was repaired safely.",
        )

    def show_diagnostics(self, _):
        _activate_app()
        content = self._read_actual_state()
        matches = (
            not self.config_load_error
            and content is not None
            and hosts_match_config(content, self.cfg)
        )
        override = self.cfg.get("schedule_override_until") or "none"
        message = "\n".join([
            f"Version: {APP_VERSION}",
            f"Requested: {'ON' if self._desired_active() else 'OFF'} ({self._active_reason()})",
            f"Actual hosts: {'ON' if self.actual_blocking else 'OFF'}",
            f"State matches: {'yes' if matches else 'NO'}",
            f"Apply status: {self.apply_status}",
            f"Password-free helper: {helper_diagnostic_status()}",
            f"Schedule override: {override}",
            f"Autostart: {launch_agent_status()}",
            f"Config: {CONFIG_PATH}",
            f"Runtime status: {STATE_PATH}",
            f"Log: {LOG_PATH}",
        ])
        if self.config_load_error:
            message += "\n\nConfiguration is locked to prevent accidental data loss."
        if self.last_error:
            message += f"\n\nLast error:\n{self.last_error}"
        try:
            from AppKit import NSAlert
            alert = NSAlert.alloc().init()
            alert.setMessageText_("distractorRemover Status & Repair")
            alert.setInformativeText_(message)
            alert.addButtonWithTitle_(
                "Recover configuration" if self.config_load_error else "Repair now"
            )
            alert.addButtonWithTitle_("Reset managed hosts section")
            alert.addButtonWithTitle_("Close")
            choice = alert.runModal()
        except Exception:
            choice = 1002
        if choice == 1000:
            if self.config_load_error:
                self.recover_damaged_config(None)
            else:
                self._reconcile("diagnostic-repair", allow_prompt=True, show_alert=True)
        elif choice == 1001:
            self.reset_managed_hosts(None)

    def quit_app(self, _):
        if not self._active() and not self.cfg["schedule"].get("enabled"):
            rumps.quit_application()
            return
        try:
            from AppKit import NSAlert
            alert = NSAlert.alloc().init()
            alert.setMessageText_("Quit distractorRemover?")
            alert.setInformativeText_(
                "Keeping current blocking leaves the hosts rule in place, but scheduled "
                "changes stop until the app starts again."
            )
            alert.addButtonWithTitle_("Keep blocking and quit")
            alert.addButtonWithTitle_("Unblock and quit")
            alert.addButtonWithTitle_("Cancel")
            choice = alert.runModal()
        except Exception:
            choice = 1002
        if choice == 1000:
            rumps.quit_application()
        elif choice == 1001 and self._turn_off_all(confirm=False):
            rumps.quit_application()

    # --- lifecycle ---------------------------------------------------------

    @rumps.timer(5)
    def _schedule_tick(self, _):
        if self.config_load_error:
            return
        old_scheduled = bool(self.cfg.get("scheduled_blocking"))
        old_override = self.cfg.get("schedule_override_until")
        refresh_runtime_state(self.cfg)
        state_changed = old_scheduled != bool(self.cfg.get("scheduled_blocking"))
        override_expired = old_override != self.cfg.get("schedule_override_until")
        retry_due = (
            self.apply_status in ("retrying", "error")
            and time.monotonic() >= self.next_retry_at
        )
        verify_due = time.monotonic() - self.last_verify_at >= 30
        if state_changed or override_expired or retry_due or verify_due:
            self._reconcile("timer", allow_prompt=False)

    @rumps.timer(0.3)
    def _on_startup(self, sender):
        sender.stop()  # run once
        try:
            from AppKit import NSApp
            NSApp.setActivationPolicy_(1)  # accessory: menu-bar-only, no dock icon
        except Exception:
            pass
        self._reconcile("startup", allow_prompt=False)


if __name__ == "__main__":
    if acquire_single_instance():
        DistractorRemover().run()

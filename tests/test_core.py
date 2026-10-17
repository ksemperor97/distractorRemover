import os
import stat
import sys
import tempfile
import unittest
from datetime import datetime
from unittest import mock


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

import distractor_remover as dr


class DomainTests(unittest.TestCase):
    def test_normalize_url(self):
        self.assertEqual(
            dr.normalize_domain("https://www.YouTube.com/feed?list=abc"),
            "youtube.com",
        )

    def test_normalize_rejects_non_domain(self):
        self.assertEqual(dr.normalize_domain("not a domain"), "")

    def test_normalize_idn(self):
        self.assertEqual(
            dr.normalize_domain("https://www.예시.한국/path"),
            "xn--vv4b11d.xn--3e0b707e",
        )

    def test_service_preset_canonicalizes_alias_and_expands_entry_points(self):
        self.assertEqual(dr.canonical_site("youtu.be"), "youtube.com")
        expanded = dr.expanded_block_domains(["youtube.com"])
        self.assertIn("m.youtube.com", expanded)
        self.assertIn("music.youtube.com", expanded)
        self.assertIn("youtu.be", expanded)

    def test_hosts_render_is_idempotent_and_preserves_unmanaged_lines(self):
        base = "127.0.0.1 localhost\n10.0.0.2 internal.test\n"
        cfg = {
            "sites": ["youtube.com"],
            "manual_blocking": True,
            "scheduled_blocking": False,
        }
        blocked = dr.render_hosts(base, cfg)
        self.assertIn("10.0.0.2 internal.test", blocked)
        self.assertIn("127.0.0.1\tyoutube.com", blocked)
        self.assertIn("::1\twww.youtube.com", blocked)
        self.assertEqual(dr.render_hosts(blocked, cfg), blocked)

        cfg["manual_blocking"] = False
        self.assertEqual(dr.render_hosts(blocked, cfg), base)

    def test_incomplete_managed_section_is_not_silently_rewritten(self):
        broken = "127.0.0.1 localhost\n" + dr.MARK_START + "\n127.0.0.1\texample.com\n"
        with self.assertRaises(ValueError):
            dr.strip_marked(broken)

    def test_text_block_list_accepts_domains_urls_and_hosts_lines(self):
        text = """
        # Paste either domains or lines copied from /etc/hosts
        youtube.com
        https://www.instagram.com/explore
        127.0.0.1 m.youtube.com youtu.be
        ::1 reddit.com
        """
        self.assertEqual(
            dr.parse_site_list_text(text),
            ["youtube.com", "instagram.com", "reddit.com"],
        )

    def test_text_block_list_reports_invalid_line(self):
        with self.assertRaisesRegex(ValueError, "line 2"):
            dr.parse_site_list_text("youtube.com\nnot a domain\n")


class ScheduleTests(unittest.TestCase):
    def test_daytime_boundaries(self):
        windows = [{"days": [0, 1, 2, 3, 4], "start": "09:00", "end": "18:00"}]
        self.assertFalse(dr.in_window(datetime(2026, 7, 13, 8, 59), windows))
        self.assertTrue(dr.in_window(datetime(2026, 7, 13, 9, 0), windows))
        self.assertTrue(dr.in_window(datetime(2026, 7, 13, 17, 59), windows))
        self.assertFalse(dr.in_window(datetime(2026, 7, 13, 18, 0), windows))

    def test_overnight_and_week_rollover(self):
        monday_night = [{"days": [0], "start": "22:00", "end": "06:00"}]
        self.assertTrue(dr.in_window(datetime(2026, 7, 13, 22, 0), monday_night))
        self.assertTrue(dr.in_window(datetime(2026, 7, 14, 5, 59), monday_night))
        self.assertFalse(dr.in_window(datetime(2026, 7, 14, 6, 0), monday_night))

        sunday_night = [{"days": [6], "start": "22:00", "end": "06:00"}]
        self.assertTrue(dr.in_window(datetime(2026, 7, 13, 5, 59), sunday_night))

    def test_parse_schedule(self):
        parsed = dr.parse_schedule("Mon-Fri 09:00-18:00; Sat,Sun 22:00-06:00")
        self.assertEqual(parsed[0]["days"], [0, 1, 2, 3, 4])
        self.assertEqual(parsed[1]["days"], [5, 6])

    def test_override_and_next_transition(self):
        schedule = {
            "enabled": True,
            "windows": [{"days": [0], "start": "09:00", "end": "18:00"}],
        }
        now = datetime(2026, 7, 13, 10, 0)
        self.assertTrue(dr.schedule_blocking_at(now, schedule))
        self.assertFalse(
            dr.schedule_blocking_at(now, schedule, datetime(2026, 7, 13, 18, 0))
        )
        self.assertEqual(
            dr.next_schedule_transition(now, schedule),
            datetime(2026, 7, 13, 18, 0),
        )


class ConfigTests(unittest.TestCase):
    def test_v1_config_migrates_and_schedule_state_is_derived(self):
        legacy = {
            "sites": ["youtu.be", "youtube.com"],
            "manual_blocking": False,
            "scheduled_blocking": False,
            "schedule": {
                "enabled": True,
                "windows": [{"days": [0], "start": "09:00", "end": "18:00"}],
            },
        }
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "config.json")
            with open(path, "w", encoding="utf-8") as handle:
                import json
                json.dump(legacy, handle)
            cfg = dr.load_config(path, now=datetime(2026, 7, 13, 10, 0))
            self.assertEqual(cfg["schema_version"], 2)
            self.assertEqual(cfg["sites"], ["youtube.com"])
            self.assertTrue(cfg["scheduled_blocking"])

            dr.save_config(cfg, path)
            with open(path, encoding="utf-8") as handle:
                saved = json.load(handle)
            self.assertNotIn("scheduled_blocking", saved)
            self.assertNotIn("blocking", saved)
            self.assertIn("manual_enabled", saved)

    def test_corrupt_json_is_reported_without_overwriting_the_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "config.json")
            damaged = "{ this is not valid json"
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(damaged)

            with self.assertRaises(dr.ConfigLoadError):
                dr.load_config(path)

            with open(path, encoding="utf-8") as handle:
                self.assertEqual(handle.read(), damaged)

    def test_malformed_config_shapes_are_reported(self):
        malformed = [
            [],
            {"sites": 7},
            {"sites": ["not a domain"]},
            {"schedule": {"enabled": True, "windows": 7}},
            {
                "schedule": {
                    "enabled": True,
                    "windows": [{"days": [9], "start": "09:00", "end": "18:00"}],
                }
            },
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "config.json")
            for payload in malformed:
                with self.subTest(payload=payload):
                    with open(path, "w", encoding="utf-8") as handle:
                        __import__("json").dump(payload, handle)
                    with self.assertRaises(dr.ConfigLoadError):
                        dr.load_config(path)

    def test_reset_corrupt_config_backs_up_original_and_creates_defaults(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "config.json")
            damaged = "{ broken"
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(damaged)

            cfg, backup = dr.reset_corrupt_config(path, now=datetime(2026, 7, 13, 10, 0))

            self.assertTrue(os.path.exists(backup))
            with open(backup, encoding="utf-8") as handle:
                self.assertEqual(handle.read(), damaged)
            self.assertEqual(cfg["schema_version"], dr.CONFIG_SCHEMA_VERSION)
            self.assertEqual(cfg["sites"], [])
            self.assertFalse(cfg["manual_enabled"])
            self.assertEqual(dr.load_config(path)["sites"], [])

    def test_reset_corrupt_config_restores_original_when_save_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "config.json")
            damaged = "{ broken"
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(damaged)

            def fail_save(*args, **kwargs):
                raise OSError("disk full")

            with self.assertRaises(OSError):
                dr.reset_corrupt_config(path, save_fn=fail_save)

            with open(path, encoding="utf-8") as handle:
                self.assertEqual(handle.read(), damaged)
            self.assertEqual(
                [name for name in os.listdir(directory) if ".corrupt-" in name],
                [],
            )

    def test_runtime_status_is_written_atomically(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "runtime-state.json")
            payload = {"apply_status": "retrying", "retry_count": 2}
            dr.save_runtime_status(payload, path)
            with open(path, encoding="utf-8") as handle:
                self.assertEqual(__import__("json").load(handle), payload)
            self.assertFalse(os.path.exists(path + ".tmp"))

    def test_hosts_backup_preserves_exact_bytes_and_is_private(self):
        with tempfile.TemporaryDirectory() as directory:
            source = os.path.join(directory, "hosts")
            backup_dir = os.path.join(directory, "backups")
            content = b"127.0.0.1 localhost\n10.0.0.2 internal.test\n"
            with open(source, "wb") as handle:
                handle.write(content)

            backup = dr.backup_hosts_file(source, backup_dir)

            with open(backup, "rb") as handle:
                self.assertEqual(handle.read(), content)
            self.assertEqual(stat.S_IMODE(os.stat(backup_dir).st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(os.stat(backup).st_mode), 0o600)

    def test_terminal_hosts_editor_uses_fixed_nano_command(self):
        completed = mock.Mock(returncode=0, stdout="", stderr="")
        with mock.patch.object(dr.subprocess, "run", return_value=completed) as run:
            result = dr.launch_hosts_terminal_editor(
                path="/etc/hosts",
                backup_path="/tmp/hosts backup",
            )

        self.assertIs(result, completed)
        command = run.call_args.args[0]
        self.assertEqual(command[:2], ["/usr/bin/osascript", "-e"])
        self.assertIn("sudo /usr/bin/nano /etc/hosts", command[2])
        self.assertIn("hosts backup", command[2])


class ReconcileTests(unittest.TestCase):
    def test_transient_failure_is_retried_on_next_reconcile(self):
        state = {"hosts": "127.0.0.1 localhost\n", "attempts": 0}
        cfg = {
            "sites": ["example.com"],
            "manual_enabled": True,
            "schedule": {"enabled": False, "windows": []},
            "schedule_override_until": None,
        }

        def read_hosts():
            return state["hosts"]

        def apply_change():
            state["attempts"] += 1
            if state["attempts"] == 1:
                raise RuntimeError("temporary failure")
            state["hosts"] = dr.render_hosts(state["hosts"], cfg)

        with self.assertRaises(RuntimeError):
            dr.reconcile_once(cfg, read_hosts, apply_change)
        dr.reconcile_once(cfg, read_hosts, apply_change)
        self.assertEqual(state["attempts"], 2)
        self.assertTrue(dr.hosts_match_config(state["hosts"], cfg))

    def test_config_save_failure_becomes_retryable_app_error(self):
        class FakeApp:
            cfg = {
                "sites": [],
                "manual_enabled": False,
                "schedule": {"enabled": False, "windows": []},
                "schedule_override_until": None,
            }
            actual_blocking = False
            apply_status = "pending"
            last_error = ""
            retry_count = 0
            next_retry_at = 0.0
            last_verify_at = 0.0
            _last_failure_cancelled = False
            config_load_error = ""

            def rebuild(self):
                pass

            def _read_actual_state(self):
                return "127.0.0.1 localhost\n"

            def _mark_failure(self, error):
                return dr.DistractorRemover._mark_failure(self, error)

            def _record_runtime_status(self):
                pass

        app = FakeApp()
        with mock.patch.object(
            dr, "reconcile_once", return_value="127.0.0.1 localhost\n"
        ), mock.patch.object(dr, "save_config", side_effect=OSError("disk full")):
            result = dr.DistractorRemover._reconcile(app, "test")

        self.assertFalse(result)
        self.assertEqual(app.apply_status, "retrying")
        self.assertIn("disk full", app.last_error)


class HelperHealthTests(unittest.TestCase):
    def test_v2_remains_usable_but_requests_recovery_upgrade(self):
        completed = __import__("subprocess").CompletedProcess(
            args=[], returncode=0, stdout="ready 2\n", stderr=""
        )
        with mock.patch.object(dr, "helper_file_valid", return_value=True), mock.patch.object(
            dr.subprocess, "run", return_value=completed
        ):
            self.assertEqual(dr.installed_helper_version(), "2")
            self.assertTrue(dr.helper_ready())
            self.assertTrue(dr.helper_needs_upgrade())

    def test_unknown_helper_version_is_not_accepted(self):
        completed = __import__("subprocess").CompletedProcess(
            args=[], returncode=0, stdout="ready 99\n", stderr=""
        )
        with mock.patch.object(dr, "helper_file_valid", return_value=True), mock.patch.object(
            dr.subprocess, "run", return_value=completed
        ):
            self.assertFalse(dr.helper_ready())


if __name__ == "__main__":
    unittest.main()

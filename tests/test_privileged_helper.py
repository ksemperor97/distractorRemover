import os
import subprocess
import sys
import tempfile
import unittest


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

import distractor_remover as dr


class PrivilegedHelperTests(unittest.TestCase):
    def _run(self, hosts_path, action, payload=""):
        env = os.environ.copy()
        env["DISTRACTORREMOVER_TEST_HOSTS"] = hosts_path
        return subprocess.run(
            [os.path.join(ROOT, "privileged_helper.sh"), action],
            input=payload,
            capture_output=True,
            text=True,
            env=env,
        )

    def test_helper_version_includes_reset_capability(self):
        result = subprocess.run(
            [os.path.join(ROOT, "privileged_helper.sh"), "--version"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), dr.HELPER_VERSION)

    def test_apply_and_clear_manage_only_marked_section(self):
        base = "127.0.0.1 localhost\n10.0.0.2 internal.test\n"
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "hosts")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(base)

            applied = self._run(path, "--apply", "youtube.com\nwww.youtube.com\n")
            self.assertEqual(applied.returncode, 0, applied.stderr)
            with open(path, encoding="utf-8") as handle:
                content = handle.read()
            # Compare exact helper output using the supplied domains rather than presets.
            expected = dr.strip_marked(base).rstrip("\n") + "\n"
            expected += dr.build_block_text(["youtube.com", "www.youtube.com"]) + "\n"
            self.assertEqual(content, expected)

            cleared = self._run(path, "--clear")
            self.assertEqual(cleared.returncode, 0, cleared.stderr)
            with open(path, encoding="utf-8") as handle:
                self.assertEqual(handle.read(), base)

    def test_incomplete_marker_is_rejected_without_modification(self):
        broken = "127.0.0.1 localhost\n" + dr.MARK_START + "\n"
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "hosts")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(broken)
            result = self._run(path, "--clear")
            self.assertNotEqual(result.returncode, 0)
            with open(path, encoding="utf-8") as handle:
                self.assertEqual(handle.read(), broken)

    def test_reset_repairs_incomplete_marker_and_creates_backup(self):
        broken = (
            "127.0.0.1 localhost\n"
            + dr.MARK_START
            + "\n127.0.0.1\texample.com\n::1\texample.com\n"
            + "10.0.0.2 internal.test\n"
        )
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "hosts")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(broken)

            result = self._run(path, "--reset")

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("backup:", result.stdout)
            with open(path, encoding="utf-8") as handle:
                repaired = handle.read()
            self.assertNotIn(dr.MARK_START, repaired)
            self.assertNotIn("example.com", repaired)
            self.assertIn("10.0.0.2 internal.test", repaired)
            backups = [
                name for name in os.listdir(directory)
                if name.startswith("hosts.distractorremover-backup-")
            ]
            self.assertEqual(len(backups), 1)
            with open(os.path.join(directory, backups[0]), encoding="utf-8") as handle:
                self.assertEqual(handle.read(), broken)


if __name__ == "__main__":
    unittest.main()

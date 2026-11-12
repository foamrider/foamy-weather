"""Bound clipboard producers in real subprocesses (on the kit's stand-ins,
hostenv.clipboard_fakes()) and exercise the QML editor."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
KIT = Path(os.environ.get("FOAMY_KIT", Path.home() / "GitHub/Personal/foamy-kit"))
HELPER = ROOT / "kit/clipboard.sh"
# hostenv comes from the kit checkout (it is not synced); GitHub's runner has none.
HOSTENV = KIT / "preview/hostenv.py"


def load_hostenv(case):
    if not HOSTENV.exists():
        case.skipTest(f"foamy-kit not found at {KIT} (set FOAMY_KIT): hostenv.clipboard_fakes() is the kit's")
    if str(KIT / "preview") not in sys.path:
        sys.path.insert(0, str(KIT / "preview"))
    import hostenv

    return hostenv


class SettingsTests(unittest.TestCase):
    def test_settings_use_safe_editor(self):
        settings = (ROOT / "WeatherSettings.qml").read_text()
        editor = (ROOT / "kit/SafeTextField.qml").read_text()
        self.assertIn("SafeTextField {", settings)
        self.assertNotIn("Controls.TextField {", settings)
        self.assertIn("Controls.TextArea.flickable", editor)
        self.assertNotIn("editor.paste()", editor)
        self.assertNotIn("editor.canPaste", editor)


class ClipboardTests(unittest.TestCase):
    def setUp(self):
        self.hostenv = load_hostenv(self)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        # The kit's wl-paste/clipboard-fixture stand-ins, and a timeout(1)
        # that keeps clipboard.sh's 2 s only for the modes whose outcome is
        # that deadline, so a loaded machine can't fail a paste that works.
        self.env = dict(os.environ, **self.hostenv.clipboard_fakes(self.base / "bin"))
        self.state = Path(self.env["TEST_CLIPBOARD_STATE"])

    def read(self, mode, selection="clipboard"):
        self.state.write_text(mode)
        deadline = mode in self.hostenv.CLIPBOARD_DEADLINE_MODES
        started = time.monotonic()
        result = subprocess.run(
            ["bash", str(HELPER), selection], env=self.env, capture_output=True, timeout=10 if deadline else 90
        )
        if deadline:
            self.assertLess(time.monotonic() - started, 4)
        self.assertLessEqual(len(result.stdout), 100000)
        return result

    def test_unicode_empty_and_limit(self):
        for mode, expected in (("unicode", "/home/test/Blåbær 📁"), ("empty", ""), ("limit", "x" * 16384)):
            with self.subTest(mode=mode):
                result = self.read(mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), expected)

    def test_primary_selection_and_single_line(self):
        result = self.read("lines", "primary")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), "one  two three")
        args = json.loads(Path(str(self.state) + ".args").read_text())
        self.assertEqual(args, ["--no-newline", "--type", "text", "--primary"])

    def test_oversized_nul_and_continuous_stream_are_rejected(self):
        for mode in ("large", "nul", "stream"):
            with self.subTest(mode=mode):
                result = self.read(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")
                self.assertEqual(result.stderr, b"")

    def test_total_deadline_covers_stalled_and_slow_sources(self):
        for mode in ("stall", "slow"):
            with self.subTest(mode=mode):
                result = self.read(mode)
                self.assertEqual(result.returncode, 137)

    def test_failure_and_invalid_selection(self):
        self.assertNotEqual(self.read("failure").returncode, 0)
        self.assertEqual(self.read("normal", "invalid").returncode, 2)

    def test_producer_ignoring_term_is_killed(self):
        result = self.read("ignore")
        self.assertEqual(result.returncode, 137)
        self.assert_producer_stopped()

    def assert_producer_stopped(self):
        pid = Path(str(self.state) + ".pid").read_text()
        status = Path(f"/proc/{pid}/stat")
        # The group leader can close stdout before a killed child is scheduled
        # to exit. Observe the child's state with a bounded wait, without the
        # exists/read race when /proc removes it between those two operations.
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline:
            try:
                state = status.read_text().split()[2]
            except (FileNotFoundError, ProcessLookupError):  # gone before the open, or before the read
                return
            if state == "Z":
                return
            time.sleep(0.01)
        self.fail("clipboard producer survived its deadline")

    def test_watchdog_survives_wrapper_destruction(self):
        self.state.write_text("stall")
        with subprocess.Popen(
            ["bash", str(HELPER), "clipboard"], env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        ) as process:
            pid_file = Path(str(self.state) + ".pid")
            deadline = time.monotonic() + 2
            while not pid_file.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(pid_file.exists(), "clipboard producer did not start")
            process.kill()
            process.communicate(timeout=4)
        self.assert_producer_stopped()

    def test_qml_editing_and_paste(self):
        runner = shutil.which("qs")
        if not runner or os.environ.get("FOAMY_TESTS_NO_QUICKSHELL"):
            self.skipTest("Quickshell is unavailable or not wanted (tests/suite.sh --ci)")

        # Quickshell's statically registered Io plugin requires the qs executable.
        # A stock qmltestrunner cannot load it as a dynamic QML plugin.
        for name in ("Commons", "Ui"):
            (self.base / name).symlink_to("/usr/share/omarchy/shell/" + name, target_is_directory=True)
        fixture = self.base / "shell.qml"
        fixture.write_text(
            """import QtQuick
import Quickshell
ShellRoot {
    FloatingWindow {
        title: "Foamy clipboard tests"
        visible: true
        implicitWidth: 500
        implicitHeight: 250
        Loader { anchors.fill: parent; source: %s }
    }
}
"""
            % json.dumps(str(ROOT / "tests/tst_clipboard.qml"))
        )
        runtime = self.base / "runtime"
        runtime.mkdir(mode=0o700)
        platform = os.environ.get("FOAMY_TEST_PLATFORM", "offscreen")
        # The kit's isolation (no Omarchy bin dir, system bus, audio server or
        # session bus: the editor needs none of them). The wayland mode keeps
        # the compositor on purpose.
        env = self.hostenv.isolate(dict(self.env), self.base, display=platform == "wayland")
        env.update(
            QT_QPA_PLATFORM=platform,
            QT_QUICK_BACKEND="software",
            QT_QPA_PLATFORMTHEME="",
            XDG_RUNTIME_DIR=str(runtime),
        )
        if platform == "wayland":
            # Keep test logs/IPC private without hiding the host compositor socket.
            display = Path(os.environ["WAYLAND_DISPLAY"])
            if not display.is_absolute():
                env["WAYLAND_DISPLAY"] = str(Path(os.environ["XDG_RUNTIME_DIR"]) / display)
        log = self.base / "qs.log"
        # Its own process group: stopping it also stops the clipboard.sh runs
        # its Processes started. The test quits by itself; 120 s is a hang guard.
        with (
            log.open("w") as out,
            self.hostenv.ProcessGroup(
                [runner, "-p", str(fixture), "--no-color"], env=env, stdout=out, stderr=subprocess.STDOUT
            ) as shell,
        ):
            status = shell.wait(120)
        output = log.read_text(errors="replace")
        self.assertEqual(status, 0, output)
        self.assertRegex(output, r"CLIPBOARD_RESULT passed=[1-9][0-9]* failed=0")
        self.assertIn("failed=0", output, output)
        print(output[output.index("CLIPBOARD_RESULT") :].splitlines()[0])


if __name__ == "__main__":
    unittest.main()

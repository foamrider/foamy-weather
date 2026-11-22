"""Exercise the QML editor (tests/tst_clipboard.qml) on the kit's clipboard
stand-ins, hostenv.clipboard_fakes()."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
KIT = Path(os.environ.get("FOAMY_KIT", Path.home() / "GitHub/Personal/foamy-kit"))
# hostenv comes from the kit checkout (it is not synced); GitHub's runner has none.
HOSTENV = KIT / "preview/hostenv.py"


def load_hostenv(case):
    if not HOSTENV.exists():
        case.skipTest(f"foamy-kit not found at {KIT} (set FOAMY_KIT): hostenv.clipboard_fakes() is the kit's")
    if str(KIT / "preview") not in sys.path:
        sys.path.insert(0, str(KIT / "preview"))
    import hostenv

    return hostenv


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

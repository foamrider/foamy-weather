"""Exercise the production location form against disposable clipboard and geocoder fixtures."""
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest
from test_clipboard import MOCK

ROOT = Path(__file__).resolve().parents[1]


class LocationUI(unittest.TestCase):
    def test_location_clipboard_navigation_save_and_lifecycle(self):
        if not os.environ.get("WAYLAND_DISPLAY"):
            self.skipTest("An active Wayland compositor is required")
        # Retain captures for visual review without changing the live configuration.
        base = Path(tempfile.mkdtemp(prefix="weather-location-ui-"))
        app = base / "app"
        app.mkdir()
        for name in ("Commons", "Ui"):
            (app / name).symlink_to("/usr/share/omarchy/shell/" + name, target_is_directory=True)
        (app / "plugin").symlink_to(ROOT, target_is_directory=True)
        home = base / "home"
        (home / ".config/omarchy").mkdir(parents=True)
        cli = base / "bin"
        cli.mkdir()
        state = base / "clipboard-state"
        state.write_text("normal")
        for name in ("wl-paste", "clipboard-fixture"):
            file = cli / name
            file.write_text(MOCK)
            file.chmod(0o755)
        # No test request reaches an external service. Only the real geocode
        # debounce, response parser and location-save helper are exercised.
        curl = cli / "curl"
        curl.write_text('''#!/bin/bash
case "$*" in
  *geocoding-api*) printf '%s\\n' '{"results":[{"name":"Bergen","latitude":60.39,"longitude":5.32,"country":"Norway"},{"name":"Bergen County","latitude":40.94,"longitude":-74.07,"country":"United States"}]}' ;;
  *) exit 22 ;;
esac
''')
        curl.chmod(0o755)
        (app / "shell.qml").write_text('''pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "plugin" as Plugin
ShellRoot {
  id: root
  Component.onCompleted: {
    Color.shellValues = ({});
    Color.background = "#24273a"; Color.foreground = "#cad3f5";
    Color.accent = "#8aadf4"; Color.urgent = "#ee99a0";
  }
  Process { id: fixture; property bool done: false; onExited: done = true }
  PanelWindow {
    id: window
    visible: true
    screen: Quickshell.screens[0]
    implicitHeight: 32
    anchors { top: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "foamy-weather-clipboard-test"
    color: Color.background
    Item {
      id: bar
      width: parent.width; height: 32
      property string position: "top"
      property int barSize: 32
      property string fontFamily: "sans-serif"
      property color foreground: Color.foreground
      property color barForeground: Color.foreground
      property color urgent: Color.urgent
      property bool vertical: false
      property bool hideLabels: false
      property bool foregroundAnimationEnabled: false
      property var activePopout: false
      function requestPopout(key) { activePopout = key }
      function releasePopout(key) { if (activePopout === key) activePopout = false }
      Plugin.Panel {
        id: panel
        bar: bar
        anchorItem: anchor
        settings: ({automaticLocation: false, animateBackground: false})
      }
      Item { id: anchor; x: 200; width: 32; height: 32 }
    }
    property bool ready: false
    Timer { interval: 300; running: true; onTriggered: window.ready = true }
    TestCase {
      parent: panel.locationField || bar
      name: "WeatherLocationClipboard"
      when: window.ready
      function source(mode) {
        fixture.command = ["clipboard-fixture", mode]; fixture.done = false; fixture.running = true;
        tryCompare(fixture, "done", true);
      }
      function input() {
        panel.open(); panel.startEditingLocation();
        tryVerify(function() { return panel.locationField !== null && panel.locationField.visible });
        var field = panel.locationField;
        wait(200); field.focusInput(); tryCompare(field, "inputActiveFocus", true);
        return field;
      }
      function capture(item, name) {
        var done = false;
        item.grabToImage(function(result) {
          verify(result.saveToFile(Qt.resolvedUrl(name + ".png").toString().replace("file://", "")));
          done = true;
        });
        tryVerify(function() { return done });
      }
      function cleanup() { if(qtest_results.failed) console.error("LOCATION_FAIL", qtest_results.functionName, "field", panel.locationField ? panel.locationField.text : "null", "error", panel.settingsError, "suggestions", JSON.stringify(panel.locationSuggestions)); panel.close(); wait(200); }
      function test_01_debounce_navigation_and_save() {
        var field = input();
        source("normal"); keyClick(Qt.Key_V, Qt.ControlModifier);
        tryCompare(field, "pasteRunning", false);
        compare(field.text, "folder");
        compare(panel.searchCompleted, false);
        tryCompare(panel, "searchCompleted", true);
        compare(panel.locationSuggestions.length, 2);
        keyClick(Qt.Key_Down); compare(panel.suggestionIndex, 1);
        keyClick(Qt.Key_Up); compare(panel.suggestionIndex, 0);
        keyClick(Qt.Key_Return);
        tryVerify(function() { return !panel.savingLocation && panel.localLocationState.name === "Bergen" });
        compare(panel.localLocationState.latitude, 60.39);
        compare(panel.localLocationState.longitude, 5.32);
        compare(field.text, "");
      }
      function test_02_errors_and_cancelled_pastes() {
        var field = input();
        field.text = "keep"; field.cursorPosition = 4;
        source("large"); keyClick(Qt.Key_V, Qt.ControlModifier);
        tryCompare(field, "pasteRunning", false);
        compare(field.text, "keep"); verify(field.pasteError.length > 0);
        compare(panel.settingsError, field.pasteError);
        keyClick(Qt.Key_X); compare(panel.settingsError, "");
        source("delayed"); keyClick(Qt.Key_V, Qt.ControlModifier);
        keyClick(Qt.Key_Escape); compare(panel.editingLocation, false);
        wait(600); compare(field.text, "keepx"); compare(field.pasteError, "");
        field = input(); compare(field.pasteError, ""); compare(panel.settingsError, "");
        source("stall"); keyClick(Qt.Key_V, Qt.ControlModifier);
        panel.close(); wait(1200);
        compare(panel.settingsContentActive, false); compare(panel.locationField, null);
      }
      function test_03_visual_and_keyboard_focus() {
        var field = input(), pane = field.parent.parent;
        var card = pane;
        while (card && !("contentLeftInset" in card)) card = card.parent;
        verify(card !== null);
        field.text = "Bergen"; field.cursorPosition = field.text.length;
        var editor = findChild(field, "safeEditor");
        verify(editor !== null);
        wait(200);
        verify(editor.cursorRectangle.y + editor.cursorRectangle.height <= field.height);
        compare(field.height, 30);
        capture(card, "location-wide-dark");
        // Adjust the fixture's form width; production responsive Grid bindings
        // still choose one column at the actual narrow form width.
        card.width = 320; wait(200); capture(card, "location-narrow-dark");
        Color.background = "#eff1f5"; Color.foreground = "#4c4f69";
        Color.accent = "#1e66f5"; Color.urgent = "#d20f39";
        wait(200); capture(card, "location-narrow-light");
        card.width = 600; wait(200); capture(card, "location-wide-light");
        field.pasteError = "Clipboard text is too large or contains invalid characters.";
        wait(100); capture(card, "location-paste-error");
        field.focusInput(); keyClick(Qt.Key_Tab); tryCompare(field, "inputActiveFocus", false);
      }
      onCompletedChanged: if (completed) {
        console.log("WEATHER_LOCATION_UI", qtest_results.passCount, "passed", qtest_results.failCount, "failed");
      }
    }
  }
}
''')
        env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / ".config"),
                   XDG_CACHE_HOME=str(home / ".cache"), XDG_STATE_HOME=str(home / ".local/state"),
                   PATH=str(cli) + ":" + os.environ["PATH"], TEST_CLIPBOARD_STATE=str(state),
                   QT_QPA_PLATFORM="wayland", QT_QUICK_BACKEND="rhi", QT_QPA_PLATFORMTHEME="basic",
                   QT_NO_XDG_DESKTOP_PORTAL="1", OMARCHY_PATH="/usr/share/omarchy")
        process = subprocess.Popen(["dbus-run-session", "--", "qs", "-p", str(app), "--no-color"],
                                   env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, start_new_session=True)
        try:
            output = process.communicate(timeout=35)[0]
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            output = process.communicate(timeout=3)[0]
        print(output)
        print("Location captures:", app)
        self.assertEqual(process.returncode, 0, output)
        self.assertIn("WEATHER_LOCATION_UI 4 passed 0 failed", output)
        self.assertEqual(json.loads((home / ".config/omarchy/weather-location.local.json").read_text()),
                         {"name": "Bergen", "latitude": 60.39, "longitude": 5.32})


if __name__ == "__main__":
    unittest.main()

"""The location search in the real Panel, offscreen on Omarchy 4.5 (foamy-kit
harness), with the real helper against the loopback stand-in for Open-Meteo
(tests/fakenet.py): a search cancelled by further typing must not report its
own end (killed, no output) as a failed search, also when the new text trims
to the same query (a trailing space), and the search that replaces it shows
its results without an error.

  python3 tests/search-runtime.py

Needs foamy-kit (FOAMY_KIT, default ~/GitHub/Personal/foamy-kit) and openssl.
Temporary HOME/XDG dirs; nothing is sent to the real services.
"""
import os
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KIT = Path(os.environ.get("FOAMY_KIT", Path.home() / "GitHub/Personal/foamy-kit"))
os.environ.setdefault("FOAMY_HOST_45", "/usr/share/omarchy/shell")
sys.path.insert(0, str(KIT / "preview"))
sys.path.insert(0, str(ROOT / "tests"))
import fakenet  # noqa: E402
import harness  # noqa: E402

# Each search answers after this delay, so the first is still running when
# the text changes. The steps below wait on conditions, not on this.
SEARCH_DELAY = 1.5

SHELL = r'''
import QtQuick
import Quickshell
import "harness"
import "plugin" as Weather

ShellRoot {
  id: shell
  property int failures: 0
  property int step: 0
  property var widget: null
  // Condition waits with one generous limit for the whole run (a loaded
  // machine is slow, not wrong).
  property real started: Date.now()
  function check(ok, what) { if (!ok) { failures++; console.log("FOAMY FAIL " + what) } else console.log("FOAMY OK " + what) }
  function finish() {
    console.log(shell.failures === 0 ? "FOAMY DONE" : "FOAMY FAIL " + shell.failures + " failures")
    Qt.quit()
  }

  MockBar { id: bar }
  Item { id: holder }

  Component.onCompleted: {
    // NetworkManager is the host's: keep the network "settling" so no
    // forecast is fetched. The search does not wait for it.
    Weather.WeatherService.networkSettleTimer.interval = 24 * 60 * 60 * 1000
    var component = Qt.createComponent(Qt.resolvedUrl("plugin/BarWidget.qml"))
    if (component.status !== Component.Ready) { console.log("FOAMY FAIL load " + component.errorString()); Qt.quit(); return }
    widget = component.createObject(holder, { bar: bar, moduleName: "foamy.weather", settings: { id: "foamy.weather" } })
    tick.start()
  }

  Timer {
    id: tick
    interval: 50
    repeat: true
    onTriggered: {
      var a = shell.widget ? shell.widget.panel : null
      if (Date.now() - shell.started > 40000) {
        shell.check(false, "timed out at step " + shell.step + ": searching " + (a && a.searching)
          + ", error " + JSON.stringify(a && a.settingsError))
        shell.finish()
        return
      }
      if (!a) return
      switch (shell.step) {
      case 0:
        a.startEditingLocation()
        a.searchEdited("Oslo")
        shell.step++
        break
      case 1:
        // The first search is under way: type a space after the word.
        if (!a.searching) return
        a.searchEdited("Oslo ")
        shell.step++
        break
      case 2:
        // The cancelled search has ended and its replacement has run.
        if (a.searching || !a.searchCompleted) return
        shell.check(a.settingsError === "", "a cancelled search is not reported as failed: " + JSON.stringify(a.settingsError))
        shell.check(a.locationSuggestions.length === 1 && a.locationSuggestions[0].name === "Oslo",
          "the new search shows its results: " + JSON.stringify(a.locationSuggestions))
        a.searchEdited("Bergen")
        shell.step++
        break
      case 3:
        if (!a.searching) return
        // Clearing the field cancels the search; its end changes nothing.
        a.searchEdited("")
        shell.step++
        break
      case 4:
        if (a.searching) return
        shell.check(a.settingsError === "" && a.locationSuggestions.length === 0 && !a.searchCompleted,
          "a search cancelled by clearing leaves no error or results: " + JSON.stringify(a.settingsError))
        shell.finish()
      }
    }
  }
}
'''


def slow_search(handler):
    time.sleep(SEARCH_DELAY)
    body = fakenet.SEARCH.encode()
    try:
        handler.send_response(200)
        handler.send_header('Content-Type', 'application/json')
        handler.send_header('Content-Length', str(len(body)))
        handler.send_header('Connection', 'close')
        handler.end_headers()
        handler.wfile.write(body)
    except OSError:
        pass  # the cancelled search's helper is gone
    handler.close_connection = True


def main():
    with tempfile.TemporaryDirectory(prefix="foamy-weather-search-") as certs_dir:
        certs = fakenet.make_certs(certs_dir)
        with fakenet.Server(certs, {'search': slow_search}) as server:
            run = harness.Run("4.5", SHELL, plugin=ROOT, prefix="foamy-weather-search-")
            run.env = fakenet.network_env(run.env, server.port, certs['ca'])
            run.run(timeout=60)
            searches = server.paths('search')
    checks = [line.split("FOAMY OK ", 1)[1] for line in run.log.splitlines() if "FOAMY OK " in line]
    if run.ok and len(searches) < 2:
        run.ok = False
        print(f"4.5: expected at least two searches at the stand-in, saw {len(searches)}")
    if run.ok:
        print(f"4.5: {len(checks)} search checks passed")
        run.cleanup()
        return 0
    print(f"4.5: FAILED (log {run.base}/qs.log)")
    print("\n".join(run.failures() or run.log.splitlines()[-30:]))
    return 1


if __name__ == "__main__":
    sys.exit(main())

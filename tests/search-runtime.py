"""The location search in the real Panel, offscreen on Omarchy 4.5 (foamy-kit
harness), with the real helper against the loopback stand-in for Open-Meteo
(tests/fakenet.py): a search cancelled by further typing must not report its
own end (killed, no output) as a failed search, also when the new text trims
to the same query (a trailing space), and the search that replaces it shows
its results without an error. The query reaches the helper on stdin, never in
its argv (read from /proc while the search runs).

  python3 tests/search-runtime.py

Needs foamy-kit (FOAMY_KIT, default ~/GitHub/Personal/foamy-kit), openssl,
dbus-daemon, dbus-python and PyGObject.
Temporary HOME/XDG dirs; nothing is sent to the real services.
"""

import json
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
import fake_nm  # noqa: E402
import fakenet  # noqa: E402
import harness  # noqa: E402

# Each search answers after this delay, so it is still running when the text
# changes. The steps below wait on conditions (the request has reached the
# stand-in), not on this.
SEARCH_DELAY = 1.5

SHELL = r"""
import QtQuick
import Quickshell
import Quickshell.Io
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
  // One line per search request that reached the stand-in.
  FileView { id: arrived; path: ARRIVED; blockLoading: true; printErrors: false }
  function arrivals() { arrived.reload(); return arrived.text().split("\n").length - 1 }

  Component.onCompleted: {
    // Offline (the kit's fake NetworkManager, main() below), so no forecast
    // is fetched; the search does not wait for the network.
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
        // The first search is at the stand-in: type a space after the word.
        if (!a.searching || shell.arrivals() < 1) return
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
        // The Bergen search (the third request) is at the stand-in.
        if (!a.searching || shell.arrivals() < 3) return
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
"""


# The argv of every foamy-weather-helper (and wrapper) seen during a search.
ARGVS = []
ARRIVED = None


def helper_argvs():
    found = []
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            argv = (entry / "cmdline").read_bytes().split(b"\0")
        except OSError:
            continue
        text = [part.decode(errors="replace") for part in argv if part]
        if any("foamy-weather-helper" in part for part in text):
            found.append(text)
    return found


def slow_search(handler):
    ARGVS.extend(helper_argvs())
    with ARRIVED.open("a") as log:
        log.write(handler.path + "\n")
    time.sleep(SEARCH_DELAY)
    body = fakenet.SEARCH.encode()
    try:
        handler.send_response(200)
        handler.send_header("Content-Type", "application/json")
        handler.send_header("Content-Length", str(len(body)))
        handler.send_header("Connection", "close")
        handler.end_headers()
        handler.wfile.write(body)
    except OSError:
        pass  # the cancelled search's helper is gone
    handler.close_connection = True


def main():
    global ARRIVED
    with tempfile.TemporaryDirectory(prefix="foamy-weather-search-") as certs_dir:
        certs = fakenet.make_certs(certs_dir)
        ARRIVED = Path(certs_dir) / "arrived"
        shell = SHELL.replace("ARRIVED", json.dumps(str(ARRIVED)))
        with fakenet.Server(certs, {"search": slow_search}) as server:
            run = harness.Run("4.5", shell, plugin=ROOT, prefix="foamy-weather-search-", system_bus="private")
            connectivity = run.base / "connectivity"
            fake_nm.set_connectivity(connectivity, fake_nm.NONE)
            run.env = fakenet.network_env(run.env, server.port, certs["ca"])
            # The fake goes on the bus before qs: Quickshell looks for
            # NetworkManager only once, at start.
            run.start_buses()
            with fake_nm.start(run.system_bus_address, connectivity):
                run.run(timeout=60)
            searches = server.paths("search")
    checks = [line.split("FOAMY OK ", 1)[1] for line in run.log.splitlines() if "FOAMY OK " in line]
    if run.ok and len(searches) != 3:
        run.ok = False
        print(f"4.5: expected three searches at the stand-in, saw {searches}")
    if run.ok and not any("geocode" in argv for argv in ARGVS):
        run.ok = False
        print(f"4.5: the search helper was not seen while it ran: {ARGVS}")
    if run.ok and any("Oslo" in part or "Bergen" in part for argv in ARGVS for part in argv):
        run.ok = False
        print(f"4.5: the query reached the helper's argv: {ARGVS}")
    if run.ok:
        print(f"4.5: {len(checks)} search checks passed")
        run.cleanup()
        return 0
    print(f"4.5: FAILED (log {run.base}/qs.log)")
    print("\n".join(run.failures() or run.log.splitlines()[-30:]))
    return 1


if __name__ == "__main__":
    sys.exit(main())

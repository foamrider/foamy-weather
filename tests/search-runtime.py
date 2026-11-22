"""The location search in the real Panel, offscreen on Omarchy 4.5 (foamy-kit
harness), with the real helper against the loopback stand-in for Open-Meteo
(tests/fakenet.py): a search cancelled by further typing must not report its
own end (killed, no output) as a failed search, also when the new text trims
to the same query (a trailing space), and the search that replaces it shows
its results without an error. Enter saves the chosen place through the
helper into an owner-only state file, which the service then reads. A search
the server refuses says so. The query reaches the helper on stdin, never in
its argv (read from /proc while the search runs), and the Norwegian display
language asks for Norwegian place names. A cancelled search whose helper
is still exiting when the next search is due does not lose that search, and
text typed as that helper exits, before the queued search starts, replaces
it.

  python3 tests/search-runtime.py

Needs foamy-kit (FOAMY_KIT, default ~/GitHub/Personal/foamy-kit), openssl,
dbus-daemon, dbus-python and PyGObject.
Temporary HOME/XDG dirs; nothing is sent to the real services.
"""

import json
import os
import platform
import shlex
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
        // Enter saves the result under the cursor through the helper.
        a.commitLocation()
        shell.check(a.savingLocation, "Enter starts saving the chosen place")
        shell.step++
        break
      case 3:
        if (a.savingLocation || Weather.WeatherService.localLocationState.name !== "Oslo") return
        shell.check(a.settingsError === "" && a.locationSuggestions.length === 0 && a.searchText === "",
          "the saved place clears the search: " + JSON.stringify([a.settingsError, a.searchText]))
        shell.check(Weather.WeatherService.localLocationState.latitude === 59.91273, "the service reads the saved place: "
          + JSON.stringify(Weather.WeatherService.localLocationState))
        a.searchEdited("Bergen")
        shell.step++
        break
      case 4:
        // The Bergen search (the third request) is at the stand-in.
        if (!a.searching || shell.arrivals() < 3) return
        // Clearing the field cancels the search; its end changes nothing.
        a.searchEdited("")
        shell.step++
        break
      case 5:
        if (a.searching) return
        shell.check(a.settingsError === "" && a.locationSuggestions.length === 0 && !a.searchCompleted,
          "a search cancelled by clearing leaves no error or results: " + JSON.stringify(a.settingsError))
        // The stand-in refuses this one at once (main() below).
        a.searchEdited("Fail")
        shell.step++
        break
      case 6:
        if (a.searching || shell.arrivals() < 4 || a.settingsError === "") return
        shell.check(a.settingsError === "Could not search for a location" && !a.searchCompleted,
          "a refused search says so: " + JSON.stringify(a.settingsError))
        shell.finish()
      }
    }
  }
}
"""


# The same search, typed again (a trailing space) while the first search
# still runs, through a helper that is slow to stop: stopped, it exits only
# when the shell writes a line to the RELEASE FIFO. The release comes from a
# timer started with the typing and longer than the Panel's 300 ms search
# delay; Qt fires timers in deadline order, so the delayed search is due
# while the stopped helper still runs. Then once more, and new text is typed
# when the Panel sees the stopped helper exit (`searching` turns false). The
# delayed search is queued by then, and the Panel starts it only after the
# exit's signal handlers (Qt.callLater), so the new text comes first however
# late the helper exits: only the new text may be searched.
SLOW_STOP_SHELL = r"""
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
  property real started: Date.now()
  function check(ok, what) { if (!ok) { failures++; console.log("FOAMY FAIL " + what) } else console.log("FOAMY OK " + what) }
  function finish() {
    console.log(shell.failures === 0 ? "FOAMY DONE" : "FOAMY FAIL " + shell.failures + " failures")
    Qt.quit()
  }

  MockBar { id: bar }
  Item { id: holder }
  FileView { id: arrived; path: ARRIVED; blockLoading: true; printErrors: false }
  function arrivals() { arrived.reload(); return arrived.text().split("\n").length - 1 }
  function lastArrival() { arrived.reload(); var lines = arrived.text().split("\n"); return lines[lines.length - 2] || "" }
  FileView { id: stopping; path: STOPPING; blockLoading: true; printErrors: false }
  function stopped() { stopping.reload(); return stopping.text().length > 0 }
  Process { id: release; command: ["sh", "-c", "echo release >\"$1\"", "sh", RELEASE] }
  Timer { id: releaseLater; interval: 900; onTriggered: release.running = true }
  // The second round types Bergen as the Panel sees the stopped helper exit.
  Connections {
    target: shell.widget ? shell.widget.panel : null
    function onSearchingChanged() {
      if (shell.step === 5 && !shell.widget.panel.searching) {
        shell.widget.panel.searchEdited("Bergen")
        shell.step++
      }
    }
  }

  Component.onCompleted: {
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
          + ", arrivals " + shell.arrivals() + ", error " + JSON.stringify(a && a.settingsError))
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
        if (!a.searching || shell.arrivals() < 1) return
        a.searchEdited("Oslo ")
        releaseLater.start()
        shell.step++
        break
      case 2:
        // The stand-in got the stop and waits for RELEASE.
        if (!shell.stopped()) return
        shell.step++
        break
      case 3:
        // The delayed search has reached the stand-in and ended.
        if (a.searching || !a.searchCompleted || shell.arrivals() < 2) return
        shell.check(shell.arrivals() === 2, "one delayed search reached the stand-in: " + shell.arrivals())
        shell.check(a.settingsError === "" && a.locationSuggestions.length === 1 && a.locationSuggestions[0].name === "Oslo",
          "the delayed search shows its results: " + JSON.stringify([a.settingsError, a.locationSuggestions]))
        a.searchEdited("Trondheim")
        shell.step++
        break
      case 4:
        if (!a.searching || shell.arrivals() < 3) return
        // Queued behind the stopped helper, as in the first round; Bergen
        // is typed when the helper exits (Connections above).
        a.searchEdited("Trondheim ")
        releaseLater.start()
        shell.step++
        break
      case 5:
        return
      case 6:
        if (a.searching || !a.searchCompleted || !/[?&]name=Bergen&/.test(shell.lastArrival())) return
        arrived.reload()
        shell.check(shell.arrivals() === 4, "only the newly typed text was searched: " + JSON.stringify(arrived.text()))
        shell.finish()
      }
    }
  }
}
"""

# Runs the real helper; stopped while it runs geocode, it ends the real
# helper and then waits for a line on the release FIFO (at most 20 s).
SLOW_STOP_HELPER = """#!/bin/bash
real=(REAL)
[[ ${1-} == geocode ]] || exec "${real[@]}" "$@"
# Read-write, so that the open does not wait for a writer, and the shell's
# writer never waits for a reader.
exec 3<>RELEASE
"${real[@]}" "$@" <&0 3<&- &
child=$!
stopped() {
  kill "$child" 2>/dev/null
  echo stopped >STOPPING
  read -r -t 20 -u 3 _ || true
  exit 143
}
trap stopped TERM
wait "$child"
"""


# The argv of every foamy-weather-helper (and wrapper) of this run seen
# during a search.
ARGVS = []
ARRIVED = None
# This run's directory (main() sets it before the shell starts).
RUN_BASE = None


def helper_argvs():
    # Other runs and the live widget may run the helper too: a process counts
    # only when an argument lies under this run's directory.
    prefix = f"{RUN_BASE}/"
    found = []
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            argv = (entry / "cmdline").read_bytes().split(b"\0")
        except OSError:
            continue
        text = [part.decode(errors="replace") for part in argv if part]
        if any("foamy-weather-helper" in part for part in text) and any(part.startswith(prefix) for part in text):
            found.append(text)
    return found


def slow_search(handler):
    ARGVS.extend(helper_argvs())
    with ARRIVED.open("a") as log:
        log.write(handler.path + "\n")
    refused = "name=Fail&" in handler.path
    if not refused:
        time.sleep(SEARCH_DELAY)
    body = b"{}" if refused else fakenet.SEARCH.encode()
    try:
        handler.send_response(503 if refused else 200)
        handler.send_header("Content-Type", "application/json")
        handler.send_header("Content-Length", str(len(body)))
        handler.send_header("Connection", "close")
        handler.end_headers()
        handler.wfile.write(body)
    except OSError:
        pass  # the cancelled search's helper is gone
    handler.close_connection = True


def slow_stop(certs, certs_dir):
    """The scenario of SLOW_STOP_SHELL; True when it passed."""
    global ARRIVED
    work = Path(certs_dir) / "slow-stop"
    work.mkdir()
    ARRIVED = work / "arrived"
    stopping, release = work / "stopping", work / "release"
    os.mkfifo(release, 0o600)
    # The plugin with the stand-in in place of its helper.
    plugin = work / "plugin"
    plugin.mkdir()
    for entry in ROOT.iterdir():
        if entry.name != "bin":
            (plugin / entry.name).symlink_to(entry)
    stand_in = plugin / "bin" / platform.machine() / "foamy-weather-helper"
    stand_in.parent.mkdir(parents=True)
    real = " ".join(shlex.quote(part) for part in fakenet.helper_command("geocode")[:-1])
    stand_in.write_text(
        SLOW_STOP_HELPER.replace("REAL", real)
        .replace("STOPPING", shlex.quote(str(stopping)))
        .replace("RELEASE", shlex.quote(str(release)))
    )
    stand_in.chmod(0o755)
    shell = (
        SLOW_STOP_SHELL.replace("ARRIVED", json.dumps(str(ARRIVED)))
        .replace("STOPPING", json.dumps(str(stopping)))
        .replace("RELEASE", json.dumps(str(release)))
    )
    with fakenet.Server(certs, {"search": slow_search}) as server:
        run = harness.Run("4.5", shell, plugin=plugin, prefix="foamy-weather-search-", system_bus="private")
        connectivity = run.base / "connectivity"
        fake_nm.set_connectivity(connectivity, fake_nm.NONE)
        run.env = fakenet.network_env(run.env, server.port, certs["ca"])
        run.start_buses()
        with fake_nm.start(run.system_bus_address, connectivity):
            run.run(timeout=60)
    if run.ok:
        print("4.5: a search due while the stopped helper exits still runs")
        run.cleanup()
        return True
    print(f"4.5: slow stop FAILED (log {run.base}/qs.log)")
    print("\n".join(run.failures() or run.log.splitlines()[-30:]))
    return False


def main():
    global ARRIVED, RUN_BASE
    with tempfile.TemporaryDirectory(prefix="foamy-weather-search-") as certs_dir:
        certs = fakenet.make_certs(certs_dir)
        ARRIVED = Path(certs_dir) / "arrived"
        shell = SHELL.replace("ARRIVED", json.dumps(str(ARRIVED)))
        with fakenet.Server(certs, {"search": slow_search}) as server:
            # Norwegian (nb): the search must ask for Norwegian names (no).
            run = harness.Run(
                "4.5", shell, plugin=ROOT, prefix="foamy-weather-search-", system_bus="private", language="nb"
            )
            RUN_BASE = run.base
            connectivity = run.base / "connectivity"
            fake_nm.set_connectivity(connectivity, fake_nm.NONE)
            run.env = fakenet.network_env(run.env, server.port, certs["ca"])
            # The fake goes on the bus before qs: Quickshell looks for
            # NetworkManager only once, at start.
            run.start_buses()
            with fake_nm.start(run.system_bus_address, connectivity):
                run.run(timeout=60)
            searches = server.paths("search")
            saved = run.base / "home/.local/state/omarchy/settings/foamy-weather-location.json"
    checks = [line.split("FOAMY OK ", 1)[1] for line in run.log.splitlines() if "FOAMY OK " in line]
    if run.ok and len(searches) != 4:
        run.ok = False
        print(f"4.5: expected four searches at the stand-in, saw {searches}")
    if run.ok and not all("&language=no&" in path for path in searches):
        run.ok = False
        print(f"4.5: a search did not ask for Norwegian names: {searches}")
    # The helper is the only writer of the searched place: owner-only, exactly
    # the chosen result (it exits 2 on any extra argument, so the place must
    # have come on stdin).
    if run.ok and (
        not saved.exists()
        or json.loads(saved.read_text()) != {"name": "Oslo", "latitude": 59.91273, "longitude": 10.74609}
        or (saved.stat().st_mode & 0o777) != 0o600
    ):
        run.ok = False
        print(f"4.5: the chosen place was not saved privately: {saved.read_text() if saved.exists() else 'missing'}")
    if run.ok and not any("geocode" in argv for argv in ARGVS):
        run.ok = False
        print(f"4.5: the search helper was not seen while it ran: {ARGVS}")
    if run.ok and any("Oslo" in part or "Bergen" in part for argv in ARGVS for part in argv):
        run.ok = False
        print(f"4.5: the query reached the helper's argv: {ARGVS}")
    if run.ok:
        print(f"4.5: {len(checks)} search checks passed")
        run.cleanup()
    else:
        print(f"4.5: FAILED (log {run.base}/qs.log)")
        print("\n".join(run.failures() or run.log.splitlines()[-30:]))
    with tempfile.TemporaryDirectory(prefix="foamy-weather-search-") as certs_dir:
        slow_ok = slow_stop(fakenet.make_certs(certs_dir), certs_dir)
    return 0 if run.ok and slow_ok else 1


if __name__ == "__main__":
    sys.exit(main())

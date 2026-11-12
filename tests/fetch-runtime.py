"""The forecast fetch in the real WeatherService, offscreen on Omarchy 4.5
(foamy-kit harness), with the real helper against the loopback stand-in for
MET Norway (tests/fakenet.py). The network goes down and up through the
kit's fake NetworkManager (preview/fake_nm.py) on the run's private system
bus, which Quickshell's Networking reads:

- offline, nothing is fetched; when the network comes back, the place's
  forecast arrives;
- a new place keeps the previous report on screen while it loads;
- a place change during a running fetch stops that fetch, never applies its
  result or its end (no error, no retry), and fetches the new place instead;
- coordinates reach the helper on stdin only, never in its argv.

  python3 tests/fetch-runtime.py

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

# Three places; MET gets them rounded to three decimals.
PLACES = {
    "A": ("Place A", 61.123, 7.456),
    "B": ("Place B", 62.5, 8.25),
    "C": ("Place C", 63.75, 9.125),
}
# Place B's forecast answers after this delay, so its fetch is still running
# when the place changes again. The QML steps wait on conditions, not on it.
SLOW_DELAY = 4.0
# The shell logs this once it has checked the offline state; main() then
# brings the network up.
OFFLINE_CHECKED = "FOAMY OFFLINE CHECKED"

SHELL = r"""
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Networking
import "harness"
import "plugin" as Weather

ShellRoot {
  id: shell
  property int failures: 0
  property var widget: null
  // The query of every report the service took, and every error it showed.
  property var reports: []
  property var errors: []
  // How many times the forecast helper started.
  property int fetches: 0
  readonly property var s: Weather.WeatherService
  function check(ok, what) { if (!ok) { failures++; console.log("FOAMY FAIL " + what) } else console.log("FOAMY OK " + what) }
  function finish() {
    console.log(shell.failures === 0 ? "FOAMY DONE" : "FOAMY FAIL " + shell.failures + " failures")
    Qt.quit()
  }
  function query(place) { return String(place[1]) + "," + String(place[2]) }
  readonly property var places: PLACES

  MockBar { id: bar }
  Item { id: holder }
  FoamyWait { id: wait }
  // Written by the stand-in once place B's request has arrived.
  FileView { id: arrived; path: ARRIVED; blockLoading: true; printErrors: false }

  Connections {
    target: Weather.WeatherService
    function onReportChanged() {
      if (shell.s.report) shell.reports = shell.reports.concat([shell.s.report.query])
    }
    function onErrorMessageChanged() {
      if (shell.s.errorMessage) shell.errors = shell.errors.concat([shell.s.errorMessage])
    }
  }
  Connections {
    target: Weather.WeatherService.weatherProc
    function onRunningChanged() { if (shell.s.weatherProc.running) shell.fetches++ }
  }

  Component.onCompleted: {
    // The fake NetworkManager starts offline (main() below).
    s.networkSettleTimer.interval = 50
    var component = Qt.createComponent(Qt.resolvedUrl("plugin/BarWidget.qml"))
    if (component.status !== Component.Ready) { check(false, "load " + component.errorString()); finish(); return }
    widget = component.createObject(holder, { bar: bar, moduleName: "foamy.weather", settings: { id: "foamy.weather" } })
    // Place A is seeded in state (main() below) and read at start.
    wait.waitFor(function() { return s.coordinateQuery === query(places.A) && !s.locationMigrateProc.running }, 20000,
      offline, "the seeded place is read")
  }

  function offline(ok) {
    if (!ok) return finish()
    // Offline for longer than the (shortened) settle time: a fetch would
    // have started by now.
    wait.after(1000, function() {
      check(Networking.connectivity === NetworkConnectivity.None, "the fake NetworkManager reports offline: "
        + Networking.connectivity)
      check(!s.networkReady && shell.fetches === 0 && s.report === null, "offline: nothing is fetched: "
        + shell.fetches + " fetches")
      console.log("FOAMY OFFLINE CHECKED")
      wait.waitFor(function() { return s.reportCurrent && !s.loading }, 30000, firstReport,
        "the network comes back: place A's forecast arrives")
    })
  }

  function firstReport(ok) {
    if (!ok) return finish()
    check(s.report.locationName === "Place A" && s.errorMessage === "", "online: the place's forecast is shown: "
      + JSON.stringify([s.report.locationName, s.errorMessage]))
    s.localLocationState = { name: "Place B", latitude: places.B[1], longitude: places.B[2] }
    wait.waitFor(function() { arrived.reload(); return arrived.text() !== "" }, 30000, slowRunning,
      "place B's request reaches MET")
  }

  function slowRunning(ok) {
    if (!ok) return finish()
    check(s.weatherProc.running && s.weatherProc.query === query(places.B), "place B's fetch is running")
    check(s.report && s.report.query === query(places.A) && s.report.locationName === "Place A" && !s.reportCurrent,
      "the previous report stays while the new place loads")
    // Move on while B is still loading: its fetch is for the old place.
    s.localLocationState = { name: "Place C", latitude: places.C[1], longitude: places.C[2] }
    wait.waitFor(function() { return s.reportCurrent && !s.loading && !s.weatherProc.running }, 30000, lastReport,
      "place C's forecast arrives")
  }

  function lastReport(ok) {
    if (!ok) return finish()
    check(s.report.locationName === "Place C" && s.report.query === query(places.C), "the new place's forecast is shown: "
      + s.report.locationName)
    check(JSON.stringify(shell.reports) === JSON.stringify([query(places.A), query(places.C)]),
      "the stopped fetch for place B never became the report: " + JSON.stringify(shell.reports))
    check(shell.errors.length === 0 && !s.retryTimer.running,
      "the stopped fetch shows no error and schedules no retry: " + JSON.stringify(shell.errors))
    finish()
  }
}
"""


def helper_argvs():
    """The argv of every running foamy-weather-helper (and its wrapper)."""
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


def main():
    with tempfile.TemporaryDirectory(prefix="foamy-weather-fetch-") as scratch:
        arrived = Path(scratch) / "arrived"
        argvs = []

        def forecast(handler):
            if "lat=62.500&lon=8.250" in handler.path:
                # The fetch for B is connected now: look at its argv, tell the
                # shell, then answer too late for a place it has left.
                argvs.extend(helper_argvs())
                arrived.write_text("yes\n")
                time.sleep(SLOW_DELAY)
            body = fakenet.forecast_body().encode()
            try:
                handler.send_response(200)
                handler.send_header("Content-Type", "application/json")
                handler.send_header("Content-Length", str(len(body)))
                handler.send_header("Connection", "close")
                handler.end_headers()
                handler.wfile.write(body)
            except OSError:
                pass  # the stopped fetch's helper is gone
            handler.close_connection = True

        certs = fakenet.make_certs(Path(scratch) / "tls")
        shell = SHELL.replace("PLACES", json.dumps(PLACES)).replace("ARRIVED", json.dumps(str(arrived)))
        with fakenet.Server(certs, {"forecast": forecast}) as server:
            run = harness.Run("4.5", shell, plugin=ROOT, prefix="foamy-weather-fetch-", system_bus="private")
            connectivity = run.base / "connectivity"
            fake_nm.set_connectivity(connectivity, fake_nm.NONE)
            state = run.base / "home/.local/state/omarchy/settings/foamy-weather-location.json"
            state.parent.mkdir(parents=True, exist_ok=True)
            name, latitude, longitude = PLACES["A"]
            state.write_text(json.dumps({"name": name, "latitude": latitude, "longitude": longitude}) + "\n")
            state.chmod(0o600)
            run.env = fakenet.network_env(run.env, server.port, certs["ca"])
            # The fake goes on the bus before qs: Quickshell looks for
            # NetworkManager only once, at start.
            run.start_buses()
            with fake_nm.start(run.system_bus_address, connectivity):
                run.start()
                try:
                    if run.wait_for_log(OFFLINE_CHECKED, timeout=60):
                        fake_nm.set_connectivity(connectivity, fake_nm.FULL)
                    run.wait(90)
                finally:
                    run.stop()
            forecasts = server.paths("forecast")
    # As harness.Run.run() decides it.
    run.ok = "FOAMY DONE" in run.log and not run.failures()
    problems = []
    wanted = ["lat=61.123&lon=7.456", "lat=62.500&lon=8.250", "lat=63.750&lon=9.125"]
    if [next((w for w in wanted if w in path), path) for path in forecasts] != wanted:
        problems.append(f"expected one forecast request per place, in order; saw {forecasts}")
    if not any("fetch" in argv for argv in argvs):
        problems.append(f"the fetch helper was not seen while it ran: {argvs}")
    if any(value in part for argv in argvs for part in argv for value in ("62.5", "8.25")):
        problems.append(f"coordinates reached the helper's argv: {argvs}")
    if run.ok and problems:
        run.ok = False
        print("\n".join(f"4.5: {problem}" for problem in problems))
    checks = [line.split("FOAMY OK ", 1)[1] for line in run.log.splitlines() if "FOAMY OK " in line]
    if run.ok:
        print(f"4.5: {len(checks)} fetch checks passed")
        run.cleanup()
        return 0
    print(f"4.5: FAILED (log {run.base}/qs.log)")
    print("\n".join(run.failures() or run.log.splitlines()[-30:]))
    return 1


if __name__ == "__main__":
    sys.exit(main())

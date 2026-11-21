"""The forecast fetch in the real WeatherService, offscreen on Omarchy 4.5
(foamy-kit harness), with the real helper against the loopback stand-in for
MET Norway (tests/fakenet.py). The network goes down and up through the
kit's fake NetworkManager (preview/fake_nm.py) on the run's private system
bus, which Quickshell's Networking reads:

- offline, nothing is fetched; when the network comes back, the place's
  forecast arrives;
- a new place keeps the previous report on screen while it loads;
- a middle click on the bar button and `r` in the popup start a forced
  fetch;
- a place change during a running fetch stops that fetch, never applies its
  result or its end (no error, no retry), and fetches the new place instead;
- a failed fetch keeps the shown report, says why, and retries with --force;
- automatic location runs GeoClue (a stand-in) through the helper, names the
  place from the reverse lookup, fetches its rounded position and credits
  OpenStreetMap in the popup's footer, and turning it off goes back to the
  searched place;
- the User-Agent setting reaches MET Norway and Nominatim, trimmed;
- Limited connectivity (VPNs, WARP) counts as online;
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

# Four places; MET gets them rounded to three decimals. Place D's forecast
# fails (503).
PLACES = {
    "A": ("Place A", 61.123, 7.456),
    "B": ("Place B", 62.5, 8.25),
    "C": ("Place C", 63.75, 9.125),
    "D": ("Place D", 64.5, 10.5),
}
# The GeoClue stand-in's position; the helper rounds it to two decimals
# (about 1 km), and MET gets that with three.
GEOCLUE = ("12.3456", "56.7890")
AUTOMATIC = "lat=12.350&lon=56.790"
AGENT = "test-agent/1.0"
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
import "plugin/kit" as Kit

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
  // The widget's bar button (the item with the pressed(button) signal).
  function button() {
    var kids = widget ? widget.children : []
    for (var i = 0; i < kids.length; i++)
      if (typeof kids[i].pressed === "function" && "labelVisible" in kids[i]) return kids[i]
    return null
  }
  function findText(item, text) {
    if (!item) return null
    if (item.text === text) return item
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) { var hit = findText(kids[i], text); if (hit) return hit }
    return null
  }
  // refresh() starts the helper at once; a forced fetch ends in --force.
  function forcedFetchRunning() {
    var command = s.weatherProc.command
    return s.weatherProc.running && command[command.length - 1] === "--force"
  }
  readonly property var places: PLACES

  MockBar { id: bar }
  Item { id: holder }
  FoamyWait { id: wait }
  Kit.FoamyCursor { id: keys }
  // Written by the stand-in once place B's request has arrived.
  FileView { id: arrived; path: ARRIVED; blockLoading: true; printErrors: false }
  // One line per forecast request for place D.
  FileView { id: failedRequests; path: FAILED; blockLoading: true; printErrors: false }
  // The searched place on disk, which the helper writes after a search.
  FileView { id: savedPlace; path: Weather.WeatherService.localLocationFile.path; blockWrites: true; printErrors: false }
  function failedCount() { failedRequests.reload(); return failedRequests.text().split("\n").length - 1 }

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
    // The agent is stored with spaces; MET and Nominatim get it trimmed (main() below).
    widget = component.createObject(holder, { bar: bar, moduleName: "foamy.weather",
      settings: { id: "foamy.weather", requestUserAgent: "  " + AGENT + "  " } })
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
    // Place D has no cache and its forecast fails.
    s.localLocationState = { name: "Place D", latitude: places.D[1], longitude: places.D[2] }
    wait.waitFor(function() { return s.errorMessage === "Weather data is unavailable" && !s.loading }, 30000, failedFetch,
      "place D's failed fetch says so")
  }

  function failedFetch(ok) {
    if (!ok) return finish()
    check(s.retryTimer.running, "a failed fetch schedules a retry")
    check(s.report && s.report.query === query(places.C) && !s.reportCurrent, "a failed fetch keeps the shown report")
    check(widget.panel.errorText === "Weather data is unavailable", "the popup shows the error: " + widget.panel.errorText)
    wait.waitFor(function() { return shell.failedCount() >= 2 }, 10000, retried, "the failed fetch is retried")
  }

  function retried(ok) {
    if (!ok) return finish()
    // Back to place C: its forecast is fresh in the cache, so nothing is
    // fetched. This time the place is saved as a search saves it, because
    // opening the popup reads the saved place again.
    savedPlace.setText(JSON.stringify({ name: "Place C", latitude: places.C[1], longitude: places.C[2] }) + "\n")
    s.reloadLocations()
    wait.waitFor(function() {
      return s.reportCurrent && !s.loading && !s.weatherProc.running && s.report.query === query(places.C)
    }, 30000, refreshes, "place C comes back from the cache")
  }

  function refreshes(ok) {
    if (!ok) return finish()
    // Online, a middle click forces a refresh (C's cache answers, main() below).
    shell.button().pressed(Qt.MiddleButton)
    check(forcedFetchRunning(), "a middle click starts a forced fetch: " + JSON.stringify(s.weatherProc.command))
    wait.waitFor(function() { return !s.loading && !s.weatherProc.running }, 30000, middleRefreshed,
      "the middle click's fetch ends")
  }

  function middleRefreshed(ok) {
    if (!ok) return finish()
    // Opening the popup refreshes without force; `r` waits for that to end.
    widget.panel.openFromHotkey()
    wait.waitFor(function() { return widget.panel.popup.bodyItem !== null && !s.loading && !s.weatherProc.running }, 30000,
      function(ok) {
        if (!ok) return finish()
        keys.emitTextKey(widget.panel.popup.bodyItem, "r")
        check(forcedFetchRunning(), "`r` in the popup starts a forced fetch: " + JSON.stringify(s.weatherProc.command))
        wait.waitFor(function() { return !s.loading && !s.weatherProc.running }, 30000, keyRefreshed, "the `r` fetch ends")
      }, "the popup opens and its refresh ends")
  }

  function keyRefreshed(ok) {
    if (!ok) return finish()
    widget.panel.close()
    check(s.reportCurrent && s.report.query === query(places.C) && s.errorMessage === "",
      "the forced refreshes keep place C's report: " + JSON.stringify([s.report.query, s.errorMessage]))
    automatic(true)
  }

  function automatic(ok) {
    if (!ok) return finish()
    widget.panel.savePreference("automaticLocation", true)
    wait.waitFor(function() {
      return s.configuredLocation === "Example Town" && s.configuredLocationState.source === "geoclue" && s.reportCurrent && !s.loading
    }, 30000, automaticReport, "the automatic place's forecast arrives")
  }

  function automaticReport(ok) {
    if (!ok) return finish()
    check(s.report.locationName === "Example Town" && s.coordinateQuery === "12.35,56.79",
      "the automatic place is named and rounded to about 1 km: " + s.coordinateQuery)
    widget.panel.openFromHotkey()
    wait.waitFor(function() { return widget.panel.popup.bodyItem !== null }, 10000, function(ok) {
      if (!ok) return finish()
      check(findText(widget.panel.popup.bodyItem, "MET Norway · OpenStreetMap") !== null,
        "the popup's footer credits OpenStreetMap for the place name")
      widget.panel.close()
      widget.panel.savePreference("automaticLocation", false)
      wait.waitFor(function() { return s.coordinateQuery === query(places.C) && s.reportCurrent && !s.loading }, 30000,
        function(ok) { finish() }, "turning automatic location off goes back to the searched place")
    }, "the popup opens")
  }
}
"""


def helper_argvs(base):
    """The argv of every running foamy-weather-helper (and its wrapper) of the
    run in `base`. Other runs and the live widget may run the helper too: a
    process counts only when an argument lies under this run's directory."""
    prefix = f"{base}/"
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


def request_problems(forecasts, log, argvs, failed_argvs):
    """What the stand-in saw that a correct service and helper never send."""
    problems = []
    a, b, c, d = "lat=61.123&lon=7.456", "lat=62.500&lon=8.250", "lat=63.750&lon=9.125", "lat=64.500&lon=10.500"
    places = [next((w for w in (a, b, c, d, AUTOMATIC) if w in path), path) for path in forecasts]
    # In order, without repeats except D's retries: B's stopped fetch is not
    # retried, and C comes back from the cache.
    order = [place for i, place in enumerate(places) if i == 0 or places[i - 1] != place]
    if order != [a, b, c, d, AUTOMATIC] or any(places.count(p) != 1 for p in (a, b, c)) or places.count(d) < 2:
        problems.append(f"expected A, B, C once each, D at least twice, then the automatic place; saw {forecasts}")
    # D's first fetch follows the place change, its retry forces a refresh.
    ends = [argv[0][-1] if argv else None for argv in failed_argvs]
    if ends[:2] != ["fetch", "--force"]:
        problems.append(f"expected D's fetch and then a forced retry; saw {failed_argvs}")
    reverse = [path for _, path, _ in log if fakenet.kind_of(path) == "reverse"]
    if not reverse or not all("lat=12.35&lon=56.79&" in path for path in reverse):
        problems.append(f"expected a reverse lookup of the rounded position; saw {reverse}")
    if any(value in path for _, path, _ in log for value in ("12.3456", "56.789")):
        problems.append("the precise GeoClue position reached a server")
    agents = {
        headers.get("User-Agent") for _, path, headers in log if fakenet.kind_of(path) in ("forecast", "sun", "reverse")
    }
    if agents != {AGENT}:
        problems.append(f"expected every MET and Nominatim request to send {AGENT!r}; saw {agents}")
    if not any("fetch" in argv for argv in argvs) or not any("resolve-location" in argv for argv in argvs):
        problems.append(f"the fetch and location helpers were not seen while they ran: {argvs}")
    secrets = ("62.5", "8.25", "64.5", "10.5", "12.35", "56.79", "12.3456", "56.789")
    if any(value in part for argv in argvs + sum(failed_argvs, []) for part in argv for value in secrets):
        problems.append(f"coordinates reached the helper's argv: {argvs}")
    return problems


def main():
    with tempfile.TemporaryDirectory(prefix="foamy-weather-fetch-") as scratch:
        arrived = Path(scratch) / "arrived"
        failed = Path(scratch) / "failed"
        # The argv of the helpers running while B's and the automatic place's
        # requests arrived, and of the fetches for place D, in order.
        argvs = []
        failed_argvs = []

        def forecast(handler):
            if "lat=62.500&lon=8.250" in handler.path:
                # The fetch for B is connected now: look at its argv, tell the
                # shell, then answer too late for a place it has left.
                argvs.extend(helper_argvs(run.base))
                arrived.write_text("yes\n")
                time.sleep(SLOW_DELAY)
            if AUTOMATIC in handler.path:
                argvs.extend(helper_argvs(run.base))
            failing = "lat=64.500&lon=10.500" in handler.path
            if failing:
                failed_argvs.append([argv for argv in helper_argvs(run.base) if "fetch" in argv])
                with failed.open("a") as log:
                    log.write(handler.path + "\n")
            body = b"{}" if failing else fakenet.forecast_body().encode()
            try:
                handler.send_response(503 if failing else 200)
                handler.send_header("Content-Type", "application/json")
                handler.send_header("Content-Length", str(len(body)))
                handler.send_header("Connection", "close")
                handler.end_headers()
                handler.wfile.write(body)
            except OSError:
                pass  # the stopped fetch's helper is gone
            handler.close_connection = True

        def reverse(handler):
            # The automatic lookup's helper is running: look at its argv.
            argvs.extend(helper_argvs(run.base))
            body = b'{"address":{"town":"Example Town"}}'
            handler.send_response(200)
            handler.send_header("Content-Type", "application/json")
            handler.send_header("Content-Length", str(len(body)))
            handler.send_header("Connection", "close")
            handler.end_headers()
            handler.wfile.write(body)
            handler.close_connection = True

        certs = fakenet.make_certs(Path(scratch) / "tls")
        shell = (
            SHELL.replace("PLACES", json.dumps(PLACES))
            .replace("ARRIVED", json.dumps(str(arrived)))
            .replace("FAILED", json.dumps(str(failed)))
            .replace("AGENT", json.dumps(AGENT))
        )
        with fakenet.Server(certs, {"forecast": forecast, "reverse": reverse}) as server:
            run = harness.Run("4.5", shell, plugin=ROOT, prefix="foamy-weather-fetch-", system_bus="private")
            # GeoClue's demo prints the position and keeps running; the helper
            # reads it and stops it at its deadline.
            geoclue = run.base / "where-am-i"
            geoclue.write_text("#!/bin/sh\n" + f"printf '%s\\n' 'Latitude: {GEOCLUE[0]}°' 'Longitude: {GEOCLUE[1]}°'\n")
            geoclue.chmod(0o755)
            connectivity = run.base / "connectivity"
            fake_nm.set_connectivity(connectivity, fake_nm.NONE)
            state = run.base / "home/.local/state/omarchy/settings/foamy-weather-location.json"
            state.parent.mkdir(parents=True, exist_ok=True)
            name, latitude, longitude = PLACES["A"]
            state.write_text(json.dumps({"name": name, "latitude": latitude, "longitude": longitude}) + "\n")
            state.chmod(0o600)
            run.env = fakenet.network_env(run.env, server.port, certs["ca"])
            run.env["WEATHER_GEOCLUE_COMMAND"] = str(geoclue)
            # The middle click and `r` force refreshes of place C right after
            # its download: the cache must answer them on a loaded machine
            # too, so C reaches MET once.
            run.env["MET_WEATHER_FORCE_MIN_AGE"] = "3600"
            # The fake goes on the bus before qs: Quickshell looks for
            # NetworkManager only once, at start.
            run.start_buses()
            with fake_nm.start(run.system_bus_address, connectivity):
                run.start()
                try:
                    # Limited (a VPN, WARP) must count as online.
                    if run.wait_for_log(OFFLINE_CHECKED, timeout=60):
                        fake_nm.set_connectivity(connectivity, fake_nm.LIMITED)
                    run.wait(120)
                finally:
                    run.stop()
            forecasts = server.paths("forecast")
            log = list(server.log)
    # As harness.Run.run() decides it.
    run.ok = "FOAMY DONE" in run.log and not run.failures()
    problems = request_problems(forecasts, log, argvs, failed_argvs)
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

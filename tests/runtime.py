"""Load the real plugin offscreen on Omarchy 4.5 (foamy-kit harness) and check
the shared service, leader election, lazy popup body, settings read through
the schema and saving, moving a legacy searched location to state, report
retention across a location change, the hourly header, the sky's motion
gates, and the service entry beside the widgets (one IPC handler, settings
from its shell.json entry, current() on demand and its idle timeout). The
host is the installed 4.5 shell (FOAMY_HOST_45 picks another 4.5 tree).

  python3 tests/runtime.py

Needs foamy-kit (FOAMY_KIT, default ~/GitHub/Personal/foamy-kit), dbus-daemon,
dbus-python and PyGObject. Temporary HOME/XDG dirs; automatic location is off
and the network is down (the kit's fake NetworkManager, preview/fake_nm.py,
reports no connectivity), so only the location helper runs (to migrate) and
no network request starts. The helper is still pointed at the loopback
stand-in (tests/fakenet.py, also needs openssl), which must see no request:
a service that fetched anyway fails the test instead of reaching MET Norway.
"""

import argparse
import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KIT = Path(os.environ.get("FOAMY_KIT", Path.home() / "GitHub/Personal/foamy-kit"))
# 4.5 is the installed shell (FOAMY_HOST_45 overrides it). Set before the
# harness reads it.
os.environ.setdefault("FOAMY_HOST_45", "/usr/share/omarchy/shell")
sys.path.insert(0, str(KIT / "preview"))
sys.path.insert(0, str(ROOT / "tests"))
import fake_nm  # noqa: E402
import fakenet  # noqa: E402
import harness  # noqa: E402

SHELL = r"""
import QtQuick
import Quickshell
import "harness"
import "plugin" as Weather
import "plugin/kit" as Kit
import "plugin/Model.js" as Model
import "plugin/kit/FoamyIpcResolver.js" as Resolver

ShellRoot {
  id: shell
  property int failures: 0
  property int step: 0
  property var widgets: []
  property var service: null
  function handlers() { return Resolver.handlersFor(shell, "foamy.weather") }
  function current() {
    var result = Resolver.call(shell, "foamy.weather", "current", [])
    return result.ran ? JSON.parse(result.output) : null
  }
  function check(ok, what) { if (!ok) { failures++; console.log("FOAMY FAIL " + what) } else console.log("FOAMY OK " + what) }
  function panel(i) { return widgets[i] ? widgets[i].panel : null }

  MockBar { id: barA }
  MockBar { id: barB }
  Item { id: holder }
  FoamyWait { id: wait }

  Component.onCompleted: {
    // Offline (the fake NetworkManager, main() below): nothing is fetched.
    // tests/fetch-runtime.py covers the fetch.
    var component = Qt.createComponent(Qt.resolvedUrl("plugin/BarWidget.qml"))
    if (component.status !== Component.Ready) { console.log("FOAMY FAIL load " + component.errorString()); Qt.quit(); return }
    // Out-of-range or mistyped stored values read as their defaults; the agent is trimmed.
    var settings = { id: "foamy.weather", units: "metric", animations: true, refreshMinutes: 2,
                     locationRefreshMinutes: "45", requestUserAgent: "  example-agent/1.0  " }
    widgets = [component.createObject(holder, { bar: barA, moduleName: "foamy.weather", settings: settings }),
               component.createObject(holder, { bar: barB, moduleName: "foamy.weather", settings: settings })]
    // The service entry, as the shell makes it: once, with no parent.
    var entry = Qt.createComponent(Qt.resolvedUrl("plugin/Service.qml"))
    if (entry.status !== Component.Ready) { console.log("FOAMY FAIL load service " + entry.errorString()); Qt.quit(); return }
    service = entry.createObject(null)
    // The steps start once the helper has migrated the seeded legacy file
    // (a real process, slow on a loaded machine); each later step only waits
    // for QML to settle.
    wait.waitFor(function() {
      return !Weather.WeatherService.locationMigrateProc.running
        && Weather.WeatherService.localLocationState.name === "Legacy Town"
    }, 30000, function() { tick.start() }, "the legacy location is migrated")
  }

  readonly property var sample: ({ forecast: { type: "Feature", properties: { timeseries: [
    { time: new Date().toISOString(), data: { instant: { details: { air_temperature: 13.2, wind_speed: 3 } },
      next_1_hours: { summary: { symbol_code: "rain" }, details: { precipitation_amount: 1 } } } } ] } },
    sun: [], fetchedAt: new Date().toISOString(), stale: false })

  Timer {
    id: tick
    interval: 400
    repeat: true
    onTriggered: {
      var a = shell.panel(0), b = shell.panel(1)
      switch (shell.step++) {
      case 0:
        shell.check(a && b, "both bar instances built their Panel")
        shell.check(Kit.FoamyShared.memberCount("weather") === 2, "two members in scope weather")
        shell.check(Weather.WeatherService.active, "service active with members")
        shell.check(Weather.WeatherService.settings.units === "metric", "leader handed its settings to the service")
        shell.check(Weather.WeatherService.serviceSettings.units === "imperial", "service entry read its plugins[] entry")
        shell.check(Weather.WeatherService.host === shell.service && Weather.WeatherService.widgetPanel === a,
          "service entry and leader Panel registered")
        shell.check(shell.handlers().length === 1 && shell.handlers()[0] === shell.service.ipc,
          "one live foamy.weather handler, the service entry's: " + shell.handlers().length)
        var early = shell.current()
        shell.check(early && early.ok === false && ["pending", "offline"].indexOf(early.reason) !== -1,
          "current() before any report: " + JSON.stringify(early))
        var prefs = Weather.WeatherService.preferences
        shell.check(prefs.refreshMinutes === 30 && Weather.WeatherService.refreshTimer.interval === 30 * 60 * 1000
          && prefs.locationRefreshMinutes === 15, "invalid intervals read as the defaults: " + JSON.stringify(prefs))
        shell.check(Weather.WeatherService.requestUserAgent === "example-agent/1.0", "agent trimmed after the schema read")
        // The seeded legacy file (main() below) was moved to state and read.
        shell.check(!Weather.WeatherService.locationMigrateProc.running
          && Weather.WeatherService.localLocationState.name === "Legacy Town"
          && Weather.WeatherService.localLocationState.latitude === 69.65, "legacy searched location migrated and read: "
          + JSON.stringify(Weather.WeatherService.localLocationState))
        shell.check(!a.popup.bodyItem && !b.popup.bodyItem, "popup bodies are lazy")
        shell.check(!Weather.WeatherService.weatherProc.running && !Weather.WeatherService.locationProc.running, "no fetch while offline")
        // A report for the configured coordinates, shared by every instance.
        Weather.WeatherService.localLocationState = { name: "Bergen", latitude: 60.39, longitude: 5.32 }
        var report = JSON.parse(JSON.stringify(shell.sample))
        report.query = Weather.WeatherService.coordinateQuery
        report.locationName = "Bergen"
        Weather.WeatherService.report = report
        break
      case 1:
        shell.check(a.barLabel === b.barLabel && a.barLabel.indexOf("13°") > 0, "both bars show the shared report: " + a.barLabel)
        shell.check(a.reportCurrent && a.reportLocation === "Bergen", "report is current for Bergen")
        var now = shell.current()
        shell.check(now && now.ok === true && now.temperature === 13 && now.unit === "C" && now.code === "rain"
          && now.condition === "Rain" && now.location === "Bergen" && now.high === 13 && now.low === 13
          && !isNaN(Date.parse(now.updatedAt)), "current() answers from the shared report in the widget's units: " + JSON.stringify(now))
        // Moving keeps the old report under its own name while the new one loads.
        Weather.WeatherService.localLocationState = { name: "Oslo", latitude: 59.91, longitude: 10.75 }
        break
      case 2:
        shell.check(Weather.WeatherService.report !== null, "report kept across a location change")
        shell.check(!a.reportCurrent && a.reportLocation === "Bergen" && a.configuredLocation === "Oslo", "old report keeps its place name")
        shell.check(a.barLabel.indexOf("13°") > 0, "bar keeps the previous reading")
        a.openFromHotkey()
        break
      case 3:
        shell.check(a.opened && a.popup.bodyItem !== null, "opening builds the body")
        shell.check(!b.popup.bodyItem, "other monitor's body still unbuilt")
        shell.check(a.popup.width >= 559 || a.popup.contentWidth >= 559, "wide popup (560): " + a.popup.contentWidth)
        var bandSurface = shell.find(a.popup.bodyItem, "foamyHeroBandSurface")
        shell.check(bandSurface !== null && bandSurface.parent.y === 0 && bandSurface.parent.width === a.popup.bodyItem.width, "hero band is first and full width")
        shell.check(bandSurface.parent.background === null, "software renderer: band keeps the static wash instead of the sky")
        var band = bandSurface.parent
        shell.check(band.scrim === false, "no readability scrim over the band")
        var headline = shell.find(a.popup.bodyItem, "weatherHeadline")
        shell.check(headline !== null && !headline.layer.enabled, "text is never drawn through a layer")
        shell.check(String(band.settingsButton.foreground) === String(Kit.FoamyPalette.secondaryText),
          "Settings keeps the kit's tone without the sky")
        var place = shell.find(a.popup.bodyItem, "weatherPlace")
        shell.check(place !== null && place.text === "Bergen" && shell.inside(place, band), "the place leads the band: " + (place && place.text))
        // (The body has no window here, so layouts are not polished: the
        // strip's place at the band's foot is checked in the preview renders.)
        var strip = shell.find(a.popup.bodyItem, "weatherMetricStrip")
        shell.check(strip !== null && shell.inside(strip, band)
          && Math.abs(strip.width - (band.width - 2 * Kit.FoamyStyle.padding)) <= 1,
          "metric strip in the band, band width less its padding: " + (strip && strip.width) + " of " + band.width)
        shell.check(shell.find(a.popup.bodyItem, "weatherMetricStrip") === strip && !shell.inside(strip, shell.find(a.popup.bodyItem, "weatherBody")),
          "no metric row in the body")
        // The hourly header names the first wet hour as the hour cards do (HH:00).
        shell.check(/^Precipitation from \d\d:00$/.test(a.popup.bodyItem.hourSummary),
          "hourly header names the full hour: " + a.popup.bodyItem.hourSummary)
        a.startEditingLocation()
        break
      case 4:
        var settingsPage = shell.find(a.popup.bodyItem, "weatherLocationField")
        shell.check(settingsPage !== null, "settings page and search field built on demand")
        a.locationSuggestions = [{ name: "Bergen", latitude: 60.39, longitude: 5.32 }, { name: "Bergen", latitude: 52.81, longitude: 9.96 }]
        a.moveSuggestion(1); a.moveSuggestion(1)
        shell.check(a.suggestionIndex === 1, "suggestion cursor clamps to the list")
        a.commitLocation()
        shell.check(a.settingsError === "Choose a location from the search results" && !a.savingLocation, "empty search is not saved")
        a.searchCleared()
        a.settingsError = ""
        a.savePreference("units", "imperial")
        shell.check(barA.saved.length === 1 && barA.saved[0].id === "foamy.weather" && barA.saved[0].settings.units === "imperial"
          && barA.saved[0].settings.animations === true, "units saved inline as the full entry: " + JSON.stringify(barA.saved))
        a.savePreference("units", "kelvin")
        shell.check(a.saveError === "That value isn't allowed." && barA.saved.length === 1, "invalid value refused")
        a.close()
        break
      case 5:
        shell.check(!a.opened && !a.editingLocation, "close leaves settings")
        shell.check(a.conditionIcon === "\u{f0597}" && a.conditionIcon.length === 2, "escaped rain glyph survives: " + escape(a.conditionIcon))
        // Settings IPC on a closed popup must land on Settings, not the overview.
        a.startEditingLocation()
        shell.check(a.opened && a.editingLocation, "edit on a closed popup opens Settings")
        a.close()
        shell.check(!a.opened && !a.editingLocation, "close resets Settings")
        // Leader goes away (monitor unplugged): the other instance takes over.
        shell.widgets[0].destroy()
        break
      case 6:
        shell.check(Kit.FoamyShared.memberCount("weather") === 1, "one member left")
        shell.check(Weather.WeatherService.active, "service still active")
        var sky = Qt.createQmlObject('import QtQuick; import "plugin" as W; W.WeatherBackground { width: 200; height: 100 }', holder)
        sky.current = { symbol: "rain" }
        sky.shown = false
        shell.check(!sky.animating, "sky idle while hidden")
        sky.shown = true; sky.animate = false
        shell.check(!sky.animating, "sky still under reduced motion")
        sky.animate = true
        shell.check(sky.animating === sky.drawable && sky.drawable === (sky.supported && sky.conditions.available), "sky animates only when it can draw")
        // As if the 30 minutes since the current() calls above had passed.
        Weather.WeatherService.demandTimer.stop()
        Weather.WeatherService.onDemand = false
        shell.widgets[1].destroy()
        break
      case 7:
        shell.check(!Weather.WeatherService.active, "service idles with no widgets")
        shell.check(Weather.WeatherService.settings.units === "imperial", "without a widget the plugins[] entry applies")
        shell.check(shell.handlers().length === 1 && shell.handlers()[0] === shell.service.ipc, "service handler still answers")
        // An idle service starts on a call and says so.
        var cold = shell.current()
        shell.check(cold && cold.ok === false && cold.reason === "pending", "cold current() is pending: " + JSON.stringify(cold))
        shell.check(Weather.WeatherService.active && Weather.WeatherService.onDemand, "current() starts the service")
        shell.check(Weather.WeatherService.demandTimer.running && Weather.WeatherService.demandTimer.interval === 30 * 60 * 1000,
          "it stays up 30 minutes after the call")
        shell.service.ipc.open()
        shell.service.ipc.toggle()
        shell.service.ipc.edit()
        break
      case 8:
        var warm = shell.current()
        shell.check(warm && warm.ok === false && warm.reason === "offline",
          "no report for the place yet: " + JSON.stringify(warm))
        var report = JSON.parse(JSON.stringify(shell.sample))
        report.query = Weather.WeatherService.coordinateQuery
        report.locationName = "Oslo"
        Weather.WeatherService.report = report
        var hot = shell.current()
        shell.check(hot && hot.ok === true && hot.unit === "F" && hot.temperature === 56 && hot.location === "Oslo",
          "current() in the entry's units: " + JSON.stringify(hot))
        // The idle timeout (shortened here) stops it again.
        Weather.WeatherService.demandTimer.interval = 100
        Weather.WeatherService.touch()
        break
      case 9:
        shell.check(!Weather.WeatherService.active && !Weather.WeatherService.onDemand, "service idles after the timeout")
        shell.check(Weather.WeatherService.report !== null, "the last report is kept while idle")
        shell.service.destroy()
        break
      case 10:
        shell.check(Weather.WeatherService.host === null && shell.handlers().length === 0, "no handler without service or widget")
        // A host that loads no service: the leader Panel answers instead.
        var lone = Qt.createComponent(Qt.resolvedUrl("plugin/BarWidget.qml"))
        shell.widgets = [lone.createObject(holder, { bar: barA, moduleName: "foamy.weather", settings: { units: "metric" } })]
        break
      case 11:
        shell.check(shell.handlers().length === 1 && shell.handlers()[0] !== null, "the Panel's handler takes the target")
        var fallback = shell.current()
        shell.check(fallback && fallback.ok === true && fallback.unit === "C", "and answers current(): " + JSON.stringify(fallback))
        shell.widgets[0].destroy()
        console.log(shell.failures === 0 ? "FOAMY DONE" : "FOAMY FAIL " + shell.failures + " failures")
        Qt.quit()
      }
    }
  }

  function inside(item, ancestor) {
    for (var it = item; it; it = it.parent) if (it === ancestor) return true
    return false
  }

  function find(item, name) {
    if (!item) return null
    if (item.objectName === name) return item
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) { var hit = find(kids[i], name); if (hit) return hit }
    return null
  }
}
"""


def main():
    argparse.ArgumentParser(description=__doc__.splitlines()[0]).parse_args()
    host = "4.5"
    run = harness.Run(host, SHELL, plugin=ROOT, prefix="foamy-weather-runtime-", system_bus="private")
    connectivity = run.base / "connectivity"
    fake_nm.set_connectivity(connectivity, fake_nm.NONE)
    home = run.base / "home"
    legacy = home / ".config/omarchy/weather-location.local.json"
    legacy.parent.mkdir(parents=True, exist_ok=True)
    legacy.write_text('{"name":"Legacy Town","latitude":69.65,"longitude":18.96}\n')
    (home / ".config/omarchy/shell.json").write_text(
        '{"version":1,"plugins":[{"id":"foamy.weather","units":"imperial","language":"nb"}]}\n'
    )
    with tempfile.TemporaryDirectory(prefix="foamy-weather-runtime-") as scratch:
        certs = fakenet.make_certs(Path(scratch) / "tls")
        with fakenet.Server(certs) as server:
            run.env = fakenet.network_env(run.env, server.port, certs["ca"])
            # The fake goes on the bus before qs: Quickshell looks for
            # NetworkManager only once, at start.
            run.start_buses()
            with fake_nm.start(run.system_bus_address, connectivity):
                run.run(timeout=60)
            requests = server.paths()
    if requests:
        run.ok = False
        print(f"{host}: requests went out while offline: {requests}")
    checks = [line.split("FOAMY OK ", 1)[1] for line in run.log.splitlines() if "FOAMY OK " in line]
    state = home / ".local/state/omarchy/settings/foamy-weather-location.json"
    if legacy.exists() or not state.exists() or (state.stat().st_mode & 0o777) != 0o600:
        run.ok = False
        print(f"{host}: the legacy location was not moved to an owner-only state file")
    if run.ok:
        print(f"{host}: {len(checks)} checks passed")
        run.cleanup()
        sys.exit(0)
    print(f"{host}: FAILED (log {run.base}/qs.log)")
    print("\n".join(run.failures() or run.log.splitlines()[-30:]))
    sys.exit(1)


if __name__ == "__main__":
    main()

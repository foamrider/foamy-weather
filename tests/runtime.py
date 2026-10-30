"""Load the real plugin offscreen on 4.0 and 4.5 (foamy-kit harness) and check
the shared service, leader election, lazy popup body, settings saving, report
retention across a location change, and the sky's motion gates.

  python3 tests/runtime.py [--host 4.0|4.5|both]

Needs foamy-kit (FOAMY_KIT, default ~/GitHub/Personal/foamy-kit). Temporary
HOME/XDG dirs; no location is configured and automatic location is off, so no
helper process or network request starts.
"""
import argparse
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KIT = Path(os.environ.get("FOAMY_KIT", Path.home() / "GitHub/Personal/foamy-kit"))
sys.path.insert(0, str(KIT / "preview"))
import harness  # noqa: E402

SHELL = r'''
import QtQuick
import Quickshell
import "harness"
import "plugin" as Weather
import "plugin/kit" as Kit
import "plugin/Model.js" as Model

ShellRoot {
  id: shell
  property int failures: 0
  property int step: 0
  property var widgets: []
  function check(ok, what) { if (!ok) { failures++; console.log("FOAMY FAIL " + what) } else console.log("FOAMY OK " + what) }
  function panel(i) { return widgets[i] ? widgets[i].panel : null }

  MockBar { id: barA }
  MockBar { id: barB }
  Item { id: holder }

  Component.onCompleted: {
    var component = Qt.createComponent(Qt.resolvedUrl("plugin/BarWidget.qml"))
    if (component.status !== Component.Ready) { console.log("FOAMY FAIL load " + component.errorString()); Qt.quit(); return }
    var settings = { id: "foamy.weather", units: "metric", animations: true }
    widgets = [component.createObject(holder, { bar: barA, moduleName: "foamy.weather", settings: settings }),
               component.createObject(holder, { bar: barB, moduleName: "foamy.weather", settings: settings })]
    tick.start()
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
        shell.check(!a.popup.bodyItem && !b.popup.bodyItem, "popup bodies are lazy")
        shell.check(!Weather.WeatherService.weatherProc.running && !Weather.WeatherService.locationProc.running, "no helper without a location")
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
        shell.widgets[1].destroy()
        break
      case 7:
        shell.check(!Weather.WeatherService.active, "service idles with no widgets")
        console.log(shell.failures === 0 ? "FOAMY DONE" : "FOAMY FAIL " + shell.failures + " failures")
        Qt.quit()
      }
    }
  }

  function find(item, name) {
    if (!item) return null
    if (item.objectName === name) return item
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) { var hit = find(kids[i], name); if (hit) return hit }
    return null
  }
}
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="both", choices=["4.0", "4.5", "both"])
    args = parser.parse_args()
    status = 0
    for host in (["4.0", "4.5"] if args.host == "both" else [args.host]):
        run = harness.Run(host, SHELL, plugin=ROOT, prefix="foamy-weather-runtime-").run(timeout=60)
        checks = [line.split("FOAMY OK ", 1)[1] for line in run.log.splitlines() if "FOAMY OK " in line]
        if run.ok:
            print(f"{host}: {len(checks)} checks passed")
            run.cleanup()
        else:
            status = 1
            print(f"{host}: FAILED (log {run.base}/qs.log)")
            print("\n".join(run.failures() or run.log.splitlines()[-30:]))
    sys.exit(status)


if __name__ == "__main__":
    main()

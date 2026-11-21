"""Load the real plugin offscreen on Omarchy 4.5 (foamy-kit harness) and check
the shared service, leader election, lazy popup body, settings read through
the schema and saving, moving a legacy searched location to state, report
retention across a location change, the hourly header, the bar button (a
left click opens, a middle click refreshes, a right click sends the summary
to omarchy-notification-send without coordinates), the bar's hover reveal,
the footer and the note offline, the search field's wiring, and the service
entry beside the widgets (one IPC handler, every IPC function on both
handlers, settings from its shell.json entry, which it never writes,
current() on demand and its idle timeout). The steps wait on conditions. The
host is the installed 4.5 shell (FOAMY_HOST_45 picks another 4.5 tree).

  python3 tests/runtime.py

Needs foamy-kit (FOAMY_KIT, default ~/GitHub/Personal/foamy-kit), dbus-daemon,
dbus-python and PyGObject. Temporary HOME/XDG dirs; automatic location is off
and the network is down (the kit's fake NetworkManager, preview/fake_nm.py,
reports no connectivity), so only the location helper runs (to migrate) and
no network request starts. The helper is still pointed at the loopback
stand-in (tests/fakenet.py, also needs openssl), which must see no request:
a service that fetched anyway fails the test instead of reaching MET Norway.
The notification command is a stand-in that records its arguments.
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
import Quickshell.Io
import "harness"
import "plugin" as Weather
import "plugin/kit" as Kit
import "plugin/Model.js" as Model
import "plugin/kit/FoamyIpcResolver.js" as Resolver

ShellRoot {
  id: shell
  property int failures: 0
  property var widgets: []
  property var service: null
  function handlers() { return Resolver.handlersFor(shell, "foamy.weather") }
  function call(name) { return Resolver.call(shell, "foamy.weather", name, []) }
  function current() {
    var result = call("current")
    return result.ran ? JSON.parse(result.output) : null
  }
  function check(ok, what) { if (!ok) { failures++; console.log("FOAMY FAIL " + what) } else console.log("FOAMY OK " + what) }
  function panel(i) { return widgets[i] ? widgets[i].panel : null }
  function finish() {
    console.log(shell.failures === 0 ? "FOAMY DONE" : "FOAMY FAIL " + shell.failures + " failures")
    Qt.quit()
  }
  // Wait for a condition, then go on; a timeout fails the run and ends it.
  function go(condition, label, next) {
    wait.waitFor(condition, 10000, function(ok) { if (ok) next(); else shell.finish() }, label)
  }
  function last(list) { return list.length ? list[list.length - 1] : undefined }
  // The widget's bar button (the item with the pressed(button) signal).
  function button(widget) {
    var kids = widget ? widget.children : []
    for (var i = 0; i < kids.length; i++)
      if (typeof kids[i].pressed === "function" && "labelVisible" in kids[i]) return kids[i]
    return null
  }

  // The bar of the first instance records the hover-reveal calls the Panel
  // makes (Omarchy's bar exposes the setter; the property is read-only there).
  MockBar {
    id: barA
    property var hoverCalls: []
    readonly property bool centerHoverRevealSuppressed: false
    function setCenterHoverRevealSuppressed(value) { hoverCalls = hoverCalls.concat([value]) }
  }
  MockBar { id: barB }
  Item { id: holder }
  FoamyWait { id: wait }
  Kit.FoamyCursor { id: keys }
  // What the fake omarchy-notification-send got (main() below).
  FileView { id: notified; path: Quickshell.env("FOAMY_OUT") + "/notify.argv"; blockLoading: true; printErrors: false }
  function notifications() {
    notified.reload()
    var fields = notified.text().split("\u0000")
    var calls = []
    for (var i = 0; i + 4 <= fields.length - 1; i += 4) calls.push(fields.slice(i, i + 4))
    return calls
  }

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
    // (a real process, slow on a loaded machine).
    wait.waitFor(function() {
      return !Weather.WeatherService.locationMigrateProc.running
        && Weather.WeatherService.localLocationState.name === "Legacy Town"
    }, 30000, function(ok) { if (ok) step0(); else finish() }, "the legacy location is migrated")
  }

  readonly property var sample: ({ forecast: { type: "Feature", properties: { timeseries: [
    { time: new Date().toISOString(), data: { instant: { details: { air_temperature: 13.2, wind_speed: 3 } },
      next_1_hours: { summary: { symbol_code: "rain" }, details: { precipitation_amount: 1 } } } } ] } },
    sun: [], fetchedAt: new Date().toISOString(), stale: false })

  function step0() {
    var a = shell.panel(0), b = shell.panel(1)
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
    shell.check(Weather.WeatherService.localLocationState.latitude === 69.65, "legacy searched location migrated and read: "
      + JSON.stringify(Weather.WeatherService.localLocationState))
    shell.check(!a.popup.bodyItem && !b.popup.bodyItem, "popup bodies are lazy")
    shell.check(!Weather.WeatherService.weatherProc.running && !Weather.WeatherService.locationProc.running, "no fetch while offline")
    // A report for the configured coordinates, shared by every instance.
    Weather.WeatherService.localLocationState = { name: "Bergen", latitude: 60.39, longitude: 5.32 }
    var report = JSON.parse(JSON.stringify(shell.sample))
    report.query = Weather.WeatherService.coordinateQuery
    report.locationName = "Bergen"
    Weather.WeatherService.report = report
    shell.go(function() { return a.reportCurrent }, "the report is current for Bergen", step1)
  }

  function step1() {
    var a = shell.panel(0), b = shell.panel(1)
    shell.check(a.barLabel === b.barLabel && a.barLabel.indexOf("13°") > 0, "both bars show the shared report: " + a.barLabel)
    shell.check(a.reportLocation === "Bergen", "report is current for Bergen")
    var now = shell.current()
    shell.check(now && now.ok === true && now.temperature === 13 && now.unit === "C" && now.code === "rain"
      && now.condition === "Rain" && now.location === "Bergen" && now.high === 13 && now.low === 13
      && !isNaN(Date.parse(now.updatedAt)), "current() answers from the shared report in the widget's units: " + JSON.stringify(now))
    // A right click sends the summary as a notification. The second one
    // comes after a failed reverse lookup left the coordinates as the name
    // (same place, so the report stays current).
    var button = shell.button(shell.widgets[0])
    shell.check(button !== null, "the widget's bar button found")
    button.pressed(Qt.RightButton)
    // One at a time: the command runs detached, so two could land in either order.
    shell.go(function() { return shell.notifications().length === 1 }, "the summary reaches omarchy-notification-send", function() {
      Weather.WeatherService.localLocationState = { name: "60.39, 5.32", latitude: 60.39, longitude: 5.32 }
      shell.check(a.reportCurrent && a.reportLocation === "60.39, 5.32", "a coordinate label names the current place")
      button.pressed(Qt.RightButton)
      shell.go(function() { return shell.notifications().length === 2 }, "the second summary reaches omarchy-notification-send", function() {
        Weather.WeatherService.localLocationState = { name: "Bergen", latitude: 60.39, longitude: 5.32 }
        // Moving keeps the old report under its own name while the new one loads.
        Weather.WeatherService.localLocationState = { name: "Oslo", latitude: 59.91, longitude: 10.75 }
        shell.go(function() { return a.configuredLocation === "Oslo" }, "the new place is configured", step2)
      })
    })
  }

  function step2() {
    var a = shell.panel(0), b = shell.panel(1)
    shell.check(Weather.WeatherService.report !== null, "report kept across a location change")
    shell.check(!a.reportCurrent && a.reportLocation === "Bergen" && a.configuredLocation === "Oslo", "old report keeps its place name")
    shell.check(a.barLabel.indexOf("13°") > 0, "bar keeps the previous reading")
    // A left click opens the popup (and asks the bar to hold back its hover reveal).
    shell.button(shell.widgets[0]).pressed(Qt.LeftButton)
    shell.go(function() { return a.opened && a.popup.bodyItem !== null }, "a left click opens the popup and builds its body", function() {
      shell.go(function() { return shell.last(barA.hoverCalls) === true }, "the open popup suppresses the bar's hover reveal", step3)
    })
  }

  function step3() {
    var a = shell.panel(0), b = shell.panel(1)
    var body = a.popup.bodyItem
    shell.check(!b.popup.bodyItem, "other monitor's body still unbuilt")
    shell.check(a.popup.width >= 559 || a.popup.contentWidth >= 559, "wide popup (560): " + a.popup.contentWidth)
    var bandSurface = shell.find(body, "foamyHeroBandSurface")
    shell.check(bandSurface !== null && bandSurface.parent.y === 0 && bandSurface.parent.width === body.width, "hero band is first and full width")
    shell.check(bandSurface.parent.background === null, "software renderer: band keeps the static wash instead of the sky")
    var band = bandSurface.parent
    var headline = shell.find(body, "weatherHeadline")
    shell.check(headline !== null && !headline.layer.enabled, "text is never drawn through a layer")
    shell.check(String(band.settingsButton.foreground) === String(Kit.FoamyPalette.secondaryText),
      "Settings keeps the kit's tone without the sky")
    var place = shell.find(body, "weatherPlace")
    shell.check(place !== null && place.text === "Bergen" && shell.inside(place, band), "the place leads the band: " + (place && place.text))
    // (The body has no window here, so layouts are not polished: the
    // strip's place at the band's foot is checked in the preview renders.)
    var strip = shell.find(body, "weatherMetricStrip")
    shell.check(strip !== null && shell.inside(strip, band)
      && Math.abs(strip.width - (band.width - 2 * Kit.FoamyStyle.padding)) <= 1,
      "metric strip in the band, band width less its padding: " + (strip && strip.width) + " of " + band.width)
    shell.check(shell.find(body, "weatherMetricStrip") === strip && !shell.inside(strip, shell.find(body, "weatherBody")),
      "no metric row in the body")
    // The hourly header names the first wet hour as the hour cards do (HH:00).
    shell.check(/^Precipitation from \d\d:00$/.test(body.hourSummary),
      "hourly header names the full hour: " + body.hourSummary)
    // Offline: the footer says so and its refresh is inert; `r` and a middle
    // click start no fetch (main() checks that no request went out).
    var status = shell.find(body, "foamyFooterStatus")
    shell.check(status !== null && status.text === "Waiting for network…", "the footer waits for the network: " + (status && status.text))
    var refresh = shell.find(body, "foamyFooterRefresh")
    shell.check(refresh !== null && refresh.actionEnabled === false, "the footer's refresh is inert offline")
    shell.check(refresh !== null && refresh.parent.parent.source === "MET Norway", "the footer names the data source")
    keys.emitTextKey(body, "r")
    shell.button(shell.widgets[0]).pressed(Qt.MiddleButton)
    shell.check(!Weather.WeatherService.weatherProc.running && !Weather.WeatherService.loading, "`r` and a middle click fetch nothing offline")
    // The note above the forecast shows the service's message, translated
    // with its values.
    Weather.WeatherService.setError("Showing last known weather")
    var note = shell.findText(body, "Showing last known weather")
    shell.check(note !== null, "a stale report shows its note")
    Weather.WeatherService.setError("Unknown option: %1", ["--x"])
    shell.check(note !== null && note.text === "Unknown option: --x", "an error note carries its values: " + (note && note.text))
    Weather.WeatherService.setError("")
    shell.check(note !== null && note.text === "", "no note without a message: " + (note && note.text))
    // `s` opens Settings.
    keys.emitTextKey(body, "s")
    shell.go(function() { return a.editingLocation && shell.find(a.popup.bodyItem, "weatherLocationField") !== null },
      "`s` opens Settings with the search field", step4)
  }

  function step4() {
    var a = shell.panel(0)
    var field = shell.find(a.popup.bodyItem, "weatherLocationField")
    shell.check(shell.find(field, "safeEditor") !== null, "the search field is the kit's clipboard-safe field")
    // The field drives the search, a cleared search clears it, and its paste
    // errors reach the page.
    field.text = "Os"
    field.textEdited()
    shell.check(a.searchText === "Os", "typing in the field starts the search: " + JSON.stringify(a.searchText))
    a.clearSearch()
    shell.check(field.text === "", "a cleared search clears the field: " + JSON.stringify(field.text))
    field.pasteError = "Clipboard paste timed out. Copy the text again."
    shell.check(a.settingsError === "Clipboard paste timed out. Copy the text again.", "a paste error shows on the page: " + a.settingsError)
    a.settingsError = ""
    a.locationSuggestions = [{ name: "Bergen", latitude: 60.39, longitude: 5.32 }, { name: "Bergen", latitude: 52.81, longitude: 9.96 }]
    a.moveSuggestion(1); a.moveSuggestion(1)
    shell.check(a.suggestionIndex === 1, "suggestion cursor clamps to the list")
    a.commitLocation()
    shell.check(a.settingsError === "Choose a location from the search results" && !a.savingLocation, "empty search is not saved")
    a.settingsError = ""
    a.savePreference("units", "imperial")
    shell.check(barA.saved.length === 1 && barA.saved[0].id === "foamy.weather" && barA.saved[0].settings.units === "imperial"
      && barA.saved[0].settings.animations === true, "units saved inline as the full entry: " + JSON.stringify(barA.saved))
    a.savePreference("units", "kelvin")
    shell.check(a.saveError === "That value isn't allowed." && barA.saved.length === 1, "invalid value refused")
    a.close()
    shell.check(shell.last(barA.hoverCalls) === false, "closing gives the bar its hover reveal back")
    shell.go(function() { return !a.opened && !a.editingLocation }, "close leaves settings", step5)
  }

  function step5() {
    var a = shell.panel(0)
    shell.check(a.conditionIcon === "\u{f0597}" && a.conditionIcon.length === 2, "escaped rain glyph survives: " + escape(a.conditionIcon))
    // Settings IPC on a closed popup must land on Settings, not the overview.
    a.startEditingLocation()
    shell.check(a.opened && a.editingLocation, "edit on a closed popup opens Settings")
    a.close()
    shell.check(!a.opened && !a.editingLocation, "close resets Settings")
    // The service entry's handler drives the leader's popup.
    shell.check(shell.call("edit").ran, "edit through the service entry runs")
    shell.go(function() { return a.opened && a.editingLocation }, "edit through the service entry opens Settings", function() {
      shell.check(shell.call("close").ran, "close through the service entry runs")
      shell.go(function() { return !a.opened && !a.editingLocation }, "close through the service entry closes the popup", function() {
        // Leader goes away (monitor unplugged): the other instance takes over.
        shell.widgets[0].destroy()
        shell.go(function() { return Kit.FoamyShared.memberCount("weather") === 1 }, "one member left", step6)
      })
    })
  }

  function step6() {
    shell.check(Weather.WeatherService.active, "service still active")
    // As if the 30 minutes since the current() calls above had passed.
    Weather.WeatherService.demandTimer.stop()
    Weather.WeatherService.onDemand = false
    shell.widgets[1].destroy()
    shell.go(function() { return !Weather.WeatherService.active }, "service idles with no widgets", step7)
  }

  function step7() {
    shell.check(Weather.WeatherService.settings.units === "imperial", "without a widget the plugins[] entry applies")
    shell.check(shell.handlers().length === 1 && shell.handlers()[0] === shell.service.ipc, "service handler still answers")
    // An idle service starts on a call and says so.
    var cold = shell.current()
    shell.check(cold && cold.ok === false && cold.reason === "pending", "cold current() is pending: " + JSON.stringify(cold))
    shell.check(Weather.WeatherService.active && Weather.WeatherService.onDemand, "current() starts the service")
    shell.check(Weather.WeatherService.demandTimer.running && Weather.WeatherService.demandTimer.interval === 30 * 60 * 1000,
      "it stays up 30 minutes after the call")
    // The popup functions do nothing without a widget (main() checks the log).
    shell.check(shell.call("open").ran && shell.call("toggle").ran && shell.call("edit").ran,
      "open, toggle and edit answer without a widget")
    // Started again, the service migrates and reads the files first.
    shell.go(function() { return !Weather.WeatherService.pending }, "the started service settles", step8)
  }

  function step8() {
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
    shell.go(function() { return !Weather.WeatherService.active && !Weather.WeatherService.onDemand },
      "service idles after the timeout", step9)
  }

  function step9() {
    shell.check(Weather.WeatherService.report !== null, "the last report is kept while idle")
    shell.service.destroy()
    shell.go(function() { return shell.handlers().length === 0 }, "no handler without service or widget", step10)
  }

  function step10() {
    shell.check(Weather.WeatherService.host === null, "the service entry is gone")
    // A host that loads no service: the leader Panel answers instead.
    var lone = Qt.createComponent(Qt.resolvedUrl("plugin/BarWidget.qml"))
    shell.widgets = [lone.createObject(holder, { bar: barA, moduleName: "foamy.weather", settings: { units: "metric" } })]
    shell.go(function() { return shell.handlers().length === 1 && shell.panel(0) !== null }, "the Panel's handler takes the target", step11)
  }

  function step11() {
    var a = shell.panel(0)
    var fallback = shell.current()
    shell.check(fallback && fallback.ok === true && fallback.unit === "C", "and answers current(): " + JSON.stringify(fallback))
    // Every function of the Panel's handler does what the service entry's does.
    var calls = [
      ["edit", function() { return a.opened && a.editingLocation }],
      ["close", function() { return !a.opened && !a.editingLocation }],
      ["toggle", function() { return a.opened }],
      ["hide", function() { return !a.opened }],
      ["show", function() { return a.opened }],
      ["close", function() { return !a.opened }]
    ]
    var next = function(i) {
      if (i === calls.length) {
        shell.check(shell.call("refresh").ran, "the Panel's handler refreshes")
        shell.widgets[0].destroy()
        shell.finish()
        return
      }
      shell.check(shell.call(calls[i][0]).ran, calls[i][0] + " through the Panel's handler runs")
      shell.go(calls[i][1], calls[i][0] + " through the Panel's handler acts on its popup", function() { next(i + 1) })
    }
    next(0)
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

  function findText(item, text) {
    if (!item) return null
    if (item.text === text) return item
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) { var hit = findText(kids[i], text); if (hit) return hit }
    return null
  }
}
"""


def main():
    argparse.ArgumentParser(description=__doc__.splitlines()[0]).parse_args()
    host = "4.5"
    # The right-click summary goes to this stand-in, never to a real notification.
    notify = '#!/bin/sh\nprintf \'%s\\0\' "$@" >> "$FOAMY_OUT/notify.argv"\n'
    run = harness.Run(
        host,
        SHELL,
        plugin=ROOT,
        prefix="foamy-weather-runtime-",
        system_bus="private",
        fakebin={"omarchy-notification-send": notify},
    )
    connectivity = run.base / "connectivity"
    fake_nm.set_connectivity(connectivity, fake_nm.NONE)
    home = run.base / "home"
    legacy = home / ".config/omarchy/weather-location.local.json"
    legacy.parent.mkdir(parents=True, exist_ok=True)
    legacy.write_text('{"name":"Legacy Town","latitude":69.65,"longitude":18.96}\n')
    shell_json = home / ".config/omarchy/shell.json"
    shell_json_bytes = b'{"version":1,"plugins":[{"id":"foamy.weather","units":"imperial","language":"nb"}]}\n'
    shell_json.write_bytes(shell_json_bytes)
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
    # The service entry reads shell.json and never writes it (only the bar saves).
    if shell_json.read_bytes() != shell_json_bytes:
        run.ok = False
        print(f"{host}: shell.json was rewritten: {shell_json.read_text()!r}")
    # NUL-separated, four fields per call: -g, the glyph, the title, the body.
    argv_file = run.out / "notify.argv"
    fields = argv_file.read_text().split("\0")[:-1] if argv_file.exists() else []
    calls = [fields[i : i + 4] for i in range(0, len(fields), 4)]
    if (
        len(calls) != 2
        or calls[0][:3] != ["-g", "\U000f0597", "Weather in Bergen"]
        or not calls[0][3].startswith("Rain · 13°")
        or "Humidity" not in calls[0][3]
        or calls[1][2] != "Weather in selected location"
    ):
        run.ok = False
        print(f"{host}: unexpected right-click notifications: {calls}")
    if any(value in field for value in ("60.39", "5.32") for field in fields):
        run.ok = False
        print(f"{host}: coordinates reached the notification command: {calls}")
    # Popup functions without a widget, the hover setter: nothing may throw.
    errors = [
        line
        for line in run.log.splitlines()
        if any(word in line for word in ("TypeError", "ReferenceError", "read-only"))
    ]
    if errors:
        run.ok = False
        print(f"{host}: errors in the run log:\n" + "\n".join(errors))
    if run.ok:
        print(f"{host}: {len(checks)} checks passed")
        run.cleanup()
        sys.exit(0)
    print(f"{host}: FAILED (log {run.base}/qs.log)")
    print("\n".join(run.failures() or run.log.splitlines()[-30:]))
    sys.exit(1)


if __name__ == "__main__":
    main()

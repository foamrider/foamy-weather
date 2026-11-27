"""The popup's keys after Settings closes, in the real Panel offscreen on
Omarchy 4.5 (foamy-kit harness), with real key presses and clicks. The popup
is shown in a window here (tests/runtime.py has none, so no item gets the
keys there). When Settings hides, the keys must come back to the view
(foamy-kit's FoamyPopup and SafeTextField give them to the popup body):
after Esc in the focused search field leaves Settings, an arrow walks the
day cards, `s` opens Settings again and Esc closes the popup; and after the
popup closes on Settings and opens again, Esc closes it. Keys left with the
hidden page still pass through it to the view, except Esc: the page takes
it for its own Back, and the popup stays open. (`r` is the same text-key
handler as `s`, and offline it fetches nothing to see.) In the place search
↓ draws the keys' accent border on the suggestion it moves to, and the
pointer moved onto a suggestion takes the cursor without it.

  python3 tests/keys-runtime.py

Needs foamy-kit (FOAMY_KIT, default ~/GitHub/Personal/foamy-kit), openssl,
dbus-daemon, dbus-python and PyGObject. Temporary HOME/XDG dirs; the network
is down (the kit's fake NetworkManager), and the helper is pointed at the
loopback stand-in (tests/fakenet.py), which must see no request.
"""

import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KIT = Path(os.environ.get("FOAMY_KIT", Path.home() / "GitHub/Personal/foamy-kit"))
os.environ.setdefault("FOAMY_HOST_45", "/usr/share/omarchy/shell")
sys.path.insert(0, str(KIT / "preview"))
sys.path.insert(0, str(ROOT / "tests"))
import fake_nm
import fakenet
import harness

SHELL = r"""
import QtQuick
import QtTest
import Quickshell
import "harness"
import "plugin" as Weather
import "plugin/kit" as Kit

ShellRoot {
  id: shell
  property int failures: 0
  property var widget: null
  function check(ok, what) { if (!ok) { failures++; console.log("FOAMY FAIL " + what) } else console.log("FOAMY OK " + what) }
  function finish() {
    console.log(shell.failures === 0 ? "FOAMY DONE" : "FOAMY FAIL " + shell.failures + " failures")
    Qt.quit()
  }
  // Wait for a condition, then go on; a timeout fails the run and ends it.
  function go(condition, label, next) {
    wait.waitFor(condition, 10000, function(ok) { if (ok) next(); else shell.finish() }, label)
  }
  function panel() { return widget ? widget.panel : null }
  function body() { var a = panel(); return a ? a.popup.bodyItem : null }
  function field() { return find(body(), "weatherLocationField") }
  // The settings page: the search field's page, its own key home (kept
  // once Settings has been built).
  function page() {
    for (var at = field(); at; at = at.parent) if (at.foamyKeyHome === at) return at
    return null
  }
  function inside(item, ancestor) {
    for (var at = item; at && ancestor; at = at.parent) if (at === ancestor) return true
    return false
  }
  // The item with the keys, named in the failure messages.
  function keys() { var b = body(); var w = b ? b.Window.window : null; return w ? w.activeFocusItem : null }
  function named(item) { return item ? (item.objectName || String(item).split("(")[0]) : "nothing" }
  function key(k) { ev.keyClick(k, Qt.NoModifier, -1) }
  function click(item) { ev.mouseClick(item, item.width / 2, item.height / 2, Qt.LeftButton, Qt.NoModifier, -1) }
  function find(item, name) {
    if (!item) return null
    if (item.objectName === name) return item
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) { var hit = find(kids[i], name); if (hit) return hit }
    return null
  }
  // Two days of hourly forecast from this hour, so the arrows have day cards to walk.
  function report() {
    var start = new Date()
    start.setMinutes(0, 0, 0)
    var series = []
    for (var i = 0; i < 48; i++)
      series.push({ time: new Date(start.getTime() + i * 3600 * 1000).toISOString(), data: {
        instant: { details: { air_temperature: 10, wind_speed: 3 } },
        next_1_hours: { summary: { symbol_code: "cloudy" }, details: { precipitation_amount: 0 } } } })
    return { forecast: { type: "Feature", properties: { timeseries: series } }, sun: [],
      fetchedAt: new Date().toISOString(), stale: false }
  }

  FloatingWindow {
    implicitWidth: 1920
    implicitHeight: 1080
    color: "black"
    ScreenSim { id: sim }
    Item { TestEvent { id: ev } }
    // The bar button the popup hangs from.
    Item { id: holder; x: sim.anchor.x; y: sim.anchor.y; width: sim.anchor.width; height: sim.anchor.height }
  }
  MockBar { id: bar }
  FoamyWait { id: wait }

  Component.onCompleted: {
    // Offline (the fake NetworkManager, main() below): nothing is fetched.
    var component = Qt.createComponent(Qt.resolvedUrl("plugin/BarWidget.qml"))
    if (component.status !== Component.Ready) { console.log("FOAMY FAIL load " + component.errorString()); Qt.quit(); return }
    widget = component.createObject(holder, { bar: bar, moduleName: "foamy.weather", settings: { id: "foamy.weather", animations: false } })
    shell.go(function() { return shell.panel() !== null && !Weather.WeatherService.pending }, "the panel and the service are up", step0)
  }

  function step0() {
    Weather.WeatherService.localLocationState = { name: "Bergen", latitude: 60.39, longitude: 5.32 }
    var report = shell.report()
    report.query = Weather.WeatherService.coordinateQuery
    report.locationName = "Bergen"
    Weather.WeatherService.report = report
    shell.panel().openFromHotkey()
    shell.go(function() { return shell.body() !== null && shell.body().forecastDays.length >= 2 && shell.keys() === shell.body() },
      "the popup opens on the forecast with the keys", function() {
        shell.key(Qt.Key_S)
        shell.leaveFromField(step1)
      })
  }

  // Settings opens: a click gives the search field the keys, a letter
  // reaches the search, and Esc in the field leaves Settings.
  function leaveFromField(next) {
    var a = shell.panel()
    shell.go(function() { return a.editingLocation && shell.field() !== null && shell.field().visible && shell.field().width > 0 },
      "Settings shows the search field", function() {
        shell.click(shell.field())
        shell.go(function() { return shell.field().inputActiveFocus }, "a click gives the search field the keys", function() {
          shell.key(Qt.Key_O)
          shell.check(a.searchText === "o", "a letter reaches the search: " + JSON.stringify(a.searchText))
          shell.key(Qt.Key_Escape)
          shell.go(function() { return !a.editingLocation }, "Esc in the search field leaves Settings", next)
        })
      })
  }

  function step1() {
    var a = shell.panel()
    shell.check(a.opened, "leaving Settings keeps the popup open")
    // The first arrow puts the cursor on today's card, the second selects tomorrow.
    shell.key(Qt.Key_Right)
    shell.key(Qt.Key_Right)
    shell.check(a.selectedDayIndex === 1, "an arrow then walks the day cards: day " + a.selectedDayIndex + ", keys with " + shell.named(shell.keys()))
    shell.key(Qt.Key_S)
    shell.check(a.editingLocation, "`s` then opens Settings again: keys with " + shell.named(shell.keys()))
    shell.searchKeys(function() { shell.leaveFromField(step2) })
  }

  // The suggestions that draw the keys' accent border (by name).
  function suggestions() {
    var found = []
    var walk = function(item) {
      if (item.modelData !== undefined && item.modelData.latitude !== undefined && item.borderSpec !== undefined) found.push(item)
      var kids = item.children || []
      for (var i = 0; i < kids.length; i++) walk(kids[i])
    }
    walk(shell.page())
    return found
  }
  function bordered() {
    return shell.suggestions().filter(function(s) { return s.borderTop > 0 && Qt.colorEqual(s.borderSpec.color, s.accent) }).map(function(s) { return s.modelData.name })
  }
  // Fixture results (offline, no search runs): ↓ in the field moves the
  // cursor and draws the keys' border there; the pointer on another result
  // takes the cursor without it; ↓ again draws it.
  function searchKeys(next) {
    var a = shell.panel()
    shell.go(function() { return shell.field() !== null && shell.field().visible && shell.field().width > 0 }, "Settings shows the search field", function() {
      shell.click(shell.field())
      a.locationSuggestions = [{ name: "Bergen", description: "Vestland", latitude: 60.39, longitude: 5.32 },
        { name: "Bergen auf Rügen", description: "Germany", latitude: 54.42, longitude: 13.43 },
        { name: "Bergen op Zoom", description: "Netherlands", latitude: 51.49, longitude: 4.29 }]
      a.suggestionIndex = 0
      shell.go(function() { return shell.field().inputActiveFocus && shell.suggestions().length === 3 && shell.suggestions()[2].height > 0 }, "the suggestions show, the field has the keys", function() {
        shell.check(JSON.stringify(shell.bordered()) === "[]", "the first result, not moved by the keys: no border: " + JSON.stringify(shell.bordered()))
        shell.key(Qt.Key_Down)
        shell.check(a.suggestionIndex === 1 && JSON.stringify(shell.bordered()) === JSON.stringify(["Bergen auf Rügen"]) && shell.suggestions()[1].borderTop === Kit.FoamyStyle.borderWidth, "↓: the keys' border on the second result alone: " + JSON.stringify(shell.bordered()))
        var third = shell.suggestions()[2]
        ev.mouseMove(third, third.width / 2, third.height / 2, -1, Qt.NoButton, Qt.NoModifier)
        shell.check(a.suggestionIndex === 2 && JSON.stringify(shell.bordered()) === "[]", "the pointer on the third result: the cursor there, no border: " + a.suggestionIndex + " " + JSON.stringify(shell.bordered()))
        shell.key(Qt.Key_Up)
        shell.check(a.suggestionIndex === 1 && JSON.stringify(shell.bordered()) === JSON.stringify(["Bergen auf Rügen"]), "↑: the keys' border again: " + JSON.stringify(shell.bordered()))
        a.locationSuggestions = []
        // leaveFromField types into the field; start it from an empty search.
        a.clearSearch()
        next()
      })
    })
  }

  function step2() {
    var a = shell.panel()
    shell.key(Qt.Key_Escape)
    shell.check(!a.opened, "Esc then closes the popup: keys with " + shell.named(shell.keys()))
    shell.go(function() { return !a.popup.visible }, "the popup is gone", step3)
  }

  // The popup closes while Settings shows (the bar button, a click outside
  // and IPC close all call the Panel's close()) and opens again: the hidden
  // page has no keys, and Esc closes the popup.
  function step3() {
    var a = shell.panel()
    a.openFromHotkey()
    shell.go(function() { return a.opened && shell.keys() === shell.body() }, "the popup opens again with the keys", function() {
      shell.key(Qt.Key_S)
      shell.go(function() { return a.editingLocation && shell.inside(shell.keys(), shell.page()) },
        "`s` opens Settings, and the page has the keys", function() {
          a.close()
          shell.go(function() { return !a.opened && !a.editingLocation && !a.popup.visible }, "the popup closes on Settings", function() {
            a.openFromHotkey()
            shell.go(function() { return a.opened && shell.inside(shell.keys(), shell.body()) },
              "the popup opens again with the keys in its body", function() {
                shell.check(!shell.inside(shell.keys(), shell.page()), "the hidden settings page has no keys: keys with " + shell.named(shell.keys()))
                shell.key(Qt.Key_Escape)
                shell.check(!a.opened, "Esc closes the popup that closed on Settings: keys with " + shell.named(shell.keys()))
                shell.finish()
              })
          })
        })
    })
  }
}
"""


def main():
    run = harness.Run("4.5", SHELL, plugin=ROOT, prefix="foamy-weather-keys-", system_bus="private")
    connectivity = run.base / "connectivity"
    fake_nm.set_connectivity(connectivity, fake_nm.NONE)
    with tempfile.TemporaryDirectory(prefix="foamy-weather-keys-") as scratch:
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
        print(f"4.5: requests went out while offline: {requests}")
    checks = [line.split("FOAMY OK ", 1)[1] for line in run.log.splitlines() if "FOAMY OK " in line]
    if run.ok:
        print(f"4.5: {len(checks)} key checks passed")
        run.cleanup()
        return 0
    print(f"4.5: FAILED (log {run.base}/qs.log)")
    print("\n".join(run.failures() or run.log.splitlines()[-30:]))
    return 1


if __name__ == "__main__":
    sys.exit(main())

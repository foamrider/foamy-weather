import QtQuick
import ".." as Dev

// The dev (1.1) UI for the kit's --trio renders: the real 1.1 Panel with its
// WeatherPopup fork, opened against the harness bar and fed the same mock
// report as Preview.qml (MockWeather.js, inlined: only this file is copied
// into the dev tree). Offscreen there is no network, so nothing is fetched.
Item {
  id: preview
  required property QtObject bar
  required property Item anchorItem
  property var previewStates: ["forecast", "empty", "settings"]
  property string previewState: "forecast"
  property int settleMs: 900
  // 1.1 keeps its popup (id panel) inside Panel.qml, and the harness window
  // that replaces the fork's PanelWindow reparents it into the simulated
  // screen, so look it up in the scene by its owner once it exists.
  property Item found: old
  readonly property Item popup: found

  function findPopup(item, depth) {
    if (!item || depth > 8) return null
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) {
      var child = kids[i]
      if (child && child.owner === old && child.borderSpec !== undefined) return child
      var deeper = findPopup(child, depth + 1)
      if (deeper) return deeper
    }
    return null
  }

  // --- MockWeather.js ---
  readonly property var symbols: ["partlycloudy_day", "partlycloudy_day", "lightrain", "rain", "cloudy", "clearsky_night", "fair_night", "cloudy",
    "fair_day", "clearsky_day", "partlycloudy_day", "cloudy", "lightrainshowers_day", "cloudy", "fair_night", "clearsky_night",
    "cloudy", "rain", "heavyrain", "rainshowers_day", "partlycloudy_day", "cloudy", "fair_night", "cloudy"]

  function bundle(start) {
    var series = []
    for (var i = 0; i < 24 * 3; i++) {
      var time = new Date(start.getTime() + i * 3600 * 1000)
      var hour = time.getHours()
      var temperature = 8 + 5 * Math.sin((hour - 9) / 24 * 2 * Math.PI) + (i > 30 ? 2 : 0)
      var symbol = preview.symbols[Math.floor(i / 3) % symbols.length]
      series.push({
        time: time.toISOString(),
        data: {
          instant: { details: { air_temperature: temperature, relative_humidity: 78, ultraviolet_index_clear_sky: 1.4,
            cloud_area_fraction: 62, wind_speed: 4.2, wind_from_direction: 225 } },
          next_1_hours: { summary: { symbol_code: symbol }, details: { precipitation_amount: symbol.indexOf("rain") >= 0 ? 0.6 : 0 } }
        }
      })
    }
    var sun = []
    for (var d = 0; d < 3; d++) {
      var day = new Date(start.getFullYear(), start.getMonth(), start.getDate() + d, 12)
      var key = day.getFullYear() + "-" + String(day.getMonth() + 1).padStart(2, "0") + "-" + String(day.getDate()).padStart(2, "0")
      sun.push({ date: key, sunrise: key + "T07:58:00+01:00", sunset: key + "T16:31:00+01:00" })
    }
    return { forecast: { type: "Feature", properties: { timeseries: series } }, sun: sun,
      fetchedAt: new Date(start.getTime() - 4 * 60000).toISOString(), stale: false }
  }

  function apply() {
    old.report = previewState === "empty" ? null : preview.bundle(new Date(2026, 9, 30, 9, 0, 0))
    old.now = new Date(2026, 9, 30, 9, 0, 0)
    old.errorMessage = previewState === "empty" ? "Choose a location to load weather" : ""
    if (previewState === "settings") old.startEditingLocation()
    else if (old.editingLocation) old.cancelEditingLocation()
  }

  Timer {
    interval: 50
    running: preview.found === old
    repeat: true
    onTriggered: {
      var top = preview
      while (top.parent) top = top.parent
      var popup = preview.findPopup(top, 0)
      if (!popup) return
      popup.anchorItem = preview.anchorItem
      preview.found = popup
    }
  }

  Dev.Panel {
    id: old
    bar: preview.bar
    anchorItem: preview.anchorItem
    settings: ({ units: "metric", animations: true })
    width: 60
    height: 30
    Component.onCompleted: { old.open(); preview.apply() }
  }
  onPreviewStateChanged: apply()
}

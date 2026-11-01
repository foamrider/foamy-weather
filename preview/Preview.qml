import QtQuick
import "../kit"
import ".." as Weather
import "../Model.js" as Model
import "MockWeather.js" as Mock

// Preview states for the foamy-kit preview harness (see foamy-kit README).
// The view gets a mock controller with the Panel's shape: mock data only,
// no processes, no network.
Item {
  id: preview
  required property QtObject bar
  required property Item anchorItem
  property var previewStates: ["forecast", "loading-new-location", "stale", "empty", "error", "settings", "settings-search", "settings-automatic",
    "sky-fog", "sky-overcast-day", "sky-sun", "sky-snow", "sky-night", "sky-storm", "long-text"]
  property string previewState: "forecast"
  property int settleMs: 700
  readonly property Item popup: popup

  // Sky states: the band over different MET conditions (Bergen). The
  // offscreen software renderer draws no shader, so there they show the
  // plain band; a GPU renderer draws the sky.
  readonly property var skies: ({
    "sky-fog": { clock: new Date(2026, 9, 30, 9, 0, 0), now: { symbol: "fog", wind: 0.8, cloud: 100 } },
    "sky-overcast-day": { clock: new Date(2026, 10, 1, 12, 0, 0), now: { symbol: "cloudy", wind: 0.8, cloud: 100 } },
    "sky-sun": { clock: new Date(2026, 5, 21, 13, 0, 0), now: { symbol: "clearsky_day", wind: 3, cloud: 0 } },
    "sky-snow": { clock: new Date(2026, 0, 15, 12, 0, 0), now: { symbol: "heavysnow", wind: 5, cloud: 100 } },
    "sky-night": { clock: new Date(2026, 9, 30, 22, 0, 0), now: { symbol: "clearsky_night", wind: 2, cloud: 0 } },
    "sky-storm": { clock: new Date(2026, 9, 30, 15, 0, 0), now: { symbol: "heavyrainshowersandthunder_day", wind: 18, cloud: 100 } }
  })
  readonly property var sky: skies[previewState] || null
  readonly property date clock: sky ? sky.clock : new Date(2026, 9, 30, 9, 0, 0)
  readonly property var sample: Mock.bundle(clock, sky ? sky.now : null)
  readonly property bool settingsState: previewState.indexOf("settings") === 0

  QtObject {
    id: mock
    readonly property bool contentActive: true
    readonly property bool opened: true
    readonly property bool editingLocation: preview.settingsState
    readonly property var report: preview.previewState === "empty" || preview.previewState === "error" ? null : preview.sample
    readonly property date now: preview.clock
    property int selectedDayIndex: 0
    readonly property var current: Model.currentCondition(report)
    readonly property string units: "metric"
    readonly property bool animations: true
    readonly property var configuredLocationState: ({ name: "Bergen", latitude: 60.39, longitude: 5.32, source: automaticLocation ? "geoclue" : "" })
    readonly property string reportLocation: preview.previewState === "loading-new-location" ? "Oslo"
      : preview.previewState === "long-text" ? "Llanfairpwllgwyngyllgogerychwyrndrobwllllantysiliogogogoch, Anglesey, Wales"
      : (report || preview.previewState === "error" ? "Bergen" : "")
    readonly property bool loading: preview.previewState === "loading-new-location"
    readonly property bool networkReady: true
    readonly property bool savingLocation: false
    // long-text: a condition longer than any catalog's, to show it eliding.
    readonly property string currentDescription: preview.previewState === "long-text" ? "Heavy rain showers and thunder over the fjord"
      : current ? FoamyI18n.t(Model.descriptionForSymbol(current.symbol)) : FoamyI18n.t("No weather data")
    readonly property string statusText: preview.previewState === "loading-new-location" ? FoamyI18n.t("Loading weather for %1…", ["Bergen"]) : ""
    readonly property bool errorIsStale: preview.previewState === "stale"
    readonly property string errorText: preview.previewState === "stale" ? FoamyI18n.t("Showing last known weather")
      : preview.previewState === "error" ? FoamyI18n.t("Weather data is unavailable")
      : preview.previewState === "empty" ? FoamyI18n.t("Choose a location to load weather") : ""
    readonly property bool automaticLocation: preview.previewState === "settings-automatic"
    readonly property bool automaticLabel: automaticLocation
    readonly property bool resolvingLocation: false
    readonly property string dynamicLocationErrorText: automaticLocation ? FoamyI18n.t("Could not find automatic location") : ""
    readonly property bool saving: false
    readonly property string settingsError: ""
    readonly property string saveError: ""
    readonly property bool canRetry: false
    readonly property var locationSuggestions: preview.previewState === "settings-search" ? [
      { name: "Bergen", description: "Vestland, Norway", latitude: 60.39, longitude: 5.32 },
      { name: "Bergen", description: "Lower Saxony, Germany", latitude: 52.81, longitude: 9.96 },
      { name: "Bergen op Zoom", description: "North Brabant, Netherlands", latitude: 51.49, longitude: 4.29 }
    ] : []
    property int suggestionIndex: 0
    readonly property bool searching: false
    readonly property bool searchCompleted: preview.previewState === "settings-search"
    signal searchCleared()
    function windLabel(degrees) { return FoamyI18n.t("Southwesterly") }
    function close() {}
    function switchPanel(direction) {}
    function startEditingLocation() {}
    function cancelEditingLocation() {}
    function refresh(force) {}
    function savePreference(key, value) {}
    function retrySave() {}
    function searchEdited(text) {}
    function moveSuggestion(delta) {}
    function commitLocation() {}
    function pickSuggestion(suggestion) {}
  }

  FoamyPopup {
    id: popup
    anchorItem: preview.anchorItem
    bar: preview.bar
    open: true
    wide: true
    centerOnBar: false
    body: Component {
      Weather.WeatherView { controller: mock }
    }
  }
}

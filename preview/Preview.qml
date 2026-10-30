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
  property var previewStates: ["forecast", "loading-new-location", "stale", "empty", "error", "settings", "settings-search", "settings-automatic"]
  property string previewState: "forecast"
  property int settleMs: 700
  readonly property Item popup: popup

  readonly property date clock: new Date(2026, 9, 30, 9, 0, 0)
  readonly property var sample: Mock.bundle(new Date(2026, 9, 30, 9, 0, 0))
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
    readonly property string reportLocation: preview.previewState === "loading-new-location" ? "Oslo" : (report || preview.previewState === "error" ? "Bergen" : "")
    readonly property bool loading: preview.previewState === "loading-new-location"
    readonly property bool networkReady: true
    readonly property bool savingLocation: false
    readonly property string currentDescription: current ? FoamyI18n.t(Model.descriptionForSymbol(current.symbol)) : FoamyI18n.t("No weather data")
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
    readonly property var lastSave: null
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

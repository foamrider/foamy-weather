pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "kit"
import "kit/FoamyPrefs.js" as Prefs
import "Model.js" as Model
import "Preferences.js" as Preferences

// One per bar (4.5 draws a bar per monitor). Weather data, timers and helper
// processes live once per shell in WeatherService; this Panel owns its popup,
// the location search, and saving settings. WeatherView draws the popup body
// from the properties and functions below (preview/Preview.qml feeds it a
// mock with the same shape).
Panel {
  id: root

  moduleName: "foamy.weather"
  ipcTarget: "foamy.weather"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property bool openedFromHotkey: false
  readonly property var barIdentity: hostWidget || root
  readonly property string entryId: hostWidget && hostWidget.moduleName ? hostWidget.moduleName : root.moduleName
  readonly property alias popup: popup

  // --- shared state ----------------------------------------------------------------
  FoamyMember { id: member; scope: "weather"; demanding: root.opened }
  // Every instance shows the same widget entry; the leader hands its settings over.
  Binding {
    target: WeatherService
    property: "settings"
    value: root.settings
    when: member.isLeader
  }

  readonly property var preferences: Preferences.fromSettings(settings)
  readonly property string units: preferences.units
  readonly property bool animations: preferences.animations
  readonly property bool automaticLocation: WeatherService.automaticLocation
  readonly property var report: WeatherService.report
  readonly property bool reportCurrent: WeatherService.reportCurrent
  readonly property bool loading: WeatherService.loading
  readonly property bool networkReady: WeatherService.networkReady
  readonly property bool resolvingLocation: WeatherService.resolvingLocation
  readonly property var configuredLocationState: WeatherService.configuredLocationState
  readonly property string configuredLocation: WeatherService.configuredLocation
  // The place the shown report belongs to: while a new location loads, the
  // previous report stays up under its own name.
  readonly property string reportLocation: report && !reportCurrent ? String(report.locationName || "") : configuredLocation
  readonly property string errorMessage: WeatherService.errorMessage
  readonly property string errorText: errorMessage ? FoamyI18n.t(errorMessage, WeatherService.errorValues) : ""
  readonly property bool errorIsStale: errorMessage === "Showing last known weather"
  readonly property string statusText: report && !reportCurrent && loading
    ? (configuredLocation ? FoamyI18n.t("Loading weather for %1…", [configuredLocation]) : FoamyI18n.t("Loading weather for the new location…"))
    : ""
  readonly property string dynamicLocationErrorText: WeatherService.dynamicLocationError
    ? FoamyI18n.t(WeatherService.dynamicLocationError, WeatherService.dynamicLocationErrorValues) : ""
  readonly property bool automaticLabel: automaticLocation && String(configuredLocationState.source || "").indexOf("geoclue") === 0

  // Forecast rows exist only while the popup is shown (or fading out).
  readonly property bool contentActive: root.opened || popup.visible
  property date now: new Date()
  property int selectedDayIndex: 0

  readonly property var current: Model.currentCondition(report)
  readonly property string conditionIcon: current ? Model.iconForSymbol(current.symbol) : "󰖐"
  readonly property string currentTemperature: current ? Preferences.temperature(current.temperature, units, FoamyI18n.number) : "--"
  readonly property string barLabel: conditionIcon + " " + currentTemperature
  readonly property string currentDescription: current ? FoamyI18n.t(Model.descriptionForSymbol(current.symbol)) : FoamyI18n.t("No weather data")

  // --- settings ----------------------------------------------------------------------
  property bool editingLocation: false
  property bool saving: false
  property bool savingLocation: false
  property string settingsError: ""
  property var lastSave: null
  property var locationSuggestions: []
  property int suggestionIndex: 0
  property string searchText: ""
  property bool searchCompleted: false
  property string geocodePendingQuery: ""
  property string geocodeActiveQuery: ""
  readonly property bool searching: geocodeProc.running
  readonly property string locationScript: WeatherService.localPath(Qt.resolvedUrl("scripts/weather-location.sh"))

  signal searchCleared()

  function windLabel(degrees) {
    var direction = Model.windDirection(degrees)
    var names = { N: "Northerly", NØ: "Northeasterly", Ø: "Easterly", SØ: "Southeasterly", S: "Southerly", SV: "Southwesterly", V: "Westerly", NV: "Northwesterly" }
    return names[direction] ? FoamyI18n.t(names[direction]) : direction
  }

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    showPopup()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    showPopup()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function showPopup() {
    now = new Date()
    root.controller.show()
    WeatherService.reloadLocations()
    WeatherService.refresh(false)
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    if (editingLocation) cancelEditingLocation()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function refresh(force) {
    now = new Date()
    WeatherService.refresh(force === true)
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function notifySummary() {
    if (!current) {
      root.openFromHotkey()
      return
    }
    var wind = Preferences.wind(current.windSpeed, units, FoamyI18n.t, FoamyI18n.number)
    var windDirection = windLabel(current.windDirection)
    var body = currentDescription + " · " + currentTemperature
      + "\n" + FoamyI18n.t("Wind") + " " + wind + (windDirection ? " " + windDirection : "")
      + " · " + FoamyI18n.t("Humidity") + " " + (current.humidity === null ? "—" : FoamyI18n.number(current.humidity) + "%")
    // A failed reverse lookup can leave a coordinate pair as the location label.
    var headlineLocation = reportLocation
    if (!headlineLocation || /^-?[0-9.]+,\s*-?[0-9.]+$/.test(headlineLocation)) headlineLocation = FoamyI18n.t("selected location")
    Quickshell.execDetached([
      "omarchy-notification-send", "-g", conditionIcon,
      FoamyI18n.t("Weather in %1", [headlineLocation]), body
    ])
  }

  function savePreference(key, value) {
    if (saving) return
    settingsError = ""
    lastSave = { key: key, value: value }
    var result = Prefs.save(root.bar, root.entryId, Preferences.fields, root.settings, key, value)
    if (!result.ok) {
      settingsError = result.error
      return
    }
    if (key === "automaticLocation" && value === true) clearSearch()
    if (result.command.length === 0) {
      lastSave = null
      return
    }
    saving = true
    preferencesSaveProc.command = result.command
    preferencesSaveProc.running = true
  }

  function retrySave() {
    if (lastSave) savePreference(lastSave.key, lastSave.value)
  }

  function clearSearch() {
    geocodeDebounce.stop()
    geocodeProc.running = false
    geocodePendingQuery = ""
    geocodeActiveQuery = ""
    locationSuggestions = []
    searchCompleted = false
    searchText = ""
    root.searchCleared()
  }

  function startEditingLocation() {
    editingLocation = true
    settingsError = ""
    lastSave = null
    clearSearch()
  }

  function cancelEditingLocation() {
    editingLocation = false
    settingsError = ""
    lastSave = null
    clearSearch()
  }

  // The search field's text changed by typing or paste.
  function searchEdited(text) {
    geocodeDebounce.stop()
    geocodeProc.running = false
    locationSuggestions = []
    searchCompleted = false
    settingsError = ""
    searchText = String(text || "")
    if (searchText.trim().length >= 2) geocodeDebounce.restart()
  }

  function moveSuggestion(delta) {
    suggestionIndex = Math.max(0, Math.min(locationSuggestions.length - 1, suggestionIndex + delta))
  }

  function commitLocation() {
    var location = Model.locationCommit(searchText, locationSuggestions, suggestionIndex)
    if (location.latitude === null || location.longitude === null) {
      settingsError = "Choose a location from the search results"
      return
    }
    pickSuggestion(location)
  }

  function pickSuggestion(suggestion) {
    if (!suggestion || savingLocation || automaticLocation) return
    savingLocation = true
    locationSaveProc.command = [locationScript, "--set"]
    locationSaveProc.requestInput = JSON.stringify({ name: suggestion.name,
      latitude: suggestion.latitude, longitude: suggestion.longitude }) + "\n"
    locationSaveProc.stdinEnabled = true
    locationSaveProc.running = true
  }

  function requestGeocode() {
    if (!editingLocation || automaticLocation) return
    var query = searchText.trim()
    if (query.length < 2) {
      locationSuggestions = []
      return
    }
    geocodePendingQuery = query
    if (!geocodeProc.running) startGeocode()
  }

  function geocodeLanguage() {
    var language = String(FoamyI18n.language || "en").toLowerCase()
    if (language === "nb" || language === "nn") return "no"
    return /^[a-z]{2}$/.test(language) ? language : "en"
  }

  function startGeocode() {
    if (!editingLocation || automaticLocation || geocodePendingQuery.length < 2) return
    geocodeActiveQuery = geocodePendingQuery
    // The typed place goes to curl on stdin, not in its (procfs-visible) argv.
    geocodeProc.requestInput = 'url = "https://geocoding-api.open-meteo.com/v1/search?name='
      + encodeURIComponent(geocodeActiveQuery) + "&count=5&language=" + geocodeLanguage() + '&format=json"\n'
    geocodeProc.stdinEnabled = true
    geocodeProc.running = true
  }

  Timer {
    // Ages and the hourly rows follow the clock only while someone looks.
    interval: 60 * 1000
    running: root.opened
    repeat: true
    onTriggered: root.now = new Date()
  }

  Timer {
    id: geocodeDebounce
    interval: 300
    onTriggered: root.requestGeocode()
  }

  Process {
    id: geocodeProc
    property string requestInput: ""
    command: ["curl", "-fsS", "--max-time", "5", "--config", "-"]
    onStarted: {
      write(requestInput)
      stdinEnabled = false
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.editingLocation && root.geocodeActiveQuery === root.searchText.trim())
        root.settingsError = "Could not search for a location"
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root.editingLocation || root.automaticLocation || root.geocodeActiveQuery !== root.searchText.trim()) return
        try {
          var response = JSON.parse(text)
          if (response.error) throw new Error("Geocoder rejected query")
        } catch (error) {
          root.settingsError = "Could not search for a location"
          return
        }
        root.locationSuggestions = Model.parseGeocodingResults(text)
        root.searchCompleted = true
        root.suggestionIndex = 0
      }
    }
  }

  Process {
    id: locationSaveProc
    property string requestInput: ""
    onStarted: {
      write(requestInput)
      stdinEnabled = false
    }
    onExited: function(exitCode) {
      root.savingLocation = false
      if (exitCode !== 0) {
        root.settingsError = "Could not save the location"
        return
      }
      WeatherService.reloadLocations()
      root.clearSearch()
    }
  }

  Process {
    id: preferencesSaveProc
    onExited: function(exitCode) {
      root.saving = false
      if (exitCode !== 0) {
        root.settingsError = "Could not save settings"
        return
      }
      root.lastSave = null
    }
  }

  FoamyIpc {
    target: "foamy.weather"
    enabled: member.isLeader

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    // Open first: the settings page is built with the popup body.
    function edit(): void { root.openFromHotkey(); root.startEditingLocation() }
    function refresh(): void { root.refresh(true) }
  }

  FoamyPopup {
    id: popup
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    wide: true
    // Follow the widget like 4.5's weather panel instead of the bar centre.
    centerOnBar: false
    body: Component {
      WeatherView {
        controller: root
      }
    }
  }
}

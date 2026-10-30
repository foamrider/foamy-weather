pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Networking
import "kit"
import "Model.js" as Model
import "Preferences.js" as Preferences

// Weather state for the whole shell. 4.5 draws a bar (and so a Panel) per
// monitor; this plugin-local singleton is shared by all of them, so there is
// one forecast fetch, one GeoClue lookup and one set of location-file
// watchers per shell. Panels read it, ask it to refresh, and the first live
// Panel (FoamyMember leader of scope "weather") feeds it the widget settings.
QtObject {
  id: root

  // --- inputs ------------------------------------------------------------------
  property var settings: ({})
  readonly property var preferences: Preferences.fromSettings(settings)
  readonly property bool automaticLocation: preferences.automaticLocation
  readonly property string requestUserAgent: preferences.requestUserAgent
  // Nothing runs until a bar widget exists (and stops if the last one goes).
  readonly property bool active: FoamyShared.memberCount("weather") > 0

  readonly property string fetchScript: localPath(Qt.resolvedUrl("scripts/weather-fetch.sh"))
  readonly property string locationResolverScript: localPath(Qt.resolvedUrl("scripts/weather-resolve-location.sh"))
  readonly property string configRoot: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/omarchy"

  // --- report --------------------------------------------------------------------
  // The last good report. It stays while a new location loads; `report.query`
  // says which coordinates it is for and `report.locationName` names them.
  property var report: null
  readonly property bool reportCurrent: !!report && report.query === coordinateQuery
  // Translation key plus its %n values (scripts send English keys).
  property string errorMessage: ""
  property var errorValues: []
  property bool loading: false
  property int retries: 0
  property int weatherGeneration: 0
  property bool weatherRestart: false

  // --- location ------------------------------------------------------------------
  property var storedLocationState: ({ name: "", latitude: null, longitude: null })
  property var localLocationState: ({ name: "", latitude: null, longitude: null })
  property var dynamicLocationState: ({ name: "", latitude: null, longitude: null, source: "" })
  property string dynamicLocationError: ""
  property var dynamicLocationErrorValues: []
  property int locationRetries: 0
  property int locationGeneration: 0
  readonly property bool resolvingLocation: locationProc.running
  readonly property bool manualLocationEnabled: localLocationState.latitude !== null
    && localLocationState.longitude !== null
  readonly property var configuredLocationState: automaticLocation ? dynamicLocationState
    : (manualLocationEnabled ? localLocationState : storedLocationState)
  readonly property string configuredLocation: configuredLocationState.name
  readonly property bool hasCoordinates: !isNaN(parseFloat(String(configuredLocationState.latitude)))
    && !isNaN(parseFloat(String(configuredLocationState.longitude)))
  readonly property string coordinateQuery: hasCoordinates
    ? String(configuredLocationState.latitude) + "," + String(configuredLocationState.longitude) : ""

  // --- network -------------------------------------------------------------------
  // WARP can leave NetworkManager's external probe at Limited while routed
  // internet access is working, so only block truly offline/portal states.
  readonly property bool networkConnected: Networking.connectivity === NetworkConnectivity.Full
    || Networking.connectivity === NetworkConnectivity.Limited
  property bool networkSettled: false
  readonly property bool networkReady: active && networkConnected && networkSettled
  onNetworkConnectedChanged: networkSettled = false

  onNetworkReadyChanged: {
    retryTimer.stop()
    locationRetryTimer.stop()
    retries = 0
    locationRetries = 0
  }

  onCoordinateQueryChanged: {
    retries = 0
    retryTimer.stop()
    // Keep the previous report visible until the new one arrives (panels
    // label it with its own place). A fetch already running is for the old
    // place: drop its result and start again once it has gone.
    weatherGeneration++
    if (weatherProc.running) {
      weatherRestart = true
      weatherProc.running = false
    } else {
      Qt.callLater(function() { root.refresh(false) })
    }
  }

  onAutomaticLocationChanged: {
    locationRetryTimer.stop()
    locationRetries = 0
    locationGeneration++
    locationProc.running = false
    dynamicLocationError = ""
    dynamicLocationErrorValues = []
    if (automaticLocation) Qt.callLater(function() { root.resolveLocation(false) })
  }

  onActiveChanged: if (active) reloadLocations()

  function localPath(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0) value = value.slice(7)
    return decodeURIComponent(value)
  }

  function reloadLocations() {
    locationFile.reload()
    localLocationFile.reload()
  }

  function setError(key, values) {
    errorMessage = String(key || "")
    errorValues = Array.isArray(values) ? values.map(String) : []
  }

  function refresh(force) {
    if (!networkReady) {
      loading = false
      return
    }
    if (!hasCoordinates) {
      loading = false
      setError("Choose a location to load weather")
      return
    }
    if (weatherProc.running) return

    loading = true
    setError("")
    weatherRestart = false
    weatherProc.generation = weatherGeneration
    weatherProc.query = coordinateQuery
    weatherProc.locationName = configuredLocation
    weatherProc.command = force ? [fetchScript, "--force"] : [fetchScript]
    // Process arguments are visible to other users through procfs; use the private pipe.
    weatherProc.requestInput = String(configuredLocationState.latitude) + "\n"
      + String(configuredLocationState.longitude) + "\n"
    if (requestUserAgent)
      weatherProc.command = ["env", "MET_WEATHER_USER_AGENT=" + requestUserAgent].concat(weatherProc.command)
    weatherProc.stdinEnabled = true
    weatherProc.running = true
  }

  function resolveLocation(force) {
    if (!networkReady || !automaticLocation || locationProc.running) return
    locationProc.generation = locationGeneration
    locationProc.command = force ? [locationResolverScript, "--force"] : [locationResolverScript]
    if (requestUserAgent)
      locationProc.command = ["env", "WEATHER_LOCATION_USER_AGENT=" + requestUserAgent].concat(locationProc.command)
    locationProc.running = true
  }

  function scheduleRetry() {
    loading = false
    if (!networkReady || retries >= 3) return
    retryTimer.interval = 2500 * Math.pow(2, retries)
    retries++
    retryTimer.restart()
  }

  // A finished fetch: ignore it if the location changed meanwhile.
  function finishWeather(raw, generation, query, locationName) {
    if (generation !== weatherGeneration) {
      loading = false
      return
    }
    raw = String(raw || "").trim()
    try {
      var response = JSON.parse(raw || "{}")
      if (response.error) {
        setError(response.error, response.values)
        scheduleRetry()
        return
      }
    } catch (e) {
      setError("Could not read weather data")
      scheduleRetry()
      return
    }

    var parsed = Model.parseBundle(raw)
    if (!parsed) {
      setError("Invalid response from MET Norway")
      scheduleRetry()
      return
    }
    parsed.query = query
    parsed.locationName = locationName
    report = parsed
    loading = false
    setError(parsed.stale ? "Showing last known weather" : "")
    if (parsed.stale) scheduleRetry()
    else retries = 0
  }

  function finishLocation(raw, generation) {
    if (generation !== locationGeneration) return
    var resolved = Model.parseResolvedLocation(raw)
    if (resolved.latitude === null || resolved.longitude === null) {
      dynamicLocationError = resolved.error || "Could not read automatic location"
      dynamicLocationErrorValues = resolved.errorValues
      if (!hasCoordinates) setError(dynamicLocationError, dynamicLocationErrorValues)
      // Automatic location needs its own recovery; weather cannot load without it.
      if (networkReady && automaticLocation && locationRetries < 3) {
        locationRetryTimer.interval = 2500 * Math.pow(2, locationRetries++)
        locationRetryTimer.restart()
      }
      return
    }

    dynamicLocationState = resolved
    locationRetries = 0
    locationRetryTimer.stop()
    dynamicLocationError = ""
    dynamicLocationErrorValues = []
    if (automaticLocation && !loading && errorMessage !== "Showing last known weather") setError("")
  }

  property FileView locationFile: FileView {
    path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/settings/weather.json"
    watchChanges: root.active
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.storedLocationState = Model.parseLocationFile(text())
    onLoadFailed: root.storedLocationState = Model.parseLocationFile("")
  }

  property FileView localLocationFile: FileView {
    path: root.configRoot + "/weather-location.local.json"
    watchChanges: root.active
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.localLocationState = Model.parseLocationFile(text())
    onLoadFailed: root.localLocationState = Model.parseLocationFile("")
  }

  property Timer networkSettleTimer: Timer {
    // NetworkManager can report a connection before DNS and routes are usable.
    interval: 2000
    running: root.active && root.networkConnected && !root.networkSettled
    onTriggered: root.networkSettled = true
  }

  property Timer refreshTimer: Timer {
    interval: root.preferences.refreshMinutes * 60 * 1000
    // Start after the connection settles, including Limited connectivity on VPNs.
    running: root.networkReady
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh(false)
  }

  property Timer locationTimer: Timer {
    interval: root.preferences.locationRefreshMinutes * 60 * 1000
    running: root.networkReady && root.automaticLocation
    repeat: true
    triggeredOnStart: true
    onTriggered: root.resolveLocation(false)
  }

  property Timer retryTimer: Timer {
    interval: 2500
    onTriggered: root.refresh(true)
  }

  property Timer locationRetryTimer: Timer {
    onTriggered: root.resolveLocation(true)
  }

  property Process weatherProc: Process {
    property string requestInput: ""
    property int generation: 0
    property string query: ""
    property string locationName: ""
    onStarted: {
      write(requestInput)
      stdinEnabled = false
    }
    onExited: {
      if (root.weatherRestart) {
        root.weatherRestart = false
        Qt.callLater(function() { root.refresh(false) })
      }
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.finishWeather(text, root.weatherProc.generation, root.weatherProc.query, root.weatherProc.locationName)
    }
  }

  property Process locationProc: Process {
    property int generation: 0
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.finishLocation(text, root.locationProc.generation)
    }
  }
}

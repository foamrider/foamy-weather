pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Networking
import "kit"
import "kit/FoamyNative.js" as FoamyNative
import "kit/FoamyPrefs.js" as Prefs
import "Model.js" as Model
import "Preferences.js" as Preferences

// Weather state for the whole shell. 4.5 draws a bar (and so a Panel) per
// monitor; this plugin-local singleton is shared by all of them and by the
// service entry (Service.qml), so there is one forecast fetch, one GeoClue
// lookup and one set of location-file watchers per shell. Panels read it, ask
// it to refresh, and the first live Panel (FoamyMember leader of scope
// "weather") feeds it the widget settings; without a widget the service
// entry feeds it the plugin's shell.json entry. It runs while a widget exists
// or for 30 minutes after the last current() call.
QtObject {
  id: root

  // --- inputs ------------------------------------------------------------------
  // The leader Panel's settings win while a widget exists (they include a
  // save not yet written back); otherwise the service entry's.
  property var widgetSettings: ({})
  property var serviceSettings: ({})
  readonly property bool widgetPresent: FoamyShared.memberCount("weather") > 0
  readonly property var settings: widgetPresent ? widgetSettings : serviceSettings
  readonly property var preferences: Prefs.values(Preferences.fields, settings)
  readonly property bool automaticLocation: preferences.automaticLocation
  // Trimmed after the schema read: the scripts only use their identifying
  // default (MET's terms) when the agent is empty, so a blank one must be.
  readonly property string requestUserAgent: preferences.requestUserAgent.trim()
  // Nothing runs until a bar widget exists or current() asks (and it stops
  // when the last widget has gone and no call came for 30 minutes).
  property bool onDemand: false
  readonly property bool active: widgetPresent || onDemand

  // The service entry while it is loaded: it owns the IPC target then.
  property QtObject host: null
  // The leader Panel, so the service's IPC can open its popup.
  property QtObject widgetPanel: null

  // The helper is bin/<arch>/foamy-weather-helper under this directory.
  readonly property string pluginDir: FoamyNative.localPath(Qt.resolvedUrl("."))
  // No helper for this CPU (exit 126/127): say so once and stop starting it.
  property bool helperUnavailable: false
  readonly property string settingsRoot: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/settings"

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
  // Test-only: runtime tests set true or false to stand in for NetworkManager
  // (the test harness has no system bus); null, always in the shell, follows it.
  property var testNetworkConnected: null
  // WARP can leave NetworkManager's external probe at Limited while routed
  // internet access is working, so only block truly offline/portal states.
  readonly property bool networkConnected: testNetworkConnected !== null ? testNetworkConnected === true
    : (Networking.connectivity === NetworkConnectivity.Full || Networking.connectivity === NetworkConnectivity.Limited)
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

  onActiveChanged: if (active) loadLocations()
  Component.onCompleted: if (active) loadLocations()

  // The helper (the only writer) first moves a searched place older versions
  // kept in config; the files are read again once it has.
  function loadLocations() {
    reloadLocations()
    if (!locationMigrateProc.running) locationMigrateProc.running = true
  }

  function reloadLocations() {
    locationFile.reload()
    localLocationFile.reload()
  }

  // A current() call: start on demand and stay up 30 minutes after it.
  function touch() {
    demandTimer.restart()
    onDemand = true
  }

  // Starting, loading, retrying, resolving the automatic location, or
  // waiting for the network to settle: an answer is on its way.
  readonly property bool pending: active && (loading || retryTimer.running
    || locationMigrateProc.running || resolvingLocation || locationRetryTimer.running
    || (networkConnected && !networkSettled))

  // The `current()` IPC reply (compact JSON; Model.currentReply). Never
  // waits: an idle service starts and answers "pending" until it has data.
  function currentReply() {
    var starting = !active
    touch()
    return JSON.stringify(Model.currentReply({
      report: report,
      reportCurrent: reportCurrent,
      units: preferences.units,
      convert: Preferences.converted,
      translate: function(key) { return FoamyI18n.t(key) },
      now: new Date(),
      // Just started: the bindings above haven't seen the network yet.
      pending: starting || pending,
      unsupported: helperUnavailable || errorMessage === Model.HTTPS_UNSUPPORTED,
      hasCoordinates: hasCoordinates,
      networkConnected: networkConnected
    }))
  }

  function setError(key, values) {
    errorMessage = String(key || "")
    errorValues = Array.isArray(values) ? values.map(String) : []
  }

  // A helper exit of 126/127: no binary for this CPU. Report it and stop
  // the retries; nothing starts the helper again.
  function helperExited(exitCode) {
    if (!FoamyNative.unavailable(exitCode)) return false
    helperUnavailable = true
    retryTimer.stop()
    locationRetryTimer.stop()
    loading = false
    setError(FoamyNative.UNAVAILABLE_TEXT)
    dynamicLocationError = FoamyNative.UNAVAILABLE_TEXT
    dynamicLocationErrorValues = []
    return true
  }

  function refresh(force) {
    if (!networkReady || helperUnavailable) {
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
    weatherProc.command = FoamyNative.command(pluginDir, Model.HELPER, force ? ["fetch", "--force"] : ["fetch"])
    // Process arguments are visible to other users through procfs; use the private pipe.
    weatherProc.requestInput = String(configuredLocationState.latitude) + "\n"
      + String(configuredLocationState.longitude) + "\n"
    if (requestUserAgent)
      weatherProc.command = ["env", "MET_WEATHER_USER_AGENT=" + requestUserAgent].concat(weatherProc.command)
    weatherProc.stdinEnabled = true
    weatherProc.running = true
  }

  function resolveLocation(force) {
    if (!networkReady || !automaticLocation || locationProc.running || helperUnavailable) return
    locationProc.generation = locationGeneration
    locationProc.command = FoamyNative.command(pluginDir, Model.HELPER,
      force ? ["resolve-location", "--force"] : ["resolve-location"])
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
    if (generation !== weatherGeneration || helperUnavailable) {
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
    if (generation !== locationGeneration || helperUnavailable) return
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

  // The searched place (localLocationFile) first, then Omarchy's own weather
  // location; both are state.
  property FileView locationFile: FileView {
    path: root.settingsRoot + "/weather.json"
    watchChanges: root.active
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.storedLocationState = Model.parseLocationFile(text())
    onLoadFailed: root.storedLocationState = Model.parseLocationFile("")
  }

  property FileView localLocationFile: FileView {
    path: root.settingsRoot + "/foamy-weather-location.json"
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

  property Timer demandTimer: Timer {
    interval: 30 * 60 * 1000
    onTriggered: root.onDemand = false
  }

  property Timer retryTimer: Timer {
    interval: 2500
    onTriggered: root.refresh(true)
  }

  property Timer locationRetryTimer: Timer {
    onTriggered: root.resolveLocation(true)
  }

  // No outer timeout: the helper bounds each request itself (3 s to connect,
  // 10 s for the forecast, 8 s for each of up to three sunrise requests, which
  // stop at the first failure), so a fetch ends within about 35 s and
  // `loading` always settles in finishWeather.
  property Process weatherProc: Process {
    property string requestInput: ""
    property int generation: 0
    property string query: ""
    property string locationName: ""
    onStarted: {
      write(requestInput)
      stdinEnabled = false
    }
    onExited: function(exitCode) {
      if (root.helperExited(exitCode)) return
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

  property Process locationMigrateProc: Process {
    command: FoamyNative.command(root.pluginDir, Model.HELPER, ["location", "--migrate"])
    onExited: function(exitCode) {
      root.helperExited(exitCode)
      root.reloadLocations()
    }
  }

  property Process locationProc: Process {
    property int generation: 0
    onExited: function(exitCode) { root.helperExited(exitCode) }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.finishLocation(text, root.locationProc.generation)
    }
  }
}

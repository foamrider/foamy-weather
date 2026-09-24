import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Networking
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "Preferences.js" as Preferences

Panel {
  id: root
  moduleName: "foamy.weather"
  ipcTarget: "foamy.weather"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property bool openedFromHotkey: false
  readonly property var barIdentity: hostWidget || root
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string iconFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string fontFamily: "sans-serif"
  readonly property color secondaryForeground: Qt.tint(Color.popups.background, Qt.rgba(foreground.r, foreground.g, foreground.b, 0.76))
  readonly property color outlineColor: Qt.tint(Color.popups.background, Qt.rgba(foreground.r, foreground.g, foreground.b, 0.22))
  readonly property color cardColor: Qt.tint(Color.popups.background, Qt.rgba(foreground.r, foreground.g, foreground.b, 0.055))
  readonly property color selectedCardColor: Qt.tint(Color.popups.background, Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.20))
  readonly property bool lightTheme: Color.popups.background.r + Color.popups.background.g + Color.popups.background.b > 1.5
  readonly property color rainColor: lightTheme ? "#087d84" : "#94e2d5"
  readonly property var displayHours: selectedDay ? selectedDay.hours : []
  readonly property string hourSummary: {
    for (var i = 0; i < displayHours.length; i++) {
      if (displayHours[i].precipitation > 0) return root.tr("Nedbør fra kl. ") + displayHours[i].time.slice(0, 2)
    }
    return root.tr("Opphold i perioden")
  }
  readonly property string uvLabel: !current || current.uvIndex === null ? "—"
    : current.uvIndex < 3 ? root.tr("Lav") : current.uvIndex < 6 ? root.tr("Moderat") : current.uvIndex < 8 ? root.tr("Høy") : root.tr("Svært høy")
  function windLabel(degrees) {
    var direction = Model.windDirection(degrees)
    var names = { N: root.tr("Nordlig"), NØ: root.tr("Nordøstlig"), Ø: root.tr("Østlig"), SØ: root.tr("Sørøstlig"), S: root.tr("Sørlig"), SV: root.tr("Sørvestlig"), V: root.tr("Vestlig"), NV: root.tr("Nordvestlig") }
    return names[direction] || direction
  }

  readonly property string configRoot: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/omarchy"
  property string widgetId: ""
  readonly property var preferences: Preferences.fromSettings(settings, Qt.locale().name)
  readonly property string language: preferences.language
  readonly property string units: preferences.units
  readonly property bool automaticLocation: preferences.automaticLocation
  readonly property bool preferencesReady: widgetId !== ""
  property string settingsError: ""
  property bool searchCompleted: false

  function tr(value) { return Preferences.text(value, language) }
  function temperature(value) { return Preferences.temperature(value, units) }
  function precipitation(value) { return Preferences.precipitation(value, units) }
  function windSpeed(value) { return Preferences.wind(value, units, language) }

  function savePreference(name, value) {
    if (preferencesSaveProc.running) return
    if (!widgetId) {
      settingsError = "Kunne ikke lese innstillingene"
      return
    }
    settingsError = ""
    // Let the shell mutate its live config; writing shell.json directly races it.
    preferencesSaveProc.command = [localPathFromUrl(Qt.resolvedUrl("scripts/weather-preferences.sh")), widgetId, name, JSON.stringify(value)]
    preferencesSaveProc.running = true
  }

  property var report: null
  property string errorMessage: ""
  property bool loading: false
  property int retries: 0
  property int selectedDayIndex: 0
  property date now: new Date()

  property var storedLocationState: ({ name: "", latitude: null, longitude: null })
  property var localLocationState: ({ name: "", latitude: null, longitude: null })
  property var dynamicLocationState: ({ name: "", latitude: null, longitude: null, source: "" })
  property string dynamicLocationError: ""
  readonly property bool manualLocationEnabled: localLocationState.latitude !== null
    && localLocationState.longitude !== null
  readonly property var configuredLocationState: automaticLocation ? dynamicLocationState
    : (manualLocationEnabled ? localLocationState : storedLocationState)
  readonly property string configuredLocation: configuredLocationState.name
  readonly property bool hasCoordinates: !isNaN(parseFloat(String(configuredLocationState.latitude)))
    && !isNaN(parseFloat(String(configuredLocationState.longitude)))
  readonly property string coordinateQuery: hasCoordinates
    ? String(configuredLocationState.latitude) + "," + String(configuredLocationState.longitude) : ""

  property bool editingLocation: false
  property bool savingLocation: false
  property var locationSuggestions: []
  property int suggestionIndex: 0
  property string geocodePendingQuery: ""
  property string geocodeActiveQuery: ""

  readonly property var current: Model.currentCondition(report)
  readonly property var forecastDays: Model.forecastDays(report, now)
  readonly property var selectedDay: forecastDays.length
    ? forecastDays[Math.max(0, Math.min(selectedDayIndex, forecastDays.length - 1))] : null
  readonly property string conditionIcon: current ? Model.iconForSymbol(current.symbol) : "󰖐"
  readonly property string currentTemperature: current ? root.temperature(current.temperature) : "--"
  readonly property string barLabel: conditionIcon + " " + currentTemperature
  readonly property string currentDescription: current ? tr(Model.descriptionForSymbol(current.symbol)) : root.tr("Ingen værdata")
  readonly property string updatedText: report && report.fetchedAt ? Preferences.age(report.fetchedAt, now, language) : ""

  readonly property string requestUserAgent: String(setting("requestUserAgent", ""))
  readonly property string fetchScript: localPathFromUrl(Qt.resolvedUrl("scripts/weather-fetch.sh"))
  readonly property string locationScript: localPathFromUrl(Qt.resolvedUrl("scripts/weather-location.sh"))
  readonly property string locationResolverScript: localPathFromUrl(Qt.resolvedUrl("scripts/weather-resolve-location.sh"))
  readonly property int refreshMinutes: Math.max(5, parseInt(setting("refreshMinutes", 30), 10) || 30)
  readonly property int locationRefreshMinutes: Math.max(5, parseInt(setting("locationRefreshMinutes", 15), 10) || 15)
  // WARP can leave NetworkManager's external probe at Limited while routed
  // internet access is working, so only block truly offline/portal states.
  readonly property bool networkReady: Networking.connectivity === NetworkConnectivity.Full
    || Networking.connectivity === NetworkConnectivity.Limited

  onCoordinateQueryChanged: {
    retries = 0
    report = null
    weatherProc.running = false
    Qt.callLater(function() { root.refresh(false) })
  }

  onAutomaticLocationChanged: {
    locationProc.running = false
    dynamicLocationError = ""
    if (automaticLocation) Qt.callLater(function() { root.resolveLocation(false) })
  }

  onForecastDaysChanged: {
    if (selectedDayIndex >= forecastDays.length) selectedDayIndex = Math.max(0, forecastDays.length - 1)
  }

  function localPathFromUrl(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0) value = value.slice(7)
    return decodeURIComponent(value)
  }

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    locationFile.reload()
    localLocationFile.reload()
    root.refresh(false)
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    locationFile.reload()
    localLocationFile.reload()
    root.refresh(false)
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
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

  function refresh(force) {
    now = new Date()
    if (!networkReady) {
      loading = false
      return
    }
    if (!hasCoordinates) {
      loading = false
      errorMessage = "Velg et sted for å hente værdata"
      return
    }
    if (weatherProc.running) return

    loading = true
    errorMessage = ""
    weatherProc.command = force
      ? [fetchScript, String(configuredLocationState.latitude), String(configuredLocationState.longitude), "--force"]
      : [fetchScript, String(configuredLocationState.latitude), String(configuredLocationState.longitude)]
    if (requestUserAgent)
      weatherProc.command = ["env", "MET_WEATHER_USER_AGENT=" + requestUserAgent].concat(weatherProc.command)
    weatherProc.running = true
  }

  function resolveLocation(force) {
    if (!preferencesReady || !networkReady || !automaticLocation || locationProc.running) return
    locationProc.command = force ? [locationResolverScript, "--force"] : [locationResolverScript]
    if (requestUserAgent)
      locationProc.command = ["env", "WEATHER_LOCATION_USER_AGENT=" + requestUserAgent].concat(locationProc.command)
    locationProc.running = true
  }

  function scheduleRetry() {
    loading = false
    if (retries >= 3) return
    retries++
    retryTimer.restart()
  }

  function notifySummary() {
    if (!current) {
      root.openFromHotkey()
      return
    }
    var wind = windSpeed(current.windSpeed)
    var windDirection = windLabel(current.windDirection)
    var body = currentDescription + " · " + currentTemperature
      + "\n" + tr("Vind") + " " + wind + (windDirection ? " " + windDirection : "")
      + " · " + tr("Luftfuktighet") + " " + (current.humidity === null ? "—" : current.humidity + "%")
    Quickshell.execDetached([
      "omarchy-notification-send", "-g", conditionIcon,
      root.tr("Været i ") + (configuredLocation || root.tr("valgt sted")), body
    ])
  }

  function clearSearch() {
    geocodeDebounce.stop()
    geocodeProc.running = false
    geocodePendingQuery = ""
    geocodeActiveQuery = ""
    locationSuggestions = []
    searchCompleted = false
  }

  function startEditingLocation() {
    editingLocation = true
    settingsError = ""
    clearSearch()
    locationField.text = ""
    weatherScroll.contentY = 0
    // Opening settings must not focus the field or query the geocoder.
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function cancelEditingLocation() {
    editingLocation = false
    settingsError = ""
    clearSearch()
    weatherScroll.contentY = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function commitLocation() {
    var location = Model.locationCommit(locationField.text, locationSuggestions, suggestionIndex)
    if (location.latitude === null || location.longitude === null) {
      settingsError = "Velg et sted fra søkeresultatene"
      return
    }
    pickSuggestion(location)
  }

  function pickSuggestion(suggestion) {
    if (!suggestion || savingLocation || automaticLocation) return
    savingLocation = true
    locationSaveProc.command = [
      locationScript, "--set", suggestion.name,
      String(suggestion.latitude), String(suggestion.longitude)
    ]
    locationSaveProc.running = true
  }

  function requestGeocode() {
    if (!editingLocation || automaticLocation) return
    var query = locationField.text.trim()
    if (query.length < 2) {
      locationSuggestions = []
      return
    }
    geocodePendingQuery = query
    if (!geocodeProc.running) startGeocode()
  }

  function startGeocode() {
    if (!editingLocation || automaticLocation || geocodePendingQuery.length < 2) return
    geocodeActiveQuery = geocodePendingQuery
    geocodeProc.command = [
      "curl", "-fsS", "--max-time", "5",
      "https://geocoding-api.open-meteo.com/v1/search?name="
        + encodeURIComponent(geocodeActiveQuery) + "&count=5&language=" + (root.language === "nb" ? "no" : "en") + "&format=json"
    ]
    geocodeProc.running = true
  }

  function dayLabel(day, index) {
    if (!day) return ""
    if (index === 0) return root.tr("I dag")
    if (index === 1) return root.tr("I morgen")
    var label = Qt.locale(language === "nb" ? "nb_NO" : "en_US").toString(day.dateObject, "dddd")
    return label.charAt(0).toUpperCase() + label.slice(1)
  }

  function shortDate(day) {
    return day ? Qt.locale(language === "nb" ? "nb_NO" : "en_US").toString(day.dateObject, "d. MMM") : ""
  }

  function timeLabel(value) {
    return Model.formatIsoTime(value) || "—"
  }

  FileView {
    id: locationFile
    path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/settings/weather.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.storedLocationState = Model.parseLocationFile(text())
    onLoadFailed: root.storedLocationState = Model.parseLocationFile("")
  }

  FileView {
    id: localLocationFile
    path: root.configRoot + "/weather-location.local.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.localLocationState = Model.parseLocationFile(text())
    onLoadFailed: root.localLocationState = Model.parseLocationFile("")
  }

  Timer {
    interval: 1500
    running: true
    onTriggered: locationFile.reload()
  }

  Timer {
    interval: 60 * 1000
    running: true
    repeat: true
    onTriggered: root.now = new Date()
  }

  Timer {
    interval: root.refreshMinutes * 60 * 1000
    // Starting on Full connectivity avoids accepting stale cache before
    // NetworkManager finishes bringing the boot-time connection online.
    running: root.networkReady
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh(false)
  }

  Timer {
    interval: root.locationRefreshMinutes * 60 * 1000
    running: root.preferencesReady && root.networkReady && root.automaticLocation
    repeat: true
    triggeredOnStart: true
    onTriggered: root.resolveLocation(false)
  }

  Timer {
    id: retryTimer
    interval: 2500
    onTriggered: root.refresh(true)
  }

  Timer {
    id: geocodeDebounce
    interval: 300
    onTriggered: root.requestGeocode()
  }

  Process {
    id: weatherProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        try {
          var response = JSON.parse(raw || "{}")
          if (response.error) {
            root.errorMessage = String(response.error)
            root.scheduleRetry()
            return
          }
        } catch (e) {
          root.errorMessage = "Kunne ikke lese værdata"
          root.scheduleRetry()
          return
        }

        var parsed = Model.parseBundle(raw)
        if (!parsed) {
          root.errorMessage = "Ugyldig svar fra MET Norway"
          root.scheduleRetry()
          return
        }
        root.report = parsed
        root.loading = false
        root.errorMessage = parsed.stale ? "Viser sist kjente værdata" : ""
        if (parsed.stale) root.scheduleRetry()
        else root.retries = 0
      }
    }
  }

  Process {
    id: locationProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var resolved = Model.parseResolvedLocation(text)
        if (resolved.latitude === null || resolved.longitude === null) {
          root.dynamicLocationError = resolved.error || "Kunne ikke lese automatisk posisjon"
          if (!root.hasCoordinates) root.errorMessage = root.dynamicLocationError
          return
        }

        root.dynamicLocationState = resolved
        root.dynamicLocationError = ""
        if (root.automaticLocation) root.errorMessage = ""
      }
    }
  }

  Process {
    id: geocodeProc
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.editingLocation && root.geocodeActiveQuery === locationField.text.trim())
        root.settingsError = "Kunne ikke søke etter sted"
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root.editingLocation || root.automaticLocation || root.geocodeActiveQuery !== locationField.text.trim()) return
        try {
          var response = JSON.parse(text)
          if (response.error) throw new Error("Geocoder rejected query")
        } catch (error) {
          root.settingsError = "Kunne ikke søke etter sted"
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
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.savingLocation = false
        root.settingsError = "Kunne ikke lagre stedet"
        return
      }
      root.savingLocation = false
      localLocationFile.reload()
      root.clearSearch()
      locationField.text = ""
    }
  }

  FileView {
    path: localPathFromUrl(Qt.resolvedUrl("manifest.json"))
    onLoaded: {
      try { root.widgetId = String(JSON.parse(text()).id || "") }
      catch (error) { root.settingsError = "Kunne ikke lese innstillingene" }
    }
    onLoadFailed: root.settingsError = "Kunne ikke lese innstillingene"
  }

  Process {
    id: preferencesSaveProc
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.settingsError = "Kunne ikke lagre innstillingene"
        return
      }
      if (root.automaticLocation) root.clearSearch()
    }
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function edit(): void { root.openFromHotkey(); root.startEditingLocation() }
    function refresh(): void { root.refresh(true) }
  }

  component Label: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.space(13)
  }

  WeatherPopup {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    padding: 0
    borderSpec: Border.flat(root.outlineColor, 1)
    contentWidth: panel.fittedContentWidth(Style.space(600))
    contentHeight: panel.fittedContentHeight(weatherColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingLocation
      onReturnRequested: root.startEditingLocation()
      Keys.onEscapePressed: root.editingLocation ? root.cancelEditingLocation() : root.close()
      Keys.onTabPressed: function(event) {
        if (root.editingLocation && keyCatcher.activeFocus) automaticLocationToggle.forceActiveFocus()
        else event.accepted = false
      }
      onMoveRequested: function(dx, dy) {
        if (dx !== 0 && root.forecastDays.length > 0)
          root.selectedDayIndex = Math.max(0, Math.min(root.forecastDays.length - 1, root.selectedDayIndex + dx))
      }
      onCloseRequested: root.editingLocation ? root.cancelEditingLocation() : root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: weatherScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: weatherColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: weatherColumn
          width: parent.width

          Item {
            id: weatherHero
            width: parent.width
            height: Style.space(200)
            // Keep the theme background available before weather data or shader readiness.
            Canvas {
              id: headerBackground
              anchors.fill: parent
              onWidthChanged: requestPaint()
              onHeightChanged: requestPaint()
              onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                var radius = Style.space(13)
                ctx.beginPath()
                ctx.moveTo(radius, 0); ctx.lineTo(width - radius, 0)
                ctx.quadraticCurveTo(width, 0, width, radius)
                ctx.lineTo(width, height); ctx.lineTo(0, height); ctx.lineTo(0, radius)
                ctx.quadraticCurveTo(0, 0, radius, 0); ctx.closePath(); ctx.clip()
                var gradient = ctx.createLinearGradient(0, 0, width * 0.5, height)
                gradient.addColorStop(0, Qt.tint(Color.popups.background, Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.08)))
                gradient.addColorStop(1, Color.popups.background)
                ctx.fillStyle = gradient; ctx.fillRect(0, 0, width, height)
                var glow = ctx.createRadialGradient(width * 0.9, 0, 0, width * 0.9, 0, width * 0.85)
                glow.addColorStop(0, Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.17))
                glow.addColorStop(1, "transparent")
                ctx.fillStyle = glow; ctx.fillRect(0, 0, width, height)
              }
              Connections { target: Color; function onAccentChanged() { headerBackground.requestPaint() } function onShellValuesChanged() { headerBackground.requestPaint() } function onBackgroundChanged() { headerBackground.requestPaint() } }
            }

            WeatherBackground {
              anchors.fill: parent
              current: root.current
              now: root.now
              location: root.configuredLocationState
              visible: root.preferences.animations
              active: root.preferences.animations && root.opened && weatherHero.y + weatherHero.height > weatherScroll.contentY
              surfaceColor: Color.popups.background
              lightTheme: root.lightTheme
              cornerRadius: Style.space(13)
            }

            Column {
              anchors.centerIn: parent
              width: parent.width - Style.space(40)
              spacing: Style.space(8)
              // Shade the text and icons instead of hiding the sky behind them.
              layer.enabled: true
              layer.effect: MultiEffect {
                shadowEnabled: true
                shadowColor: Color.popups.background
                shadowOpacity: 0.9
                shadowBlur: 0.25
                blurMax: 8
                shadowHorizontalOffset: 0
                shadowVerticalOffset: 1
              }
              Label {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.configuredLocation || root.tr("Velg sted")
                width: Math.min(implicitWidth, weatherHero.width - Style.space(120))
                height: Style.space(28)
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
                font.pixelSize: Style.space(14)
              }
              Row {
                anchors.horizontalCenter: parent.horizontalCenter
                height: Style.space(68)
                spacing: Style.space(4)
                Label { text: root.currentTemperature.replace("°", ""); font.pixelSize: Style.space(60); height: parent.height; verticalAlignment: Text.AlignVCenter }
                Label { text: root.current ? (root.units === "imperial" ? "°F" : "°C") : ""; font.pixelSize: Style.space(19); topPadding: Style.space(6) }
              }
              Column {
                width: parent.width
                spacing: Style.space(4)
                Row {
                  anchors.horizontalCenter: parent.horizontalCenter
                  spacing: Style.space(5)
                  WeatherConditionIcon {
                    width: Style.space(28); height: width
                    symbol: root.current ? root.current.symbol : "cloudy"
                    lightTheme: root.lightTheme
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Label {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.currentDescription
                    font.pixelSize: Style.space(18)
                    width: Math.min(implicitWidth, weatherHero.width - Style.space(80))
                    elide: Text.ElideRight
                  }
                }
                Label {
                  width: parent.width; horizontalAlignment: Text.AlignHCenter
                  visible: root.forecastDays.length > 0
                  text: root.forecastDays.length ? root.tr("Høy ") + root.temperature(root.forecastDays[0].high) + root.tr(" · Lav ") + root.temperature(root.forecastDays[0].low) : ""
                  color: root.secondaryForeground; font.pixelSize: Style.space(12)
                }
                Label {
                  width: parent.width; horizontalAlignment: Text.AlignHCenter
                  visible: !root.current
                  text: root.loading ? root.tr("Henter værdata…") : root.tr("Venter på værdata")
                  color: root.secondaryForeground; font.pixelSize: Style.space(12)
                }
              }
            }
            WeatherAction {
              visible: !root.editingLocation
              anchors.top: parent.top
              anchors.right: parent.right
              anchors.topMargin: Style.space(13)
              anchors.rightMargin: Style.space(16)
              implicitWidth: Style.space(32)
              implicitHeight: Style.space(32)
              radius: Style.space(7)
              iconSize: Style.space(16)
              iconName: "settings"
              tooltipText: root.tr("Innstillinger")
              foreground: root.secondaryForeground
              keyTarget: keyCatcher
              enabled: !root.savingLocation
              onClicked: root.editingLocation ? root.cancelEditingLocation() : root.startEditingLocation()
            }
          }

          Item {
            width: parent.width
            height: body.implicitHeight + Style.space(28)
            Column {
              id: body
              x: Style.space(20); y: Style.space(16)
              width: parent.width - Style.space(40)
              spacing: 0

          Column {
            visible: root.editingLocation
            width: parent.width
            spacing: Style.space(12)

            Row {
              width: parent.width
              spacing: Style.space(10)
              WeatherAction {
                id: settingsBack
                iconName: "arrow-left"
                tooltipText: root.tr("Tilbake")
                foreground: root.secondaryForeground
                onClicked: root.cancelEditingLocation()
              }
              Label {
                text: root.tr("Innstillinger")
                color: root.secondaryForeground
                anchors.verticalCenter: parent.verticalCenter
              }
            }
            Toggle {
              fontFamily: root.fontFamily
              titleSize: Style.space(13)
              implicitHeight: Style.space(36)
              borderSpec: activeFocus ? Border.flat(Color.accent, 1) : Border.none()
              color: "transparent"
              id: automaticLocationToggle
              width: parent.width
              label: root.tr("Bruk posisjonsdata")
              property bool showHint: false
              onHovered: function(hovered) { showHint = hovered }
              PanelToolTip {
                visible: automaticLocationToggle.showHint || automaticLocationToggle.activeFocus
                text: root.tr("Automatisk via GeoClue. Posisjonen brukes av MET Norway og OpenStreetMap.")
                fontFamily: root.fontFamily
              }
              checked: root.automaticLocation
              enabled: !preferencesSaveProc.running && !root.savingLocation
              onClicked: root.savePreference("automaticLocation", !root.automaticLocation)
            }
            Label {
              visible: root.automaticLocation && (locationProc.running || root.dynamicLocationError !== "")
              width: parent.width
              wrapMode: Text.WordWrap
              text: locationProc.running ? root.tr("Finner posisjon…") : root.tr(root.dynamicLocationError)
              color: root.secondaryForeground
              font.pixelSize: Style.space(12)
            }
            Column {
              visible: !root.automaticLocation
              width: parent.width
              spacing: Style.spacing.labelGap
              Label {
                text: root.tr("Posisjon")
                color: Qt.darker(Color.popups.text, 1.4)
                font.pixelSize: Style.font.caption
                font.bold: true
              }
              TextField {
                id: locationField
                width: parent.width
                enabled: !root.savingLocation
                Accessible.name: root.tr("Posisjon")
                placeholderText: root.tr("Søk etter sted")
                foreground: root.foreground
                font.family: root.fontFamily
                onTextEdited: {
                  root.clearSearch()
                  root.settingsError = ""
                  if (text.trim().length >= 2) geocodeDebounce.restart()
                }

                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Escape) {
                    root.cancelEditingLocation()
                    event.accepted = true
                  } else if (event.key === Qt.Key_Down) {
                    if (root.suggestionIndex < root.locationSuggestions.length - 1) root.suggestionIndex++
                    event.accepted = true
                  } else if (event.key === Qt.Key_Up) {
                    if (root.suggestionIndex > 0) root.suggestionIndex--
                    event.accepted = true
                  } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.commitLocation()
                    event.accepted = true
                  }
                }
              }
            }

            Repeater {
              model: root.locationSuggestions

              Rectangle {
                required property var modelData
                required property int index
                width: parent.width
                height: suggestionText.implicitHeight + Style.space(12)
                radius: Style.cornerRadius
                color: index === root.suggestionIndex
                  ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"

                Text {
                  textFormat: Text.PlainText
                  id: suggestionText
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.name + (modelData.description ? "  ·  " + modelData.description : "")
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  width: parent.width - Style.space(24)
                  wrapMode: Text.WordWrap
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onPositionChanged: root.suggestionIndex = index
                  onClicked: root.pickSuggestion(modelData)
                }
              }
            }
            Label {
              visible: !root.automaticLocation && (geocodeProc.running || root.searchCompleted && !root.locationSuggestions.length)
              text: geocodeProc.running ? root.tr("Søker…") : root.tr("Ingen treff")
              color: root.secondaryForeground
            }
            Label {
              visible: root.settingsError !== ""
              width: parent.width
              wrapMode: Text.WordWrap
              text: root.tr(root.settingsError)
              color: root.urgent
            }
            Grid {
              id: preferenceGrid
              width: parent.width
              columns: width < Style.space(420) ? 1 : 2
              spacing: Style.space(12)
              Dropdown {
                id: languageDropdown
                fontFamily: root.fontFamily
                width: (preferenceGrid.width - preferenceGrid.spacing * (preferenceGrid.columns - 1)) / preferenceGrid.columns
                label: root.tr("Språk")
                value: root.preferences.languageMode
                options: [
                  { value: "system", label: root.tr("Standard (systemspråk)") },
                  { value: "nb", label: "Norsk bokmål" },
                  { value: "en", label: "English" }
                ]
                enabled: !preferencesSaveProc.running
                onChanged: function(value) { root.savePreference("language", value) }
              }
              Dropdown {
                id: unitsDropdown
                fontFamily: root.fontFamily
                width: (preferenceGrid.width - preferenceGrid.spacing * (preferenceGrid.columns - 1)) / preferenceGrid.columns
                label: root.tr("Enheter")
                value: root.units
                options: [{ value: "metric", label: root.tr("Metrisk (°C, km/t, mm)") }, { value: "imperial", label: root.tr("Imperial (°F, mph, in)") }]
                enabled: !preferencesSaveProc.running
                onChanged: function(value) { root.savePreference("units", value) }
              }
            }
            Toggle {
              id: animationToggle
              fontFamily: root.fontFamily
              titleSize: Style.space(13)
              implicitHeight: Style.space(36)
              borderSpec: activeFocus ? Border.flat(Color.accent, 1) : Border.none()
              color: "transparent"
              width: parent.width
              label: root.tr("Animert bakgrunn")
              checked: root.preferences.animations
              enabled: !preferencesSaveProc.running
              onClicked: root.savePreference("animations", !root.preferences.animations)
            }
          }

          Rectangle {
            visible: !root.editingLocation && root.errorMessage !== ""
            width: parent.width
            height: errorRow.implicitHeight + Style.space(14)
            radius: Style.cornerRadius
            color: Style.hoverFillFor(root.foreground, root.report && root.report.stale ? Color.accent : root.urgent)

            Row {
              id: errorRow
              anchors.left: parent.left
              anchors.leftMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: root.report && root.report.stale ? "󰋚" : "󰅚"
                color: root.report && root.report.stale ? Color.accent : root.urgent
                font.family: root.iconFontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                textFormat: Text.PlainText
                text: root.tr(root.errorMessage)
                width: Math.max(0, body.width - Style.space(50))
                wrapMode: Text.WordWrap
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }



              Column {
                id: forecastContent
                width: parent.width
                visible: !root.editingLocation
              Item { width: 1; height: Style.space(18); visible: root.errorMessage !== "" }

              Grid {
                id: metricGrid
                visible: !!root.current
                width: parent.width
                columns: width < Style.space(380) ? 2 : 4
                rowSpacing: Style.space(15)
                Repeater {
                  model: [
                    { label: root.tr("Vind"), icon: "wind", value: root.current ? root.windSpeed(root.current.windSpeed) : "—", detail: root.current ? root.windLabel(root.current.windDirection) : "" },
                    { label: root.tr("Fuktighet"), icon: "droplets", value: root.current && root.current.humidity !== null ? root.current.humidity + " %" : "—", detail: root.tr("Relativ") },
                    { label: root.tr("Neste time"), icon: "cloud-rain", value: root.current ? root.precipitation(root.current.precipitation) : "—", detail: root.tr("Nedbør") },
                    { label: root.tr("UV-indeks"), icon: "sun", value: root.current ? Model.uvIndex(root.current.uvIndex) : "—", detail: root.uvLabel }
                  ]
                  Item {
                    required property var modelData
                    required property int index
                    width: metricGrid.width / metricGrid.columns
                    height: Style.space(64)
                    Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: root.outlineColor; visible: index % metricGrid.columns < metricGrid.columns - 1 }
                    Column {
                      width: parent.width
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(6)
                      Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: Style.space(5)
                        WeatherIcon { anchors.verticalCenter: parent.verticalCenter; width: Style.space(14); height: width; name: modelData.icon; color: root.secondaryForeground }
                        Label { anchors.verticalCenter: parent.verticalCenter; text: modelData.label; color: root.secondaryForeground; font.pixelSize: Style.space(11); font.letterSpacing: 0.6 }
                      }
                      Label { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.value; font.pixelSize: Style.space(19) }
                      Label { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.detail; color: root.secondaryForeground; font.pixelSize: Style.space(11) }
                    }
                  }
                }
              }

              Item { width: 1; height: Style.space(16); visible: root.forecastDays.length > 0 }
              Label { text: root.tr("Tre dagers varsel"); visible: root.forecastDays.length > 0 }
              Item { width: 1; height: Style.space(11); visible: root.forecastDays.length > 0 }
              Grid {
                id: forecastGrid
                visible: root.forecastDays.length > 0
                width: parent.width
                columns: width < Style.space(420) ? 1 : Math.max(1, root.forecastDays.length)
                spacing: Style.space(10)
                Repeater {
                  model: root.forecastDays
                  Rectangle {
                    id: dayCard
                    required property var modelData
                    required property int index
                    width: (forecastGrid.width - forecastGrid.spacing * (forecastGrid.columns - 1)) / forecastGrid.columns
                    height: Style.space(100)
                    radius: Style.space(8)
                    color: index === root.selectedDayIndex ? root.selectedCardColor : root.cardColor
                    clip: true
                    Item {
                      anchors.bottom: parent.bottom
                      width: parent.width
                      height: dayCard.radius
                      visible: dayCard.index === root.selectedDayIndex
                      clip: true
                      // Two offset rounded fills reproduce an inset bottom shadow,
                      // tapering to nothing at the sides instead of curling upward.
                      Rectangle {
                        anchors.bottom: parent.bottom
                        width: dayCard.width
                        height: dayCard.height
                        radius: dayCard.radius
                        color: Color.accent
                        antialiasing: true
                        Rectangle {
                          anchors.fill: parent
                          anchors.bottomMargin: Style.space(2)
                          radius: dayCard.radius
                          color: dayCard.color
                          antialiasing: true
                        }
                      }
                    }
                    Column {
                      anchors.fill: parent; anchors.margins: Style.space(10)
                      spacing: Style.space(5)
                      Row {
                        width: parent.width
                        Label { text: root.dayLabel(modelData, index) }
                        Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth); height: 1 }
                        Label { text: root.shortDate(modelData); color: root.secondaryForeground; font.pixelSize: Style.space(11) }
                      }
                      Row {
                        spacing: Style.space(9)
                        WeatherConditionIcon { width: Style.space(36); height: width; symbol: modelData.symbol; lightTheme: root.lightTheme; anchors.verticalCenter: parent.verticalCenter }
                        Label { text: root.temperature(modelData.high); font.pixelSize: Style.space(21); anchors.verticalCenter: parent.verticalCenter }
                        Label { text: root.temperature(modelData.low); color: root.secondaryForeground; anchors.verticalCenter: parent.verticalCenter }
                      }
                      Row {
                        spacing: Style.space(6)
                        WeatherIcon { width: Style.space(13); height: width; name: "droplet"; color: root.secondaryForeground; anchors.verticalCenter: parent.verticalCenter }
                        Label { text: root.precipitation(modelData.precipitation) + " · " + root.timeLabel(modelData.sunset); color: root.secondaryForeground; font.pixelSize: Style.space(11) }
                      }
                    }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.selectedDayIndex = index }
                  }
                }
              }

              Item { width: 1; height: Style.space(16); visible: root.displayHours.length > 0 }
              Row {
                width: parent.width
                visible: root.displayHours.length > 0
                Label { text: root.tr("Time for time") }
                Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth); height: 1 }
                Label { text: root.selectedDay ? root.dayLabel(root.selectedDay, root.selectedDayIndex) + " · " + root.hourSummary : ""; color: root.secondaryForeground; font.pixelSize: Style.space(11) }
              }
              Item { width: 1; height: Style.space(11); visible: root.displayHours.length > 0 }
              Grid {
                id: hourlyGrid
                width: parent.width
                visible: root.displayHours.length > 0
                columns: width < Style.space(480) ? 4 : 8
                Repeater {
                  model: root.displayHours
                  Item {
                    required property var modelData
                    width: hourlyGrid.width / hourlyGrid.columns
                    height: Style.space(110)
                    Column {
                      anchors.verticalCenter: parent.verticalCenter; width: parent.width
                      spacing: Style.space(5)
                      Label { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: modelData.time; color: root.secondaryForeground; font.pixelSize: Style.space(11) }
                      WeatherConditionIcon { anchors.horizontalCenter: parent.horizontalCenter; width: Style.space(34); height: width; symbol: modelData.symbol; lightTheme: root.lightTheme }
                      Label { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: root.temperature(modelData.temperature) }
                      Label { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: root.precipitation(modelData.precipitation); color: root.rainColor; font.pixelSize: Style.space(11) }
                    }
                  }
                }
              }

              Item { width: 1; height: Style.space(12) }
              Rectangle { width: parent.width; height: 1; color: root.outlineColor }
              Item { width: 1; height: Style.space(10) }
              Row {
                id: footer
                width: parent.width
                Label { id: providerLabel; anchors.verticalCenter: parent.verticalCenter; text: "MET Norway"; color: root.secondaryForeground; font.pixelSize: Style.space(11) }
                Item { width: Math.max(0, footer.width - providerLabel.width - footerActions.implicitWidth); height: 1 }
                Row {
                  id: footerActions
                  spacing: Style.space(12)
                  Label {
                    visible: root.updatedText !== ""
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, Math.max(0, footer.width - providerLabel.width - refreshButton.width - Style.space(24)))
                    text: root.tr("Oppdatert ") + root.updatedText
                    elide: Text.ElideRight
                    color: root.secondaryForeground
                    opacity: 0.8
                    font.pixelSize: Style.space(11)
                  }
                  WeatherAction {
                    id: refreshButton
                    iconName: "refresh-cw"
                    label: root.loading ? root.tr("Oppdaterer…") : (!root.networkReady ? root.tr("Venter på nettverk…") : root.tr("Oppdater"))
                    foreground: root.secondaryForeground
                    enabled: !root.loading && root.networkReady
                    onClicked: root.refresh(true)
                  }
                }
              }
              }
            }
          }
        }
      }
    }
  }
}

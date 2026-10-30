pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "kit"
import "Model.js" as Model
import "Preferences.js" as Preferences

// The weather popup body: sky hero with the header, readings, three-day and
// hourly forecasts, attribution, and the settings page. Built on first open
// (FoamyPopup body). `controller` is the Panel, or the preview's mock with
// the same properties and functions.
//
// Keyboard (one cursor): arrows/hjkl walk the day cards, refresh and
// settings; moving onto a day selects it. Enter activates (with nothing
// under the cursor it opens Settings, as before), `s` Settings, `r` refresh,
// Esc closes or leaves Settings, Tab/Shift-Tab switch bar panels.
PanelKeyCatcher {
  id: view

  required property QtObject controller
  readonly property QtObject c: controller

  readonly property var forecastDays: c.contentActive && !c.editingLocation ? Model.forecastDays(c.report, c.now) : []
  readonly property var selectedDay: forecastDays.length
    ? forecastDays[Math.max(0, Math.min(c.selectedDayIndex, forecastDays.length - 1))] : null
  readonly property var displayHours: selectedDay ? selectedDay.hours : []
  readonly property var current: c.current
  readonly property bool lightTheme: FoamyPalette.lightTheme
  // Opaque tints: the selected card's inset accent edge is drawn under them.
  readonly property color cardColor: Qt.tint(FoamyPalette.background, FoamyPalette.fieldFill)
  readonly property color cursorCardColor: Qt.tint(cardColor, FoamyPalette.hoverFill)
  readonly property color selectedCardColor: Qt.tint(FoamyPalette.background, Qt.alpha(Commons.Color.accent, 0.20))
  readonly property color rainColor: FoamyPalette.onSurface(FoamyPalette.info)
  readonly property string hourSummary: {
    for (var i = 0; i < displayHours.length; i++) {
      if (displayHours[i].precipitation > 0) return FoamyI18n.t("Precipitation from %1", [displayHours[i].time.slice(0, 2)])
    }
    return FoamyI18n.t("No precipitation expected")
  }
  readonly property string uvLabel: !current || current.uvIndex === null ? "—"
    : current.uvIndex < 3 ? FoamyI18n.t("Low") : current.uvIndex < 6 ? FoamyI18n.t("Moderate")
    : current.uvIndex < 8 ? FoamyI18n.t("High") : FoamyI18n.t("Very high")
  readonly property string updatedText: c.report && c.report.fetchedAt
    ? Preferences.age(c.report.fetchedAt, c.now, FoamyI18n.t, FoamyI18n.tn) : ""
  readonly property string headerMeta: c.loading ? FoamyI18n.t("Refreshing…")
    : !c.networkReady ? FoamyI18n.t("Waiting for network…")
    : updatedText ? FoamyI18n.t("Updated %1", [updatedText]) : ""

  // The hero's own type sizes: the reading is the panel's focal point, well
  // above the shared scale (4.5's weather panel does the same).
  readonly property int heroTemperatureSize: Style.space(60)
  readonly property real innerRadius: FoamyStyle.innerRadius(FoamyStyle.radius, FoamyStyle.borderWidth)

  function temperature(value) { return Preferences.temperature(value, c.units, FoamyI18n.number) }
  function precipitation(value) { return Preferences.precipitation(value, c.units, FoamyI18n.number) }
  function windSpeed(value) { return Preferences.wind(value, c.units, FoamyI18n.t, FoamyI18n.number) }

  function dayLabel(day, index) {
    if (!day) return ""
    if (index === 0) return FoamyI18n.t("Today")
    if (index === 1) return FoamyI18n.t("Tomorrow")
    var locale = Qt.locale(FoamyI18n.formatLocale)
    var label = typeof locale.standaloneDayName === "function"
      ? locale.standaloneDayName(day.dateObject.getDay(), Locale.LongFormat)
      : locale.toString(day.dateObject, "dddd")
    return label.charAt(0).toUpperCase() + label.slice(1)
  }

  function shortDate(day) {
    return day ? Qt.locale(FoamyI18n.formatLocale).toString(day.dateObject, "d MMM") : ""
  }

  // --- cursor ------------------------------------------------------------------------
  readonly property int refreshStop: forecastDays.length
  readonly property int settingsStop: forecastDays.length + 1
  FoamyCursor { id: cursor; count: view.forecastDays.length + 2 }

  function activate(index) {
    if (index >= 0 && index < forecastDays.length) c.selectedDayIndex = index
    else if (index === refreshStop) { if (!c.loading && c.networkReady) c.refresh(true) }
    else c.startEditingLocation()
  }

  implicitWidth: FoamyStyle.popupWidthWide
  implicitHeight: c.editingLocation ? settingsLoader.implicitHeight : weatherColumn.implicitHeight
  blocked: c.editingLocation

  onMoveRequested: function(dx, dy) {
    cursor.move(dx !== 0 ? dx : dy)
    if (cursor.index >= 0 && cursor.index < forecastDays.length) c.selectedDayIndex = cursor.index
  }
  onActivateRequested: activate(cursor.index)
  onCloseRequested: c.close()
  onTabRequested: function(direction) { c.switchPanel(direction) }
  onTextKey: function(text) {
    if (text === "s") c.startEditingLocation()
    else if (text === "r") activate(refreshStop)
  }

  onForecastDaysChanged: {
    if (!c.editingLocation && c.selectedDayIndex >= forecastDays.length) c.selectedDayIndex = Math.max(0, forecastDays.length - 1)
  }

  Connections {
    target: view.c
    function onOpenedChanged() {
      if (!view.c.opened) cursor.reset()
    }
    function onEditingLocationChanged() {
      cursor.reset()
      weatherScroll.contentY = 0
      if (view.c.editingLocation) Qt.callLater(function() { if (settingsLoader.item) settingsLoader.item.focusBack() })
      else Qt.callLater(function() { view.forceActiveFocus() })
    }
  }

  component Label: Text {
    textFormat: Text.PlainText
    color: FoamyPalette.text
    font.family: FoamyStyle.fontFamily
    font.pixelSize: FoamyStyle.font.subtitle
  }

  Flickable {
    id: weatherScroll
    visible: !view.c.editingLocation
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
        height: heroHeader.implicitHeight + heroReading.implicitHeight + FoamyStyle.padding

        // Keep the theme background available before weather data or shader readiness.
        Canvas {
          id: headerBackground
          readonly property real cornerRadius: Math.max(0, Math.min(width / 2, height, view.innerRadius))
          readonly property color accent: Commons.Color.accent
          readonly property color surface: Commons.Color.popups.background
          anchors.fill: parent
          onCornerRadiusChanged: requestPaint()
          onAccentChanged: requestPaint()
          onSurfaceChanged: requestPaint()
          onWidthChanged: requestPaint()
          onHeightChanged: requestPaint()
          onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var radius = cornerRadius
            ctx.beginPath()
            ctx.moveTo(radius, 0); ctx.lineTo(width - radius, 0)
            ctx.arcTo(width, 0, width, radius, radius)
            ctx.lineTo(width, height); ctx.lineTo(0, height); ctx.lineTo(0, radius)
            ctx.arcTo(0, 0, radius, 0, radius); ctx.closePath(); ctx.clip()
            var gradient = ctx.createLinearGradient(0, 0, width * 0.5, height)
            gradient.addColorStop(0, Qt.tint(surface, Qt.alpha(accent, 0.08)))
            gradient.addColorStop(1, surface)
            ctx.fillStyle = gradient; ctx.fillRect(0, 0, width, height)
            var glow = ctx.createRadialGradient(width * 0.9, 0, 0, width * 0.9, 0, width * 0.85)
            glow.addColorStop(0, Qt.alpha(accent, 0.17))
            glow.addColorStop(1, "transparent")
            ctx.fillStyle = glow; ctx.fillRect(0, 0, width, height)
          }
        }

        WeatherBackground {
          id: sky
          anchors.fill: parent
          current: view.current
          now: view.c.now
          location: view.c.configuredLocationState
          visible: view.c.animations
          // Drawn only while the popup shows it; a still frame under reduced motion.
          shown: view.c.animations && view.c.opened && !view.c.editingLocation
            && weatherHero.y + weatherHero.height > weatherScroll.contentY
          animate: !FoamyMotion.reduceMotion
          surfaceColor: Commons.Color.popups.background
          lightTheme: view.lightTheme
          cornerRadius: view.innerRadius
        }

        FoamyHeader {
          id: heroHeader
          width: parent.width
          iconName: "map-pin"
          title: view.c.reportLocation || FoamyI18n.t("Choose location")
          meta: view.headerMeta
          settingsHasCursor: cursor.at(view.settingsStop)
          onSettingsClicked: view.c.startEditingLocation()
          onSettingsHovered: function(hovered) { if (hovered) cursor.hover(view.settingsStop) }
          // Shade text and icons instead of hiding the sky behind them.
          layer.enabled: sky.drawable
          layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: Commons.Color.popups.background
            shadowOpacity: 0.9
            shadowBlur: 0.25
            blurMax: 8
            shadowVerticalOffset: 1
          }

          FoamyAction {
            iconName: "refresh-cw"
            foreground: FoamyPalette.secondaryText
            tooltipText: view.c.loading ? FoamyI18n.t("Refreshing…") : (!view.c.networkReady ? FoamyI18n.t("Waiting for network…") : FoamyI18n.t("Refresh"))
            spinning: view.c.opened && view.c.loading
            actionEnabled: !view.c.loading && view.c.networkReady
            hasCursor: cursor.at(view.refreshStop)
            onHoveredChanged: if (hovered) cursor.hover(view.refreshStop)
            onClicked: view.activate(view.refreshStop)
          }
        }

        Column {
          id: heroReading
          anchors.top: heroHeader.bottom
          anchors.topMargin: -FoamyStyle.gap
          anchors.horizontalCenter: parent.horizontalCenter
          width: parent.width - FoamyStyle.padding * 2
          spacing: FoamyStyle.gapSmall
          layer.enabled: sky.drawable
          layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: Commons.Color.popups.background
            shadowOpacity: 0.9
            shadowBlur: 0.25
            blurMax: 8
            shadowVerticalOffset: 1
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            height: Style.space(68)
            spacing: FoamyStyle.gapSmall
            // A reading and its unit ("13 °C") stay in that order in a
            // right-to-left layout too, the way bidi text keeps them.
            LayoutMirroring.enabled: false
            Label {
              text: view.current ? Preferences.temperatureValue(view.current.temperature, view.c.units, FoamyI18n.number) : "--"
              font.pixelSize: view.heroTemperatureSize
              height: parent.height
              verticalAlignment: Text.AlignVCenter
            }
            Label {
              text: view.current ? (view.c.units === "imperial" ? "°F" : "°C") : ""
              font.pixelSize: FoamyStyle.font.iconLarge
              topPadding: Style.space(6)
            }
          }
          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: FoamyStyle.gapSmall
            WeatherConditionIcon {
              width: Style.space(28); height: width
              symbol: view.current ? view.current.symbol : "cloudy"
              lightTheme: view.lightTheme
              anchors.verticalCenter: parent.verticalCenter
            }
            Label {
              anchors.verticalCenter: parent.verticalCenter
              text: view.c.currentDescription
              font.pixelSize: FoamyStyle.font.iconLarge
              width: Math.min(implicitWidth, weatherHero.width - Style.space(80))
              elide: Text.ElideRight
            }
          }
          Label {
            width: parent.width; horizontalAlignment: Text.AlignHCenter
            visible: view.forecastDays.length > 0
            text: view.forecastDays.length
              ? FoamyI18n.t("High %1 · Low %2", [view.temperature(view.forecastDays[0].high), view.temperature(view.forecastDays[0].low)]) : ""
            color: FoamyPalette.secondaryText; font.pixelSize: FoamyStyle.font.body
          }
          Label {
            width: parent.width; horizontalAlignment: Text.AlignHCenter
            visible: !view.current
            text: view.c.loading ? FoamyI18n.t("Loading weather…") : FoamyI18n.t("Waiting for weather")
            color: FoamyPalette.secondaryText; font.pixelSize: FoamyStyle.font.body
          }
        }
      }

      Column {
        id: body
        x: FoamyStyle.padding
        width: parent.width - FoamyStyle.padding * 2
        topPadding: FoamyStyle.gap
        bottomPadding: FoamyStyle.gapLarge

        // A note about what is shown: loading a new place, stale data, or an error.
        Rectangle {
          id: note
          readonly property bool info: view.c.statusText !== "" || view.c.errorIsStale
          readonly property string message: view.c.statusText || view.c.errorText
          visible: message !== ""
          width: parent.width
          height: visible ? noteRow.implicitHeight + Style.space(14) : 0
          radius: FoamyStyle.radius
          color: Qt.alpha(info ? Commons.Color.accent : Commons.Color.urgent, 0.12)

          Row {
            id: noteRow
            anchors.left: parent.left
            anchors.leftMargin: FoamyStyle.gapLarge
            anchors.verticalCenter: parent.verticalCenter
            spacing: FoamyStyle.gap
            FoamyIcon {
              anchors.verticalCenter: parent.verticalCenter
              width: FoamyStyle.iconSize; height: width
              // kit "info" draws a megaphone (kit issue filed); pick explicit glyphs.
              name: view.c.statusText !== "" ? "map-pin" : note.info ? "cloud" : "triangle-alert"
              color: note.info ? Commons.Color.accent : Commons.Color.urgent
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: note.message
              width: Math.max(0, body.width - Style.space(50))
              wrapMode: Text.WordWrap
              horizontalAlignment: Text.AlignLeft
              color: FoamyPalette.text
              font.family: FoamyStyle.fontFamily
              font.pixelSize: FoamyStyle.font.bodySmall
              Accessible.role: note.info ? Accessible.StaticText : Accessible.AlertMessage
              Accessible.name: text
            }
          }
        }
        Item { width: 1; height: FoamyStyle.padding; visible: view.c.statusText !== "" || view.c.errorText !== "" }

        Grid {
          id: metricGrid
          visible: !!view.current
          width: parent.width
          columns: width < Style.space(380) ? 2 : 4
          rowSpacing: Style.space(15)
          Repeater {
            model: [
              { label: FoamyI18n.t("Wind"), icon: "wind", value: view.current ? view.windSpeed(view.current.windSpeed) : "—", detail: view.current ? view.c.windLabel(view.current.windDirection) : "" },
              { label: FoamyI18n.t("Humidity"), icon: "droplets", value: view.current && view.current.humidity !== null ? FoamyI18n.number(view.current.humidity) + " %" : "—", detail: FoamyI18n.t("Relative") },
              { label: FoamyI18n.t("Next hour"), icon: "cloud-rain", value: view.current ? view.precipitation(view.current.precipitation) : "—", detail: FoamyI18n.t("Precipitation") },
              { label: FoamyI18n.t("UV index"), icon: "sun", value: view.current ? Model.uvIndex(view.current.uvIndex, FoamyI18n.number) : "—", detail: view.uvLabel }
            ]
            Item {
              required property var modelData
              required property int index
              width: metricGrid.width / metricGrid.columns
              height: Style.space(64)
              Rectangle {
                anchors.right: parent.right; width: 1; height: parent.height; color: FoamyPalette.divider
                visible: parent.index % metricGrid.columns < metricGrid.columns - 1
              }
              Column {
                width: parent.width
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)
                Row {
                  anchors.horizontalCenter: parent.horizontalCenter
                  spacing: Style.space(5)
                  FoamyIcon { anchors.verticalCenter: parent.verticalCenter; width: Style.space(14); height: width; name: modelData.icon; color: FoamyPalette.secondaryText }
                  Label { anchors.verticalCenter: parent.verticalCenter; text: modelData.label; color: FoamyPalette.secondaryText; font.pixelSize: FoamyStyle.font.bodySmall; font.letterSpacing: 0.6 }
                }
                Label { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.value; font.pixelSize: FoamyStyle.font.iconLarge }
                Label { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.detail; color: FoamyPalette.secondaryText; font.pixelSize: FoamyStyle.font.bodySmall }
              }
            }
          }
        }

        Item { width: 1; height: Style.space(16); visible: view.forecastDays.length > 0 }
        Label { text: FoamyI18n.t("Three-day forecast"); visible: view.forecastDays.length > 0 }
        Item { width: 1; height: Style.space(11); visible: view.forecastDays.length > 0 }
        Grid {
          id: forecastGrid
          visible: view.forecastDays.length > 0
          width: parent.width
          columns: width < Style.space(420) ? 1 : Math.max(1, view.forecastDays.length)
          spacing: Style.space(10)
          Repeater {
            model: view.forecastDays
            Rectangle {
              id: dayCard
              required property var modelData
              required property int index
              readonly property bool selected: index === view.c.selectedDayIndex
              readonly property bool hasCursor: cursor.at(index)
              width: (forecastGrid.width - forecastGrid.spacing * (forecastGrid.columns - 1)) / forecastGrid.columns
              height: Style.space(100)
              radius: FoamyStyle.radius
              color: selected ? view.selectedCardColor : (hasCursor ? view.cursorCardColor : view.cardColor)
              clip: true
              Behavior on color { ColorAnimation { duration: FoamyMotion.hover } }
              Item {
                anchors.bottom: parent.bottom
                width: parent.width
                height: Math.max(Style.space(2), Math.min(dayCard.radius, dayCard.width / 2, dayCard.height / 2))
                visible: dayCard.selected
                clip: true
                // Two offset rounded fills reproduce an inset bottom shadow,
                // tapering to nothing at the sides instead of curling upward.
                Rectangle {
                  anchors.bottom: parent.bottom
                  width: dayCard.width
                  height: dayCard.height
                  radius: dayCard.radius
                  color: Commons.Color.accent
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
                Item {
                  width: parent.width
                  height: dayName.implicitHeight
                  Label { id: dayName; anchors.left: parent.left; text: view.dayLabel(dayCard.modelData, dayCard.index) }
                  Label { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: view.shortDate(dayCard.modelData); color: FoamyPalette.secondaryText; font.pixelSize: FoamyStyle.font.bodySmall }
                }
                Row {
                  spacing: Style.space(9)
                  WeatherConditionIcon { width: Style.space(36); height: width; symbol: dayCard.modelData.symbol; lightTheme: view.lightTheme; anchors.verticalCenter: parent.verticalCenter }
                  Label { text: view.temperature(dayCard.modelData.high); font.pixelSize: FoamyStyle.font.display; anchors.verticalCenter: parent.verticalCenter }
                  Label { text: view.temperature(dayCard.modelData.low); color: FoamyPalette.secondaryText; anchors.verticalCenter: parent.verticalCenter }
                }
                Row {
                  spacing: Style.space(6)
                  FoamyIcon { width: Style.space(13); height: width; name: "droplet"; color: FoamyPalette.secondaryText; anchors.verticalCenter: parent.verticalCenter }
                  Label {
                    text: view.precipitation(dayCard.modelData.precipitation) + " · " + (Model.formatIsoTime(dayCard.modelData.sunset) || "—")
                    color: FoamyPalette.secondaryText; font.pixelSize: FoamyStyle.font.bodySmall
                  }
                }
              }
              HoverHandler {
                cursorShape: Qt.PointingHandCursor
                onHoveredChanged: if (hovered) cursor.hover(dayCard.index)
              }
              TapHandler { onTapped: view.activate(dayCard.index) }
            }
          }
        }

        Item { width: 1; height: Style.space(16); visible: view.displayHours.length > 0 }
        Item {
          width: parent.width
          height: hourlyTitle.implicitHeight
          visible: view.displayHours.length > 0
          Label { id: hourlyTitle; anchors.left: parent.left; text: FoamyI18n.t("Hourly forecast") }
          Label {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, parent.width - hourlyTitle.implicitWidth - FoamyStyle.gapLarge)
            elide: Text.ElideRight
            text: view.selectedDay ? view.dayLabel(view.selectedDay, view.c.selectedDayIndex) + " · " + view.hourSummary : ""
            color: FoamyPalette.secondaryText; font.pixelSize: FoamyStyle.font.bodySmall
          }
        }
        Item { width: 1; height: Style.space(11); visible: view.displayHours.length > 0 }
        Grid {
          id: hourlyGrid
          width: parent.width
          visible: view.displayHours.length > 0
          columns: width < Style.space(480) ? 4 : 8
          Repeater {
            model: view.displayHours
            Item {
              required property var modelData
              width: hourlyGrid.width / hourlyGrid.columns
              height: Style.space(110)
              Column {
                anchors.verticalCenter: parent.verticalCenter; width: parent.width
                spacing: Style.space(5)
                Label { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: modelData.time; color: FoamyPalette.secondaryText; font.pixelSize: FoamyStyle.font.bodySmall }
                WeatherConditionIcon { anchors.horizontalCenter: parent.horizontalCenter; width: Style.space(34); height: width; symbol: modelData.symbol; lightTheme: view.lightTheme }
                Label { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: view.temperature(modelData.temperature) }
                Label { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: view.precipitation(modelData.precipitation); color: view.rainColor; font.pixelSize: FoamyStyle.font.bodySmall }
              }
            }
          }
        }

        Item { width: 1; height: Style.space(12) }
        Rectangle { width: parent.width; height: 1; color: FoamyPalette.divider }
        Item { width: 1; height: Style.space(10) }
        // Data and place-name sources (CC BY 4.0 / ODbL ask for attribution).
        Label {
          width: parent.width
          horizontalAlignment: Text.AlignLeft
          elide: Text.ElideRight
          text: view.c.automaticLabel ? FoamyI18n.t("MET Norway · OpenStreetMap") : FoamyI18n.t("MET Norway")
          color: FoamyPalette.secondaryText
          font.pixelSize: FoamyStyle.font.bodySmall
        }
      }
    }
  }

  // Built the first time Settings opens; kept with the body afterwards.
  Loader {
    id: settingsLoader
    anchors.fill: parent
    active: false
    visible: view.c.editingLocation
    Connections {
      target: view.c
      function onEditingLocationChanged() { if (view.c.editingLocation) settingsLoader.active = true }
    }
    Component.onCompleted: if (view.c.editingLocation) active = true
    sourceComponent: WeatherSettings { controller: view.c }
  }
}

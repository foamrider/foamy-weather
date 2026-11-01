pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "kit"
import "Model.js" as Model
import "Preferences.js" as Preferences
import "WeatherScene.js" as Scene

// The weather popup body: sky hero with the header, readings, three-day and
// hourly forecasts, attribution, and the settings page. Built on first open
// (FoamyPopup body). `controller` is the Panel, or the preview's mock with
// the same properties and functions.
//
// Keyboard (one cursor): arrows/hjkl walk the day cards, settings and the
// footer's refresh; moving onto a day selects it. Enter activates (with nothing
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
  // The footer's freshness line (next to its refresh button).
  readonly property string footerStatus: c.loading ? FoamyI18n.t("Refreshing…")
    : !c.networkReady ? FoamyI18n.t("Waiting for network…")
    : updatedText ? FoamyI18n.t("Updated %1", [updatedText]) : ""
  // The band's meta under the place: today's range, or what is missing.
  readonly property string headerMeta: !current
    ? (c.loading ? FoamyI18n.t("Loading weather…") : FoamyI18n.t("Waiting for weather"))
    : forecastDays.length
      ? FoamyI18n.t("High %1 · Low %2", [temperature(forecastDays[0].high), temperature(forecastDays[0].low)]) : ""

  // The sky shader and its blur need a GPU renderer (known once the popup
  // window exists) and weather to show.
  readonly property var skyConditions: Scene.conditions(current, c.now, c.configuredLocationState)
  readonly property bool skyAvailable: c.animations && GraphicsInfo.api !== GraphicsInfo.Software
    && GraphicsInfo.api !== GraphicsInfo.Unknown && skyConditions.available
  // 0 (night) … 1 (bright overcast, fog, snow by day); see Scene.brightness.
  readonly property real skyBrightness: Scene.brightness(skyConditions)
  // How much the sky competes with the text (Scene.glare).
  readonly property real skyGlare: Scene.glare(skyBrightness, lightTheme)
  // The strip's small labels over the sky: the muted tone, a step (light
  // themes: two) stronger.
  readonly property color stripMuted: skyShown ? Qt.tint(FoamyPalette.background, Qt.alpha(FoamyPalette.text, lightTheme ? 0.92 : 0.86)) : FoamyPalette.secondaryText
  // Latched: a shader that failed once keeps the wash (no retry loop).
  property bool skyFailed: false
  readonly property bool skyShown: skyAvailable && !skyFailed

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
  readonly property int settingsStop: forecastDays.length
  readonly property int refreshStop: forecastDays.length + 1
  FoamyCursor { id: cursor; count: view.forecastDays.length + 2 }

  function activate(index) {
    if (index >= 0 && index < forecastDays.length) c.selectedDayIndex = index
    else if (index === refreshStop) { if (!c.loading && c.networkReady) c.refresh(true) }
    else c.startEditingLocation()
  }
  // A wheel notch scrolls a normal amount (high-resolution wheels too).
  FoamyWheelScroll { target: weatherScroll }

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

  Component {
    id: skyComponent
    WeatherBackground {
      anchors.fill: parent
      current: view.current
      now: view.c.now
      location: view.c.configuredLocationState
      // Drawn only while the popup shows it; a still frame under reduced motion.
      shown: view.c.opened && !view.c.editingLocation && band.y + band.height > weatherScroll.contentY
      animate: !FoamyMotion.reduceMotion
      surfaceColor: Commons.Color.popups.background
      lightTheme: view.lightTheme
      cornerRadius: band.topRadius
      onFailed: view.skyFailed = true
    }
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

      // Immersive band: the MET sky undimmed behind the place, the reading
      // and a frosted strip of the current readings, all centred; Settings
      // stays in the trailing top corner. The kit's centred title and meta
      // stay empty: the place leads here, above the reading.
      FoamyHeroBand {
        id: band
        width: parent.width
        centered: true
        settingsHasCursor: cursor.at(view.settingsStop)
        onSettingsClicked: view.c.startEditingLocation()
        onSettingsHovered: function(hovered) { if (hovered) cursor.hover(view.settingsStop) }
        // The MET-driven sky is the band's picture when it can be drawn;
        // otherwise (animations setting off, CPU rendering, no data, a
        // shader error) the kit's static wash.
        background: view.skyShown ? skyComponent : null
        // No readability scrim (it greys the sky out): the sky itself is
        // toned for the text (WeatherBackground) and the strip has its own
        // surface.
        scrim: false
        // Settings over the sky: the full text tone, like the headline (the
        // muted one fades into a bright sky).
        Binding {
          target: band.settingsButton
          property: "foreground"
          value: FoamyPalette.text
          when: view.skyShown
        }

        ColumnLayout {
          id: headline
          objectName: "weatherHeadline"
          // The hero slot's width, read from the band (not from the layout,
          // which sizes itself from these rows).
          readonly property real room: Math.max(0, band.width - band.centeredInset * 2)
          // Its rows don't stretch, so as a layout it wouldn't either.
          Layout.preferredWidth: room
          spacing: FoamyStyle.gapSmall

          // The place, level with the Settings button.
          Row {
            id: placeRow
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredHeight: FoamyStyle.settingsButtonSize
            spacing: FoamyStyle.gap
            FoamyIcon {
              id: pin
              anchors.verticalCenter: parent.verticalCenter
              width: FoamyStyle.iconSize; height: width
              name: "map-pin"
              color: FoamyPalette.text
            }
            Label {
              objectName: "weatherPlace"
              anchors.verticalCenter: parent.verticalCenter
              width: Math.min(implicitWidth, headline.room - pin.width - placeRow.spacing)
              text: view.c.reportLocation || FoamyI18n.t("Choose location")
              elide: Text.ElideRight
              font.pixelSize: FoamyStyle.font.title
              font.weight: Font.DemiBold
            }
          }

          // The reading, and beside it the condition over today's range,
          // bottom-aligned: the range sits on the numeral's baseline.
          Row {
            id: heroRow
            Layout.alignment: Qt.AlignHCenter
            spacing: FoamyStyle.gapLarge + FoamyStyle.gapSmall

            Row {
              id: readingGroup
              // A reading and its unit ("13 °C") stay in that order in a
              // right-to-left layout too, the way bidi text keeps them.
              LayoutMirroring.enabled: false
              spacing: FoamyStyle.gapSmall
              baselineOffset: reading.y + reading.baselineOffset
              Label {
                id: reading
                text: view.current ? Preferences.temperatureValue(view.current.temperature, view.c.units, FoamyI18n.number) : "--"
                font.pixelSize: FoamyStyle.font.numeral
              }
              // Superscript: the unit's cap height meets the numeral's.
              Label {
                id: unit
                visible: !!view.current
                anchors.baseline: reading.baseline
                anchors.baselineOffset: unitMetrics.capHeight - numeralMetrics.capHeight
                text: view.c.units === "imperial" ? "°F" : "°C"
                font.pixelSize: FoamyStyle.font.display
              }
              // (`font` is read so the heights follow font changes.)
              FontMetrics {
                id: numeralMetrics
                readonly property real capHeight: { font; return tightBoundingRect("0").height }
                font: reading.font
              }
              FontMetrics {
                id: unitMetrics
                readonly property real capHeight: { font; return tightBoundingRect("C").height }
                font: unit.font
              }
            }

            Column {
              id: conditionColumn
              readonly property real available: Math.max(0, headline.room - readingGroup.width - heroRow.spacing)
              anchors.baseline: readingGroup.baseline
              baselineOffset: rangeText.y + rangeText.baselineOffset
              spacing: FoamyStyle.gapSmall
              // Lines start at the reading edge (mirrored anchors in RTL).
              Row {
                id: conditionRow
                anchors.left: parent.left
                visible: !!view.current
                spacing: FoamyStyle.gap
                WeatherConditionIcon {
                  id: conditionIcon
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(26); height: width
                  symbol: view.current ? view.current.symbol : "cloudy"
                  lightTheme: view.lightTheme
                }
                Label {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.min(implicitWidth, conditionColumn.available - conditionIcon.width - conditionRow.spacing)
                  text: view.c.currentDescription
                  elide: Text.ElideRight
                  font.pixelSize: FoamyStyle.font.iconLarge
                }
              }
              // Today's range, or what is missing.
              Label {
                id: rangeText
                anchors.left: parent.left
                width: Math.min(implicitWidth, conditionColumn.available)
                text: view.headerMeta
                elide: Text.ElideRight
                // The muted tone is too faint on a bright sky (fog, snow).
                color: view.skyShown ? FoamyPalette.text : FoamyPalette.secondaryText
                font.pixelSize: FoamyStyle.font.body
              }
            }
          }
        }

        // The current readings on a frosted strip at the band's foot. The
        // hero slot keeps clear of the Settings button on both sides; the
        // strip runs to the band's own padding instead.
        Item {
          visible: !!view.current
          Layout.fillWidth: true
          Layout.topMargin: FoamyStyle.gapLarge
          implicitHeight: strip.height
          Rectangle {
            id: strip
            objectName: "weatherMetricStrip"
            x: FoamyStyle.padding - band.centeredInset
            width: band.width - FoamyStyle.padding * 2
            height: metricGrid.height
            radius: FoamyStyle.radius
            // Over the sky: more opaque the more the sky competes with the
            // text (bright skies in dark themes, dark ones in light themes).
            color: Qt.alpha(Commons.Color.popups.background, !view.skyShown ? 0.35
              : (view.lightTheme ? 0.70 : 0.58) + 0.2 * view.skyGlare)
            border.width: Style.spacing.hairline
            border.color: Qt.alpha(Commons.Color.popups.text, 0.08)

            Grid {
              id: metricGrid
              width: parent.width
              columns: width < Style.space(380) ? 2 : 4
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
                  height: metricColumn.implicitHeight + FoamyStyle.gapLarge * 2
                  Rectangle {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.spacing.hairline; height: parent.height - FoamyStyle.gapLarge * 2
                    color: FoamyPalette.divider
                    visible: parent.index % metricGrid.columns < metricGrid.columns - 1
                  }
                  Column {
                    id: metricColumn
                    width: parent.width
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(3)
                    Row {
                      anchors.horizontalCenter: parent.horizontalCenter
                      spacing: Style.space(5)
                      FoamyIcon { anchors.verticalCenter: parent.verticalCenter; width: Style.space(13); height: width; name: modelData.icon; color: view.stripMuted }
                      Label { anchors.verticalCenter: parent.verticalCenter; text: modelData.label; color: view.stripMuted; font.pixelSize: FoamyStyle.font.bodySmall; font.letterSpacing: 0.6 }
                    }
                    Label { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.value; font.pixelSize: FoamyStyle.font.heading }
                    Label { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.detail; color: view.stripMuted; font.pixelSize: FoamyStyle.font.bodySmall }
                  }
                }
              }
            }
          }
        }
      }
      Column {
        id: body
        objectName: "weatherBody"
        x: FoamyStyle.padding
        width: parent.width - FoamyStyle.padding * 2
        topPadding: FoamyStyle.sectionGap

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
              name: note.info ? "info" : "triangle-alert"
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
              // The selected day: an even accent hairline on every side (no
              // heavier bottom edge), as the clock's selected date.
              border.width: selected ? Style.spacing.hairline : 0
              border.color: Commons.Color.accent
              clip: true
              Behavior on color { ColorAnimation { duration: FoamyMotion.hover } }
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

        Item { width: 1; height: FoamyStyle.gapLarge }
        // Data and place-name sources (CC BY 4.0 / ODbL ask for attribution),
        // when the report was fetched, and refresh.
        FoamyPanelFooter {
          id: footer
          width: parent.width
          source: view.c.automaticLabel ? FoamyI18n.t("MET Norway · OpenStreetMap") : FoamyI18n.t("MET Norway")
          status: view.footerStatus
          refreshing: view.c.opened && view.c.loading
          refreshEnabled: view.c.networkReady
          refreshTooltip: view.c.loading ? FoamyI18n.t("Refreshing…") : (!view.c.networkReady ? FoamyI18n.t("Waiting for network…") : FoamyI18n.t("Refresh"))
          refreshHasCursor: cursor.at(view.refreshStop)
          onRefreshHovered: function(hovered) { if (hovered) cursor.hover(view.refreshStop) }
          onRefreshClicked: view.activate(view.refreshStop)
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

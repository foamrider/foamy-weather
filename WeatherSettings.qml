pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "kit"

// Weather settings: location (automatic or a searched place) and display.
// Same width as the forecast. Esc or Back returns; Tab walks the controls.
FoamySettingsPage {
  id: page

  required property QtObject controller
  readonly property QtObject c: controller

  saving: c.saving || c.savingLocation
  error: c.settingsError ? FoamyI18n.t(c.settingsError) : c.saveError ? FoamyI18n.t(c.saveError) : ""
  retryable: c.canRetry
  onBack: c.cancelEditingLocation()
  onRetry: c.retrySave()

  Connections {
    target: page.c
    ignoreUnknownSignals: true
    function onSearchCleared() { locationField.text = "" }
  }

  FoamySettingsSection {
    width: parent.width
    title: FoamyI18n.t("Location")

    FoamyToggle {
      width: parent.width
      label: FoamyI18n.t("Use location data")
      description: FoamyI18n.t("Automatic via GeoClue. Your location is used by MET Norway and OpenStreetMap.")
      checked: page.c.automaticLocation
      enabled: !page.c.saving && !page.c.savingLocation
      onClicked: page.c.savePreference("automaticLocation", !page.c.automaticLocation)
    }

    Text {
      visible: page.c.automaticLocation && (page.c.resolvingLocation || page.c.dynamicLocationErrorText !== "")
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      horizontalAlignment: Text.AlignLeft
      text: page.c.resolvingLocation ? FoamyI18n.t("Finding location…") : page.c.dynamicLocationErrorText
      color: FoamyPalette.mutedText
      font.family: FoamyStyle.fontFamily
      font.pixelSize: FoamyStyle.font.bodySmall
    }

    SafeTextField {
      id: locationField
      objectName: "weatherLocationField"
      visible: !page.c.automaticLocation
      width: parent.width
      enabled: !page.c.savingLocation
      Accessible.name: FoamyI18n.t("Location")
      placeholderText: FoamyI18n.t("Search for a location")
      translate: FoamyI18n.t
      onTextEdited: page.c.searchEdited(text)
      onPasteErrorChanged: if (pasteError) page.c.settingsError = pasteError
      onKeyPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          page.c.cancelEditingLocation()
          event.accepted = true
        } else if (event.key === Qt.Key_Down) {
          page.c.moveSuggestion(1)
          event.accepted = true
        } else if (event.key === Qt.Key_Up) {
          page.c.moveSuggestion(-1)
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          page.c.commitLocation()
          event.accepted = true
        }
      }
    }

    Repeater {
      model: page.c.automaticLocation ? [] : page.c.locationSuggestions

      FoamyCursorSurface {
        id: suggestion
        required property var modelData
        required property int index
        width: parent.width
        height: suggestionText.implicitHeight + Style.space(12)
        hasCursor: index === page.c.suggestionIndex
        onHovered: page.c.suggestionIndex = index
        onClicked: page.c.pickSuggestion(modelData)

        Text {
          id: suggestionText
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.leftMargin: FoamyStyle.gapLarge
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - FoamyStyle.gapLarge * 2
          horizontalAlignment: Text.AlignLeft
          wrapMode: Text.WordWrap
          text: suggestion.modelData.name + (suggestion.modelData.description ? "  ·  " + suggestion.modelData.description : "")
          color: FoamyPalette.text
          font.family: FoamyStyle.fontFamily
          font.pixelSize: FoamyStyle.font.body
        }
      }
    }

    Text {
      visible: !page.c.automaticLocation && (page.c.searching || page.c.searchCompleted && !page.c.locationSuggestions.length)
      width: parent.width
      textFormat: Text.PlainText
      horizontalAlignment: Text.AlignLeft
      text: page.c.searching ? FoamyI18n.t("Searching…") : FoamyI18n.t("No locations found")
      color: FoamyPalette.mutedText
      font.family: FoamyStyle.fontFamily
      font.pixelSize: FoamyStyle.font.bodySmall
    }
  }

  FoamySettingsSection {
    width: parent.width
    title: FoamyI18n.t("Display")

    FoamyDropdown {
      width: parent.width
      compact: true
      label: FoamyI18n.t("Units")
      value: page.c.units
      options: [
        { value: "metric", label: FoamyI18n.t("Metric (°C, km/h, mm)") },
        { value: "imperial", label: FoamyI18n.t("Imperial (°F, mph, in)") }
      ]
      enabled: !page.c.saving
      onChanged: function(value) { page.c.savePreference("units", value) }
    }

    FoamyToggle {
      width: parent.width
      label: FoamyI18n.t("Animated background")
      description: FoamyMotion.reduceMotion ? FoamyI18n.t("Shown as a still image while animations are off.") : ""
      checked: page.c.animations
      enabled: !page.c.saving
      onClicked: page.c.savePreference("animations", !page.c.animations)
    }
  }
}

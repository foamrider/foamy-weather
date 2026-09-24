import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "foamy.weather"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh(force) {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh(force === true)
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  function notifySummary() {
    if (panelLoader.item && panelLoader.item.notifySummary) panelLoader.item.notifySummary()
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  readonly property real openPanelIndicatorWidth: button.labelWidth

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? "" : (panelLoader.item ? panelLoader.item.barLabel : "󰖐 --")
    labelVisible: !root.vertical
    hasVisualContent: true
    horizontalMargin: 8.75
    verticalPadding: 8.75

    onPressed: function(b) {
      if (b === Qt.RightButton) root.notifySummary()
      else if (b === Qt.MiddleButton) root.refresh(true)
      else root.togglePanel()
    }

    OpticalGlyph {
      visible: root.vertical
      anchors.fill: parent
      text: panelLoader.item ? panelLoader.item.conditionIcon : "󰖐"
      fontFamily: button.fontFamily
      fontSize: button.fontSize
      color: button.foreground
    }
  }
}

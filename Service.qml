import QtQuick
import Quickshell
import Quickshell.Io
import "kit"
import "Model.js" as Model

// The plugin's service entry point: the shell creates one per shell (not per
// bar) while foamy.weather is enabled, through a `plugins[]` entry or its bar
// widget. It owns the `foamy.weather` IPC target, so `current()` answers with
// no bar widget, and feeds WeatherService the plugin's shell.json entry. The
// weather itself is the WeatherService singleton the bar widgets share: an
// idle service starts on a current() call and stops 30 minutes after the
// last one (or when the last widget goes, whichever is later).
QtObject {
  id: root

  readonly property string configPath: (Quickshell.env("HOME") || "") + "/.config/omarchy/shell.json"
  // The handler turns on a turn after this entry took the target over, so a
  // Panel's fallback handler is off first (one live handler per target).
  property bool ipcLive: false

  function panel() {
    return WeatherService.widgetPanel
  }

  function panelCall(name) {
    var target = panel()
    if (target && typeof target[name] === "function") target[name]()
  }

  function applyConfig(text) {
    var entry = Model.pluginEntry(text, "foamy.weather")
    // An unreadable or half-written shell.json keeps the last settings.
    if (!entry.valid) return
    if (JSON.stringify(entry.settings) !== JSON.stringify(WeatherService.serviceSettings))
      WeatherService.serviceSettings = entry.settings
  }

  Component.onCompleted: {
    WeatherService.host = root
    Qt.callLater(function() {
      if (WeatherService.host === root) root.ipcLive = true
    })
  }
  Component.onDestruction: {
    ipcLive = false
    if (WeatherService.host === root) WeatherService.host = null
  }

  // The scoped service API offers no read of the plugin's own entry; watch
  // the same shell.json as Omarchy (read only, never written here).
  property FileView configFile: FileView {
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyConfig(text())
  }

  property FoamyIpc ipc: FoamyIpc {
    target: "foamy.weather"
    enabled: root.ipcLive

    // The popup belongs to the bar widget: these do nothing without one.
    function open(): void { root.panelCall("openFromHotkey") }
    function close(): void { root.panelCall("close") }
    function show(): void { root.panelCall("openFromHotkey") }
    function hide(): void { root.panelCall("close") }
    function toggle(): void { root.panelCall("toggle") }
    function edit(): void {
      root.panelCall("openFromHotkey")
      root.panelCall("startEditingLocation")
    }
    function refresh(): void {
      if (root.panel()) root.panel().refresh(true)
      else {
        WeatherService.touch()
        WeatherService.refresh(true)
      }
    }
    function current(): string { return WeatherService.currentReply() }
  }
}

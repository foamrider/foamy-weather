import QtQuick
import QtQuick.Effects
import "WeatherScene.js" as Scene

Item {
  id: root
  property var current: null
  property date now: new Date()
  property var location: null
  property bool active: false
  property color surfaceColor: "#1e1e2e"
  property bool lightTheme: false
  property real cornerRadius: 13
  readonly property var conditions: Scene.conditions(current, now, location)
  readonly property bool animating: active && conditions.available && sky.status !== ShaderEffect.Error
  property real elapsed: 0
  property real windOffset: 41.7
  property real evolution: 7.3
  clip: true

  // Limit both fragment work and updates; no animation timer runs while closed.
  Timer {
    interval: 50
    repeat: true
    running: root.animating
    onTriggered: {
      root.elapsed = (root.elapsed + 0.05) % 4096
      root.windOffset += (0.006 + root.conditions.wind * 0.22) * 0.05
      root.evolution += (0.07 + root.conditions.wind * 0.09) * 0.05
    }
  }

  Image {
    id: noise
    source: "shaders/noise.png"
    visible: false
    smooth: true
    mipmap: false
    fillMode: Image.Tile
  }

  ShaderEffectSource {
    id: noiseTexture
    sourceItem: noise
    visible: false
    live: false
    wrapMode: ShaderEffectSource.Repeat
    textureSize: Qt.size(256, 256)
  }

  ShaderEffect {
    id: sky
    width: root.width
    height: root.height
    fragmentShader: "shaders/atmosphere.frag.qsb"
    property variant u_noise: noiseTexture
    property vector2d u_res: Qt.vector2d(width, height)
    property real u_time: root.elapsed
    property vector3d u_cam: Qt.vector3d(Math.PI, 0.45, 0.85)
    property vector2d u_sun: Qt.vector2d(root.conditions.sunElevation, root.conditions.sunAzimuth)
    property real u_cover: root.conditions.cover
    property vector3d u_high: Qt.vector3d(root.conditions.high[0], root.conditions.high[1], root.conditions.high[2])
    property vector3d u_mid: Qt.vector3d(root.conditions.mid[0], root.conditions.mid[1], root.conditions.mid[2])
    property vector4d u_low: Qt.vector4d(root.conditions.low[0], root.conditions.low[1], root.conditions.low[2], root.conditions.low[3])
    property real u_rain: root.conditions.rain
    property real u_snow: root.conditions.snow
    property real u_wind: root.conditions.wind
    property real u_thunder: root.conditions.thunder
    property real u_haze: root.conditions.haze
    property vector2d u_cbFeat: Qt.vector2d(0.4, 0.1)
    property real u_windOff: root.windOffset
    property real u_evo: root.evolution
    property real u_filtAmt: 0
    property vector3d u_filtTint: Qt.vector3d(1, 1, 1)
    property real u_filtSat: 1
    property real u_filtLift: 0
    property real u_p3: 0
    property real u_headroom: 1
    property vector4d u_tone: Qt.vector4d(0, 1, 0.8, 0)
    property vector4d u_pol: Qt.vector4d(0, 0, 0, 0)
    property vector4d u_sky: Qt.vector4d(6, 0, 0, 0)
    property vector2d u_radiant: Qt.vector2d(0, 0)
    onStatusChanged: {
      if (status === ShaderEffect.Error)
        console.warn("Weather background shader failed; keeping static header:", log)
    }
  }

  ShaderEffectSource {
    id: sampledSky
    sourceItem: sky
    hideSource: true
    visible: false
    live: root.animating
    // The default texture size follows the window pixel ratio, including HiDPI displays.
  }

  Item {
    id: roundedMask
    width: root.width
    height: root.height
    visible: false
    layer.enabled: true
    Rectangle { width: parent.width; height: parent.height + root.cornerRadius; radius: root.cornerRadius; color: "white" }
  }

  MultiEffect {
    anchors.fill: parent
    source: sampledSky
    visible: root.conditions.available && sky.status !== ShaderEffect.Error
    blurEnabled: true
    blurMax: 16
    blur: 0.15
    autoPaddingEnabled: false
    maskEnabled: true
    maskSource: roundedMask
  }

  Rectangle {
    width: root.width
    height: root.height + root.cornerRadius
    radius: root.cornerRadius
    visible: root.conditions.available && sky.status !== ShaderEffect.Error
    gradient: Gradient {
      GradientStop { position: 0; color: Qt.alpha(root.surfaceColor, root.lightTheme ? 0.30 : 0.15) }
      GradientStop { position: 0.7; color: Qt.alpha(root.surfaceColor, root.lightTheme ? 0.45 : 0.25) }
      GradientStop { position: root.height / Math.max(1, root.height + root.cornerRadius); color: root.surfaceColor }
    }
  }
}

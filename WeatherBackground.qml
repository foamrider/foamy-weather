import QtQuick
import QtQuick.Effects
import qs.Commons as Commons
import "WeatherScene.js" as Scene

// The MET-driven sky behind the weather hero. Costs nothing while hidden:
// no timer, no live texture, and a hidden popup window renders nothing.
// While `shown` it renders at 20 Hz, or under reduced motion (`animate`
// false) a single still frame that updates only when the weather changes.

Item {
  id: root
  property var current: null
  property date now: new Date()
  property var location: null
  property bool shown: false
  property bool animate: true
  property color surfaceColor: Commons.Color.popups.background
  property bool lightTheme: false
  property real cornerRadius: 13
  readonly property var conditions: Scene.conditions(current, now, location)
  // Per-second drift; calm weather still moves (see Scene.drift).
  readonly property var drift: Scene.drift(conditions.wind)
  readonly property real brightness: Scene.brightness(conditions)
  readonly property real glare: Scene.glare(brightness, lightTheme)
  // How far the sky is toned for white text (dark themes): any daylight sky
  // competes with it; night skies are left as they are.
  readonly property real calmAmount: lightTheme ? 0 : Math.min(1, glare / 0.5)
  // The software renderer (CPU rendering) draws neither shaders nor
  // MultiEffect; keep the static header there.
  readonly property bool supported: GraphicsInfo.api !== GraphicsInfo.Software && GraphicsInfo.api !== GraphicsInfo.Unknown
  readonly property bool drawable: supported && shown && conditions.available && sky.status !== ShaderEffect.Error
  readonly property bool animating: drawable && animate
  // The shader could not be built; the view falls back to the plain band.
  signal failed()
  property real elapsed: 0
  property real windOffset: 41.7
  property real evolution: 7.3
  clip: true

  // A still frame: refresh the texture once when it becomes visible or the
  // scene inputs change, never on a clock.
  function stillFrame() {
    if (drawable && !animate) sampledSky.scheduleUpdate()
  }
  onDrawableChanged: stillFrame()
  onAnimateChanged: stillFrame()
  onConditionsChanged: stillFrame()
  onWidthChanged: stillFrame()
  onHeightChanged: stillFrame()

  // Limit both fragment work and updates; no animation timer runs while closed.
  Timer {
    interval: 50
    repeat: true
    running: root.animating
    onTriggered: {
      root.elapsed = (root.elapsed + 0.05) % 4096
      root.windOffset += root.drift.offset * 0.05
      root.evolution += root.drift.evolution * 0.05
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
    // Under white text the sky also leans a little toward the theme
    // surface's hue (more where it is toned), so greys (fog, overcast) go
    // the theme's way rather than muddy.
    property real u_filtAmt: root.lightTheme ? 0 : 0.15 + 0.25 * root.calmAmount
    property vector3d u_filtTint: {
      var c = root.surfaceColor
      var l = Math.max(0.02, 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b)
      return Qt.vector3d(0.5 + 0.5 * c.r / l, 0.5 + 0.5 * c.g / l, 0.5 + 0.5 * c.b / l)
    }
    property real u_filtSat: 1
    property real u_filtLift: 0
    property real u_p3: 0
    property real u_headroom: 1
    property vector4d u_tone: Qt.vector4d(0, 1, 0.8, 0)
    property vector4d u_pol: Qt.vector4d(0, 0, 0, 0)
    property vector4d u_sky: Qt.vector4d(6, 0, 0, 0)
    property vector2d u_radiant: Qt.vector2d(0, 0)
    // The sky toned for the text over it (see the shader's "Calm"): a dark
    // theme's white text gets bright skies rolled off toward a deep, still
    // vivid range (deepest behind the title and reading); a light theme's
    // dark text gets the sky lifted. Night skies in a dark theme are left
    // as they are.
    property vector4d u_calm: root.lightTheme
      ? Qt.vector4d(0, 0, 0, 0.2 + 0.4 * root.glare)
      : Qt.vector4d(root.calmAmount, 0.32, 0.13, 0)
    onStatusChanged: {
      if (status === ShaderEffect.Error) {
        console.warn("Weather background shader failed; keeping static header:", log)
        root.failed()
      }
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
    visible: root.supported && root.conditions.available && sky.status !== ShaderEffect.Error
    blurEnabled: true
    blurMax: 16
    blur: 0.15
    autoPaddingEnabled: false
    maskEnabled: true
    maskSource: roundedMask
  }

  Rectangle {
    id: veil
    width: root.width
    height: root.height + root.cornerRadius
    radius: root.cornerRadius
    visible: root.supported && root.conditions.available && sky.status !== ShaderEffect.Error
    // The sky is toned in the shader; this only settles it a touch toward
    // the surface and fades it into the body at the bottom.
    readonly property real amount: root.lightTheme ? 0.12 : 0.06
    gradient: Gradient {
      GradientStop { position: 0; color: Qt.alpha(root.surfaceColor, veil.amount) }
      GradientStop { position: 0.6; color: Qt.alpha(root.surfaceColor, veil.amount) }
      GradientStop { position: root.height / Math.max(1, root.height + root.cornerRadius); color: root.surfaceColor }
    }
  }
}

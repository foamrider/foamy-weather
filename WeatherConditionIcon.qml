import QtQuick
import QtQuick.Effects
import qs.Commons as Commons
import "WeatherIcons.js" as Icons

Image {
  property string symbol: "cloudy"
  property bool lightTheme: false
  source: Qt.resolvedUrl("icons/" + Icons.assetForSymbol(symbol) + ".svg")
  sourceSize.width: Math.ceil(width * 2)
  sourceSize.height: Math.ceil(height * 2)
  fillMode: Image.PreserveAspectFit
  // Keep pale clouds distinct from light popup surfaces without recoloring the SVG.
  // MultiEffect needs a GPU renderer; without one the plain icon is drawn.
  layer.enabled: lightTheme && GraphicsInfo.api !== GraphicsInfo.Software
  layer.effect: MultiEffect {
    shadowEnabled: true
    // A soft shade of the theme's text colour (dark on light themes).
    shadowColor: Commons.Color.popups.text
    shadowOpacity: 0.35
    shadowBlur: 0.15
    blurMax: 8
    shadowVerticalOffset: 1
  }
}

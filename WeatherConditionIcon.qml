import QtQuick
import QtQuick.Effects
import "WeatherIcons.js" as Icons

Image {
  property string symbol: "cloudy"
  property bool lightTheme: false
  source: Qt.resolvedUrl("icons/" + Icons.assetForSymbol(symbol) + ".svg")
  sourceSize.width: Math.ceil(width * 2)
  sourceSize.height: Math.ceil(height * 2)
  fillMode: Image.PreserveAspectFit
  // Keep pale clouds distinct from light popup surfaces without recoloring the SVG.
  layer.enabled: lightTheme
  layer.effect: MultiEffect {
    shadowEnabled: true
    shadowColor: "#52657d"
    shadowOpacity: 0.6
    shadowBlur: 0.15
    blurMax: 8
    shadowVerticalOffset: 1
  }
}

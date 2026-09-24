import QtQuick
import "WeatherIcons.js" as Icons

Image {
  id: root
  property string name: "cloud"
  property color color: "white"
  property real strokeWidth: 1.7
  sourceSize.width: Math.ceil(width * 2)
  sourceSize.height: Math.ceil(height * 2)
  fillMode: Image.PreserveAspectFit
  // Inline SVG keeps the original stroke geometry and follows the active theme.
  source: "data:image/svg+xml;charset=utf-8," + encodeURIComponent(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="'
    + color.toString() + '" stroke-width="' + strokeWidth
    + '" stroke-linecap="round" stroke-linejoin="round">'
    + (Icons.paths[name] || Icons.paths.cloud) + '</svg>')
}

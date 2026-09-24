const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const { assetForSymbol } = require("../WeatherIcons.js")

const examples = {
  clearsky_day: "clear-day",
  clearsky_night: "clear-night",
  fair_day: "mostly-clear-day",
  partlycloudy_night: "partly-cloudy-night",
  fair_polartwilight: "mostly-clear-night",
  cloudy: "cloudy",
  fog: "fog",
  lightrain: "drizzle",
  heavyrain: "extreme-rain",
  sleet: "sleet",
  rainshowers_day: "partly-cloudy-day-rain",
  snowshowers_night: "partly-cloudy-night-snow",
  heavyrainandthunder: "thunderstorms-extreme-rain",
  lightssleetshowersandthunder_day: "thunderstorms-day-sleet",
  lightssnowshowersandthunder_night: "thunderstorms-night-snow",
  unknown: "cloudy"
}
for (const [symbol, asset] of Object.entries(examples))
  assert.equal(assetForSymbol(symbol), asset, symbol)
assert.equal(assetForSymbol(null), "cloudy")
assert.equal(assetForSymbol("../../outside"), "cloudy")

// Exercise the full MET precipitation family against the actual vendored files.
const symbols = Object.keys(examples)
for (const weight of ["light", "", "heavy"])
  for (const precipitation of ["rain", "snow", "sleet"])
    for (const showers of ["", "showers"])
      for (const thunder of ["", "andthunder"])
        for (const suffix of ["", "_day", "_night", "_polartwilight"])
          symbols.push(weight + precipitation + showers + thunder + suffix)
for (const symbol of symbols) {
  const file = path.join(__dirname, "../icons", assetForSymbol(symbol) + ".svg")
  const svg = fs.readFileSync(file, "utf8")
  assert.match(svg, /<svg\s/)
  assert.doesNotMatch(svg, /<(?:script|animate|set)\b|\bhref=/)
}
console.log("Weather icons passed: MET conditions, day/night, fallbacks, and local static SVG assets.")

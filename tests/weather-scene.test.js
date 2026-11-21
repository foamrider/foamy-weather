const assert = require("node:assert/strict")
const { inspect } = require("node:util")
const Scene = require("../WeatherScene.js")
const noon = new Date("2026-09-24T10:00:00Z")
const location = { latitude: 51.48, longitude: 0 }
const scene = symbol => Scene.conditions({ symbol }, noon, location)

for (const symbol of ["clearsky_day", "fair_night", "partlycloudy_polartwilight", "cloudy", "fog"]) {
  assert.equal(scene(symbol).available, true)
  assert.equal(scene(symbol).rain, 0)
  assert.equal(scene(symbol).snow, 0)
}
for (const weight of ["light", "", "heavy"]) {
  for (const precipitation of ["rain", "snow", "sleet"]) {
    for (const showers of ["", "showers"]) {
      for (const thunder of ["", "andthunder"]) {
        for (const suffix of ["", "_day", "_night", "_polartwilight"]) {
          const result = scene(weight + precipitation + showers + thunder + suffix)
          assert.equal(result.available, true)
          assert.equal(result.rain > 0, precipitation !== "snow")
          assert.equal(result.snow > 0, precipitation !== "rain")
          assert.equal(result.thunder > 0, thunder !== "")
          assert.ok(result.cover >= 0.75)
        }
      }
    }
  }
}
assert.ok(scene("heavyrain").rain > scene("lightrain").rain)
// MET keeps these two misspellings in its public codes; both must draw the
// sky of the correctly spelled code.
for (const code of ["lightssleetshowersandthunder", "lightssnowshowersandthunder"]) {
  for (const suffix of ["", "_day", "_night", "_polartwilight"]) {
    assert.equal(scene(code + suffix).available, true, code + suffix)
    assert.deepEqual(scene(code + suffix), scene(code.replace("lights", "light") + suffix), code + suffix)
  }
}
assert.ok(scene("fog").haze > scene("clearsky_day").haze)
assert.equal(Scene.conditions(null, noon, location).available, false)
assert.equal(scene("unrecognized").available, false)
assert.equal(Scene.conditions({ symbol: "rain", precipitation: 30 }, noon, location).rain, 0.5,
  "Do not treat a multi-hour precipitation sum as an hourly rate")
// Every value goes to the sky shader as a uniform, where NaN or an out of
// range value draws garbage: any current point gives bounded inputs.
const hostile = [NaN, Infinity, -Infinity, -50, 1e9, "80", null]
const points = [null, { symbol: 42 }, { symbol: {} }, { symbol: "x".repeat(100000) }]
for (const value of hostile) {
  points.push({ symbol: "rain", windSpeed: value }, { symbol: "cloudy", cloudCover: value },
    { symbol: "rain", precipitationOneHour: value })
}
const places = { "a place": [noon, location], "latitude 91": [noon, { latitude: 91, longitude: 0 }],
  "text coordinates": [noon, { latitude: "59", longitude: "10" }], "an invalid date": [new Date(NaN), location] }
const unit = (value, name) => assert.ok(Number.isFinite(value) && value >= 0 && value <= 1, name + " = " + value)
for (const point of points) {
  for (const [placeName, [when, place]] of Object.entries(places)) {
    const c = Scene.conditions(point, when, place)
    const name = inspect(point, { maxStringLength: 20, breakLength: Infinity }) + " with " + placeName
    for (const key of ["cover", "rain", "snow", "thunder", "wind", "haze"]) unit(c[key], name + ": " + key)
    for (const key of ["high", "mid", "low"]) c[key].forEach((value, i) => unit(value, name + ": " + key + i))
    assert.ok(Number.isFinite(c.sunElevation) && Number.isFinite(c.sunAzimuth), name + ": sun")
    const light = Scene.brightness(c)
    unit(light, name + ": brightness")
    unit(Scene.glare(light, false), name + ": dark theme glare")
    unit(Scene.glare(light, true), name + ": light theme glare")
    const pace = Scene.drift(c.wind)
    assert.ok(Number.isFinite(pace.offset) && pace.offset > 0 && Number.isFinite(pace.evolution) && pace.evolution > 0, name + ": drift")
  }
}
assert.equal(Scene.conditions({ symbol: "rain", precipitationOneHour: 100 }, noon, location).rain, 1)
assert.equal(Scene.conditions({ symbol: "clearsky_day", cloudCover: 100 }, noon, location).cover, 0.08)
assert.ok(Scene.solarPosition(noon, location.latitude, location.longitude).elevation > 0)
assert.ok(Scene.solarPosition(new Date("2026-09-24T22:00:00Z"), location.latitude, location.longitude).elevation < 0)
assert.ok(Scene.solarPosition(new Date("2026-06-21T22:00:00Z"), 78, 15).elevation > 0, "Polar summer remains daylight")
assert.ok(Scene.solarPosition(new Date("2026-12-21T10:00:00Z"), 78, 15).elevation < 0, "Polar winter remains dark")
assert.ok(Scene.conditions({ symbol: "clearsky_night" }, noon, null).sunElevation < 0)
assert.ok(Scene.conditions({ symbol: "fair_polartwilight" }, noon, { latitude: null, longitude: null }).sunElevation < 0)
// Drift: calm air and fog still move (the old pace left calm fog static),
// and the pace never falls with the wind.
const calm = Scene.drift(0)
assert.ok(calm.offset >= 0.03 && calm.evolution >= 0.12, "calm weather drifts")
for (let w = 0; w < 1; w += 0.05) {
  assert.ok(Scene.drift(w + 0.05).offset >= Scene.drift(w).offset && Scene.drift(w + 0.05).evolution >= Scene.drift(w).evolution)
}
assert.deepEqual(Scene.drift(NaN), calm)
assert.deepEqual(Scene.drift(Scene.conditions({ symbol: "fog", windSpeed: 0.8 }, noon, location).wind), calm, "3 km/h fog drifts at the floor")
// Brightness: night 0, a clear day mid, overcast/fog/snow by day brightest.
const at = (symbol, when) => Scene.brightness(Scene.conditions({ symbol }, when, location))
assert.equal(at("cloudy", new Date("2026-09-24T23:00:00Z")), 0)
assert.ok(at("clearsky_day", noon) > 0.4 && at("clearsky_day", noon) < 0.7)
for (const symbol of ["cloudy", "fog", "heavysnow"]) assert.ok(at(symbol, noon) > 0.9, symbol)
assert.equal(Scene.brightness(Scene.conditions(null, noon, location)), 0)
// Glare: a dark theme's light text competes with bright skies only; a light
// theme's dark text with every sky, most at night.
assert.equal(Scene.glare(0, false), 0)
assert.equal(Scene.glare(1, false), 1)
assert.equal(Scene.glare(0, true), 1)
assert.ok(Scene.glare(1, true) >= 0.5)
assert.equal(Scene.glare(NaN, false), 0)
console.log("Weather scene tests passed (all MET precipitation variants, missing data, solar and polar conditions, drift).")

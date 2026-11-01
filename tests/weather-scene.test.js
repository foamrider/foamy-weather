const assert = require("node:assert/strict")
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
assert.equal(scene("lightssleetshowersandthunder_day").available, true)
assert.ok(scene("lightssleetshowersandthunder_night").rain > 0)
assert.ok(scene("lightssleetshowersandthunder_night").snow > 0)
assert.ok(scene("lightssnowshowersandthunder_day").snow > 0)
assert.ok(scene("lightssnowshowersandthunder_day").thunder > 0)
assert.ok(scene("fog").haze > scene("clearsky_day").haze)
assert.equal(Scene.conditions(null, noon, location).available, false)
assert.equal(scene("unrecognized").available, false)
assert.equal(Scene.conditions({ symbol: "rain", precipitation: 30 }, noon, location).rain, 0.5,
  "Do not treat a multi-hour precipitation sum as an hourly rate")
assert.equal(Scene.conditions({ symbol: "rain", windSpeed: Infinity, cloudCover: NaN }, noon, location).wind, 2 / 30)
assert.equal(Scene.conditions({ symbol: "rain", precipitationOneHour: 100 }, noon, location).rain, 1)
assert.equal(Scene.conditions({ symbol: "clearsky_day", cloudCover: 100 }, noon, location).cover, 0.08)
assert.ok(Scene.solarPosition(noon, location.latitude, location.longitude).elevation > 0)
assert.ok(Scene.solarPosition(new Date("2026-09-24T22:00:00Z"), location.latitude, location.longitude).elevation < 0)
assert.ok(Scene.solarPosition(new Date("2026-06-21T22:00:00Z"), 78, 15).elevation > 0, "Polar summer remains daylight")
assert.ok(Scene.solarPosition(new Date("2026-12-21T10:00:00Z"), 78, 15).elevation < 0, "Polar winter remains dark")
assert.ok(Scene.conditions({ symbol: "clearsky_night" }, noon, null).sunElevation < 0)
assert.ok(Scene.conditions({ symbol: "fair_polartwilight" }, noon, { latitude: null, longitude: null }).sunElevation < 0)
// Drift: calm air and fog still move (the old pace left calm fog static);
// strong wind keeps its old pace, and the pace never falls with the wind.
const calm = Scene.drift(0), gale = Scene.drift(1)
assert.ok(calm.offset >= 0.03 && calm.evolution >= 0.12, "calm weather drifts")
assert.ok(Math.abs(gale.offset - 0.226) < 1e-9 && Math.abs(gale.evolution - 0.16) < 1e-9, "strong wind keeps its pace")
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

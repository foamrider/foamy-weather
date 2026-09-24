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
console.log("Weather scene tests passed (all MET precipitation variants, missing data, solar and polar conditions).")

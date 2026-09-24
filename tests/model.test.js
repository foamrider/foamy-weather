process.env.TZ = "Europe/Oslo"
const assert = require("node:assert/strict")
const Model = require("../Model.js")

function entry(time, temperature, symbol, precipitation = 0, uvIndex = 0) {
  return {
    time,
    data: {
      instant: {
        details: {
          air_pressure_at_sea_level: 1004.2,
          air_temperature: temperature,
          cloud_area_fraction: 72.4,
          relative_humidity: 81.2,
          ultraviolet_index_clear_sky: uvIndex,
          wind_from_direction: 224,
          wind_speed: 2.5
        }
      },
      next_1_hours: {
        summary: { symbol_code: symbol },
        details: { precipitation_amount: precipitation }
      }
    }
  }
}

const bundle = {
  fetchedAt: "2026-08-21T08:00:00+02:00",
  stale: false,
  forecast: {
    type: "Feature",
    properties: {
      timeseries: [
        entry("2026-08-21T06:00:00Z", 11.4, "cloudy", 0, 2.4),
        entry("2026-08-21T10:00:00Z", 15.7, "partlycloudy_day", 0.2),
        entry("2026-08-21T16:00:00Z", 13.1, "lightrain", 0.8),
        entry("2026-08-21T22:00:00Z", 9.2, "clearsky_night"),
        entry("2026-08-22T04:00:00Z", 8.1, "clearsky_day"),
        entry("2026-08-22T10:00:00Z", 18.6, "fair_day"),
        entry("2026-08-22T16:00:00Z", 16.2, "partlycloudy_day"),
        entry("2026-08-22T22:00:00Z", 10.3, "cloudy"),
        entry("2026-08-23T04:00:00Z", 10.8, "cloudy"),
        entry("2026-08-23T10:00:00Z", 17.4, "rain", 1.4),
        entry("2026-08-23T16:00:00Z", 14.1, "rainshowers_day", 0.6)
      ]
    }
  },
  sun: [
    { date: "2026-08-21", sunrise: "2026-08-21T05:50:00+02:00", sunset: "2026-08-21T20:46:00+02:00" },
    { date: "2026-08-22", sunrise: "2026-08-22T05:52:00+02:00", sunset: "2026-08-22T20:43:00+02:00" },
    { date: "2026-08-23", sunrise: "2026-08-23T05:55:00+02:00", sunset: "2026-08-23T20:40:00+02:00" }
  ]
}

assert.deepEqual(Model.parseLocationFile('{"name":"Example","latitude":12.34,"longitude":56.78}'), {
  name: "Example",
  latitude: 12.34,
  longitude: 56.78
})
assert.deepEqual(Model.parseLocationFile('{"label":"Example","lat":"12.34","lon":"56.78"}'), {
  name: "Example",
  latitude: 12.34,
  longitude: 56.78
})
assert.deepEqual(Model.parseLocationFile("broken"), { name: "", latitude: null, longitude: null })
assert.deepEqual(Model.parseResolvedLocation('{"name":"Example Town","latitude":12.3456,"longitude":56.7890,"source":"geoclue"}'), {
  name: "Example Town",
  latitude: 12.3456,
  longitude: 56.7890,
  source: "geoclue",
  error: ""
})
assert.deepEqual(Model.parseResolvedLocation('{"error":"Kunne ikke finne automatisk posisjon"}'), {
  name: "",
  latitude: null,
  longitude: null,
  source: "",
  error: "Kunne ikke finne automatisk posisjon"
})

const parsed = Model.parseBundle(JSON.stringify(bundle))
assert.ok(parsed)
assert.equal(Model.parseBundle('{"forecast":{}}'), null)

const current = Model.currentCondition(parsed)
assert.equal(current.temperature, 11.4)
assert.equal(current.uvIndex, 2.4)
assert.equal(Model.temperature(current.temperature), "11°")
assert.equal(Model.uvIndex(current.uvIndex), "2.4")
assert.equal(Model.uvIndex(null), "—")
assert.equal(Model.iconForSymbol(current.symbol), "󰖐")
assert.equal(Model.descriptionForSymbol("partlycloudy_day"), "Delvis skyet")
assert.equal(Model.windDirection(current.windDirection), "SV")
assert.equal(Model.windSpeedKmh(current.windSpeed), 9)

const days = Model.forecastDays(parsed, new Date("2026-08-21T08:15:00+02:00"))
assert.equal(days.length, 3)
assert.equal(days[0].date, "2026-08-21")
assert.equal(days[0].high, 16)
assert.equal(days[0].low, 11)
assert.equal(days[0].precipitation, 1)
assert.equal(days[0].sunrise, "2026-08-21T05:50:00+02:00")
assert.equal(days[1].symbol, "fair_day")
assert.equal(days[2].precipitation, 2)
assert.ok(days.every(day => day.hours.length > 0))

const rollingEntries = []
const rollingStart = new Date("2026-08-21T21:00:00+02:00")
for (let index = 0; index < 17; index++) {
  const time = new Date(rollingStart.getTime() + index * 3 * 60 * 60 * 1000)
  rollingEntries.push(entry(time.toISOString(), 12 + index / 10, "partlycloudy_day"))
}
const rollingDays = Model.forecastDays({
  forecast: { properties: { timeseries: rollingEntries } },
  sun: []
}, new Date("2026-08-21T20:30:00+02:00"))
assert.deepEqual(rollingDays[0].hours.map(point => point.time), [
  "21:00", "00:00", "03:00", "06:00", "09:00", "12:00", "15:00", "18:00"
])
assert.equal(rollingDays[0].hours.length, rollingDays[1].hours.length)
assert.equal(rollingDays[0].hours[7].dateKey, "2026-08-22")

assert.equal(Model.precipitation(0), "0 mm")
assert.equal(Model.precipitation(1.25), "1.3 mm")
assert.equal(Model.formatIsoTime("2026-08-21T05:50:00+02:00"), "05:50")
assert.equal(Model.formatAge("2026-08-21T08:00:00+02:00", new Date("2026-08-21T08:31:00+02:00")), "31 min siden")

console.log("Weather model tests passed.")

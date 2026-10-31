// Mock MET Norway bundle for preview/Preview.qml (no network, fixed clock).
.pragma library

var symbols = ["partlycloudy_day", "partlycloudy_day", "lightrain", "rain", "cloudy", "clearsky_night", "fair_night", "cloudy",
  "fair_day", "clearsky_day", "partlycloudy_day", "cloudy", "lightrainshowers_day", "cloudy", "fair_night", "clearsky_night",
  "cloudy", "rain", "heavyrain", "rainshowers_day", "partlycloudy_day", "cloudy", "fair_night", "cloudy"]

function bundle(start) {
  var series = []
  for (var i = 0; i < 24 * 3; i++) {
    var time = new Date(start.getTime() + i * 3600 * 1000)
    var hour = time.getHours()
    var temperature = 8 + 5 * Math.sin((hour - 9) / 24 * 2 * Math.PI) + (i > 30 ? 2 : 0)
    var symbol = symbols[Math.floor(i / 3) % symbols.length]
    series.push({
      time: time.toISOString(),
      data: {
        instant: { details: { air_temperature: temperature, relative_humidity: 78, ultraviolet_index_clear_sky: 1.4,
          cloud_area_fraction: 62, wind_speed: 4.2, wind_from_direction: 225 } },
        next_1_hours: { summary: { symbol_code: symbol }, details: { precipitation_amount: symbol.indexOf("rain") >= 0 ? 0.6 : 0 } }
      }
    })
  }
  var sun = []
  for (var d = 0; d < 3; d++) {
    var day = new Date(start.getFullYear(), start.getMonth(), start.getDate() + d, 12)
    var key = day.getFullYear() + "-" + String(day.getMonth() + 1).padStart(2, "0") + "-" + String(day.getDate()).padStart(2, "0")
    sun.push({ date: key, sunrise: key + "T07:58:00+01:00", sunset: key + "T16:31:00+01:00" })
  }
  return { forecast: { type: "Feature", properties: { timeseries: series } }, sun: sun,
    fetchedAt: new Date(start.getTime() - 4 * 60000).toISOString(), stale: false }
}

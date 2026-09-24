// Solar calculation adapted from Atmosphere sun.ts; see LICENSE-ATMOSPHERE.
function solarPosition(now, latitude, longitude) {
  var rad = Math.PI / 180
  var d = now.getTime() / 86400000 - 0.5 + 2440588 - 2451545
  var m = rad * (357.5291 + 0.98560028 * d)
  var c = rad * (1.9148 * Math.sin(m) + 0.02 * Math.sin(2 * m) + 0.0003 * Math.sin(3 * m))
  var l = m + c + rad * 102.9372 + Math.PI
  var obliquity = 23.4397 * rad
  var dec = Math.asin(Math.sin(obliquity) * Math.sin(l))
  var ra = Math.atan2(Math.sin(l) * Math.cos(obliquity), Math.cos(l))
  var phi = rad * latitude
  var h = rad * (280.16 + 360.9856235 * d + longitude) - ra
  return {
    elevation: Math.asin(Math.sin(phi) * Math.sin(dec) + Math.cos(phi) * Math.cos(dec) * Math.cos(h)),
    azimuth: Math.atan2(Math.sin(h), Math.cos(h) * Math.sin(phi) - Math.tan(dec) * Math.cos(phi)) + Math.PI
  }
}

function bounded(value, fallback, minimum, maximum) {
  return typeof value === "number" && isFinite(value)
    ? Math.max(minimum, Math.min(maximum, value)) : fallback
}

function conditions(current, now, location) {
  var symbol = current ? String(current.symbol || "") : ""
  var code = symbol.replace(/_(day|night|polartwilight)$/, "")
  // MET retains these two misspellings in its public Locationforecast contract.
  code = code.replace(/^lights(sleet|snow)showersandthunder$/, "light$1showersandthunder")
  var known = /^(clearsky|fair|partlycloudy|cloudy|fog)$/.test(code)
    || /^(light|heavy)?(rain|sleet|snow)(showers)?(andthunder)?$/.test(code)
  var rain = code.indexOf("rain") !== -1
  var snow = code.indexOf("snow") !== -1
  var sleet = code.indexOf("sleet") !== -1
  var thunder = code.indexOf("thunder") !== -1
  var wet = rain || snow || sleet
  var cover = code === "clearsky" ? 0 : code === "fair" ? 0.22
    : code === "partlycloudy" ? 0.5 : 0.92
  cover = bounded(current && current.cloudCover, cover * 100, 0, 100) / 100
  // Keep the visual consistent with the displayed forecast symbol at period boundaries.
  if (code === "clearsky") cover = Math.min(cover, 0.08)
  if (wet || code === "cloudy" || code === "fog") cover = Math.max(cover, 0.75)
  var intensity = code.indexOf("heavy") === 0 ? 0.85 : code.indexOf("light") === 0 ? 0.2 : 0.5
  var amount = bounded(current && current.precipitationOneHour, -1, 0, 100)
  if (wet && amount > 0) intensity = Math.max(0.12, Math.min(1, Math.sqrt(amount / 10)))
  var sun = { elevation: /_night$/.test(symbol) ? -0.5 : /_polartwilight$/.test(symbol) ? -0.06 : 0.6, azimuth: Math.PI }
  if (now instanceof Date && isFinite(now.getTime()) && location
      && typeof location.latitude === "number" && isFinite(location.latitude) && Math.abs(location.latitude) <= 90
      && typeof location.longitude === "number" && isFinite(location.longitude) && Math.abs(location.longitude) <= 180) {
    sun = solarPosition(now, location.latitude, location.longitude)
  }
  return {
    available: !!current && known,
    cover: cover,
    rain: rain ? intensity : sleet ? intensity * 0.55 : 0,
    snow: snow ? intensity : sleet ? intensity * 0.45 : 0,
    thunder: thunder ? 0.25 : 0,
    wind: bounded(current && current.windSpeed, 2, 0, 30) / 30,
    haze: code === "fog" ? 0.92 : wet ? 0.3 : 0.06,
    high: [cover * 0.12, 0, 0],
    mid: [wet ? cover * 0.2 : 0, 0, wet ? cover * 0.72 : 0],
    low: [code === "fog" ? 0.8 : 0, wet ? 0 : cover * 0.65, wet ? 0 : cover * 0.55, thunder ? 0.55 : 0],
    sunElevation: sun.elevation,
    sunAzimuth: sun.azimuth
  }
}

if (typeof module !== "undefined") module.exports = { conditions: conditions, solarPosition: solarPosition }

// The bundled helper, bin/<arch>/foamy-weather-helper (kit/FoamyNative.js).
var HELPER = "foamy-weather-helper"
// The helper's error key on a CPU without the instructions its HTTPS needs
// (foamy-helper's tls::UNSUPPORTED).
var HTTPS_UNSUPPORTED = "HTTPS isn't supported on this CPU (foamy helpers need AES, carry-less multiply, AVX2, BMI2 and ADX on x86-64, or the crypto extensions on ARMv8)"

function trimmed(value) {
  return String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "")
}

function parseLocationFile(raw) {
  var unset = { name: "", latitude: null, longitude: null }
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || typeof data !== "object") return unset

    var latitude = parseFloat(data.latitude !== undefined ? data.latitude : data.lat)
    var longitude = parseFloat(data.longitude !== undefined ? data.longitude : data.lon)
    var hasCoordinates = !isNaN(latitude) && !isNaN(longitude)
      && latitude >= -90 && latitude <= 90
      && longitude >= -180 && longitude <= 180
    return {
      name: typeof data.name === "string" ? trimmed(data.name)
        : (typeof data.label === "string" ? trimmed(data.label) : ""),
      latitude: hasCoordinates ? latitude : null,
      longitude: hasCoordinates ? longitude : null
    }
  } catch (e) {
    return unset
  }
}

function parseResolvedLocation(raw) {
  var unset = { name: "", latitude: null, longitude: null, source: "", error: "", errorValues: [] }
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || typeof data !== "object") return unset

    var location = parseLocationFile(JSON.stringify(data))
    return {
      name: location.name,
      latitude: location.latitude,
      longitude: location.longitude,
      source: typeof data.source === "string" ? trimmed(data.source) : "",
      error: typeof data.error === "string" ? trimmed(data.error) : "",
      // %n values for the error key (a missing program's name, …).
      errorValues: Array.isArray(data.values) ? data.values.map(String) : []
    }
  } catch (e) {
    return unset
  }
}

// The search asks Open-Meteo for five places (count=5). Its reply is
// untrusted: keep at most that many, each with a string name and the numeric
// in-range coordinates `location --set` accepts, so every listed place can be
// saved.
var SEARCH_RESULTS = 5

function inRange(value, bound) {
  return typeof value === "number" && isFinite(value) && value >= -bound && value <= bound
}

function parseGeocodingResults(raw) {
  try {
    var data = JSON.parse(String(raw || "{}"))
    var results = data && Array.isArray(data.results) ? data.results : []

    var out = []
    for (var i = 0; i < results.length && out.length < SEARCH_RESULTS; i++) {
      var result = results[i]
      if (!result || typeof result !== "object" || typeof result.name !== "string" || !result.name
        || !inRange(result.latitude, 90) || !inRange(result.longitude, 180)) continue
      var region = [result.admin1, result.country].filter(function(part) {
        return typeof part === "string" && part !== ""
      }).join(", ")
      out.push({
        name: result.name,
        description: region,
        latitude: result.latitude,
        longitude: result.longitude
      })
    }
    return out
  } catch (e) {
    return []
  }
}

function locationCommit(text, suggestions, selectedIndex) {
  var name = trimmed(text)
  if (name === "") return { name: "", latitude: null, longitude: null }

  var choices = suggestions || []
  var index = Math.max(0, Math.min(parseInt(selectedIndex, 10) || 0, choices.length - 1))
  return choices[index] || { name: name, latitude: null, longitude: null }
}

function parseBundle(raw) {
  try {
    var bundle = JSON.parse(String(raw || ""))
    if (!bundle || typeof bundle !== "object") return null
    var forecast = bundle.forecast
    var timeseries = forecast && forecast.properties ? forecast.properties.timeseries : null
    if (!timeseries || !timeseries.length) return null
    bundle.sun = bundle.sun || []
    bundle.stale = bundle.stale === true
    return bundle
  } catch (e) {
    return null
  }
}

function round(value, digits) {
  var number = parseFloat(value)
  if (isNaN(number)) return null
  var scale = Math.pow(10, digits || 0)
  return Math.round(number * scale) / scale
}

// `number` is FoamyI18n.number (digits for the display language).
function uvIndex(value, number) {
  var rounded = round(value, 1)
  if (rounded === null) return "—"
  var decimals = rounded % 1 === 0 ? 0 : 1
  return typeof number === "function" ? number(rounded, decimals) : rounded.toFixed(decimals)
}

function localDateKey(date) {
  if (!(date instanceof Date) || isNaN(date.getTime())) return ""
  var year = date.getFullYear()
  var month = String(date.getMonth() + 1).padStart(2, "0")
  var day = String(date.getDate()).padStart(2, "0")
  return year + "-" + month + "-" + day
}

function dateFromKey(key) {
  var parts = String(key || "").split("-")
  if (parts.length !== 3) return new Date(NaN)
  return new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]), 12, 0, 0)
}

function periodFor(data) {
  if (!data) return null
  return data.next_1_hours || data.next_6_hours || data.next_12_hours || null
}

function pointFromEntry(entry) {
  if (!entry || !entry.data || !entry.data.instant) return null
  var date = new Date(entry.time)
  if (isNaN(date.getTime())) return null

  var details = entry.data.instant.details || {}
  var oneHour = entry.data.next_1_hours || null
  var period = periodFor(entry.data)
  var summary = period && period.summary ? period.summary : {}
  var periodDetails = period && period.details ? period.details : {}
  var oneHourDetails = oneHour && oneHour.details ? oneHour.details : {}

  return {
    date: date,
    dateKey: localDateKey(date),
    hour: date.getHours(),
    time: String(date.getHours()).padStart(2, "0") + ":00",
    temperature: round(details.air_temperature, 1),
    humidity: round(details.relative_humidity, 0),
    uvIndex: round(details.ultraviolet_index_clear_sky, 1),
    cloudCover: round(details.cloud_area_fraction, 0),
    windSpeed: round(details.wind_speed, 1),
    windDirection: round(details.wind_from_direction, 0),
    symbol: String(summary.symbol_code || "cloudy"),
    precipitation: round(periodDetails.precipitation_amount, 1),
    precipitationOneHour: oneHour ? round(oneHourDetails.precipitation_amount, 1) : null
  }
}

function forecastPoints(bundle) {
  var timeseries = bundle && bundle.forecast && bundle.forecast.properties
    ? bundle.forecast.properties.timeseries : []
  var points = []
  for (var i = 0; i < timeseries.length; i++) {
    var point = pointFromEntry(timeseries[i])
    if (point) points.push(point)
  }
  return points
}

function currentCondition(bundle) {
  var points = forecastPoints(bundle)
  return points.length ? points[0] : null
}

function sunForDate(bundle, dateKey) {
  var rows = bundle && bundle.sun ? bundle.sun : []
  for (var i = 0; i < rows.length; i++) {
    if (rows[i] && rows[i].date === dateKey) return rows[i]
  }
  return { date: dateKey, sunrise: "", sunset: "" }
}

function nearestNoon(points) {
  if (!points || !points.length) return null
  var best = points[0]
  var bestDistance = Math.abs(best.hour - 12)
  for (var i = 1; i < points.length; i++) {
    var distance = Math.abs(points[i].hour - 12)
    if (distance < bestDistance) {
      best = points[i]
      bestDistance = distance
    }
  }
  return best
}

function dailyPrecipitation(points) {
  var total = 0
  var found = false
  for (var i = 0; i < points.length; i++) {
    var amount = points[i].precipitationOneHour
    if (amount === null || amount === undefined) continue
    total += amount
    found = true
  }
  return found ? round(total, 1) : null
}

function hourlyPoints(points, now, isToday) {
  var rows = []
  var currentTime = now instanceof Date ? now.getTime() : Date.now()
  for (var i = 0; i < points.length; i++) {
    var point = points[i]
    if (isToday && point.date.getTime() + 60 * 60 * 1000 < currentTime) continue
    if (point.hour % 3 !== 0 && rows.length > 0) continue
    rows.push(point)
    if (rows.length >= 8) break
  }
  return rows
}

function forecastDays(bundle, now) {
  var points = forecastPoints(bundle)
  if (!points.length) return []

  var currentDate = now instanceof Date && !isNaN(now.getTime()) ? now : new Date()
  var todayKey = localDateKey(currentDate)
  var groups = {}
  var keys = []

  for (var i = 0; i < points.length; i++) {
    var key = points[i].dateKey
    if (key < todayKey) continue
    if (!groups[key]) {
      if (keys.length >= 3) continue
      groups[key] = []
      keys.push(key)
    }
    groups[key].push(points[i])
  }

  var result = []
  for (var dayIndex = 0; dayIndex < keys.length; dayIndex++) {
    var dateKey = keys[dayIndex]
    var dayPoints = groups[dateKey]
    var high = null
    var low = null
    for (var pointIndex = 0; pointIndex < dayPoints.length; pointIndex++) {
      var value = dayPoints[pointIndex].temperature
      if (value === null) continue
      high = high === null ? value : Math.max(high, value)
      low = low === null ? value : Math.min(low, value)
    }
    var representative = nearestNoon(dayPoints) || dayPoints[0]
    var sun = sunForDate(bundle, dateKey)
    result.push({
      date: dateKey,
      dateObject: dateFromKey(dateKey),
      high: round(high, 0),
      low: round(low, 0),
      symbol: representative ? representative.symbol : "cloudy",
      precipitation: dailyPrecipitation(dayPoints),
      sunrise: sun.sunrise || "",
      sunset: sun.sunset || "",
      // Today is a rolling forecast, so keep filling its eight slots across midnight.
      hours: hourlyPoints(dateKey === todayKey ? points : dayPoints, currentDate, dateKey === todayKey)
    })
  }
  return result
}

function normalizedSymbol(symbol) {
  return String(symbol || "cloudy")
    .replace(/_(day|night|polartwilight)$/, "")
    .replace(/^lightss/, "lights")
}

function descriptionForSymbol(symbol) {
  var code = normalizedSymbol(symbol)
  var descriptions = {
    clearsky: "Clear",
    fair: "Mostly clear",
    partlycloudy: "Partly cloudy",
    cloudy: "Cloudy",
    fog: "Fog",
    lightrain: "Light rain",
    lightrainshowers: "Light rain showers",
    rain: "Rain",
    rainshowers: "Rain showers",
    heavyrain: "Heavy rain",
    heavyrainshowers: "Heavy rain showers",
    lightrainandthunder: "Light thunderstorms",
    lightrainshowersandthunder: "Light thunderstorms",
    rainandthunder: "Thunderstorms",
    rainshowersandthunder: "Thunderstorms",
    heavyrainandthunder: "Heavy thunderstorms",
    heavyrainshowersandthunder: "Heavy thunderstorms",
    lightsleet: "Light sleet",
    lightsleetshowers: "Light sleet",
    sleet: "Sleet",
    sleetshowers: "Sleet",
    heavysleet: "Heavy sleet",
    heavysleetshowers: "Heavy sleet",
    lightsleetandthunder: "Light sleet and thunder",
    lightsleetshowersandthunder: "Light sleet and thunder",
    sleetandthunder: "Sleet and thunder",
    sleetshowersandthunder: "Sleet and thunder",
    heavysleetandthunder: "Heavy sleet and thunder",
    heavysleetshowersandthunder: "Heavy sleet and thunder",
    lightsnow: "Light snow",
    lightsnowshowers: "Light snow",
    snow: "Snow",
    snowshowers: "Snow",
    heavysnow: "Heavy snow",
    heavysnowshowers: "Heavy snow",
    lightsnowandthunder: "Light snow and thunder",
    lightsnowshowersandthunder: "Light snow and thunder",
    snowandthunder: "Snow and thunder",
    snowshowersandthunder: "Snow and thunder",
    heavysnowandthunder: "Heavy snow and thunder",
    heavysnowshowersandthunder: "Heavy snow and thunder"
  }
  return descriptions[code] || code
}

function iconForSymbol(symbol) {
  var raw = String(symbol || "cloudy")
  var code = normalizedSymbol(raw)
  var night = raw.endsWith("_night")
  if (code === "clearsky" || code === "fair") return night ? "\u{f0594}" : "\u{f0599}"
  if (code === "partlycloudy") return night ? "\u{f0f31}" : "\u{f0595}"
  if (code === "cloudy") return "\u{f0590}"
  if (code === "fog") return "\u{f0591}"
  if (code.indexOf("thunder") !== -1) return code.indexOf("snow") !== -1 ? "\u{f067f}" : "\u{f067e}"
  if (code.indexOf("snow") !== -1) return "\u{f0598}"
  if (code.indexOf("sleet") !== -1) return "\u{f0592}"
  if (code.indexOf("heavyrain") !== -1) return "\u{f0596}"
  if (code.indexOf("rain") !== -1) return "\u{f0597}"
  return "\u{f0590}"
}

function windDirection(degrees) {
  var value = parseFloat(degrees)
  if (isNaN(value)) return ""
  var directions = ["N", "NØ", "Ø", "SØ", "S", "SV", "V", "NV"]
  return directions[Math.round(((value % 360) + 360) % 360 / 45) % 8]
}

function formatIsoTime(value) {
  var date = new Date(value)
  if (isNaN(date.getTime())) return ""
  return String(date.getHours()).padStart(2, "0") + ":" + String(date.getMinutes()).padStart(2, "0")
}

// --- the service entry (Service.qml) -----------------------------------------------

// The plugin's own settings in shell.json for the service entry: the
// `plugins[]` entry, else the bar layout entry (the same keys either way).
// { valid: false } when the file can't be read as a shell config, so the
// service keeps what it had; { valid: true, found: false, settings: {} }
// when there is no entry.
function pluginEntry(raw, id) {
  var config
  try {
    config = JSON.parse(String(raw || ""))
  } catch (e) {
    return { valid: false, found: false, settings: {} }
  }
  if (!config || typeof config !== "object" || Array.isArray(config))
    return { valid: false, found: false, settings: {} }
  var wanted = String(id || "")
  var matches = function(entry) {
    return !!entry && typeof entry === "object" && !Array.isArray(entry) && entry.id === wanted
  }
  var copy = function(entry) {
    var settings = {}
    for (var key in entry) if (key !== "id") settings[key] = entry[key]
    return { valid: true, found: true, settings: settings }
  }
  var plugins = Array.isArray(config.plugins) ? config.plugins : []
  for (var i = 0; i < plugins.length; i++) if (matches(plugins[i])) return copy(plugins[i])
  var layout = config.bar && typeof config.bar === "object" ? config.bar.layout : null
  if (layout && typeof layout === "object") {
    for (var section in layout) {
      var entries = Array.isArray(layout[section]) ? layout[section] : []
      for (var j = 0; j < entries.length; j++) if (matches(entries[j])) return copy(entries[j])
    }
  }
  return { valid: true, found: false, settings: {} }
}

// Longest strings in a current() reply, in code points.
var REPLY_LIMITS = { code: 48, condition: 64, location: 80 }

// One line of plain text, at most `limit` code points: control and line
// separator characters become spaces, runs of spaces collapse.
function plainText(value, limit) {
  var text = String(value === undefined || value === null ? "" : value)
    .replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, " ")
    .replace(/\s+/g, " ")
  text = trimmed(text)
  var points = Array.from(text)
  return points.length > limit ? trimmed(points.slice(0, limit).join("")) : text
}

function wholeOrNull(value) {
  return typeof value === "number" && isFinite(value) ? Math.round(value) : null
}

// The `current()` IPC reply, compact JSON-ready. `state`:
//   report, reportCurrent      WeatherService's last report and whether it is
//                              for the configured place
//   units                      "metric" | "imperial"
//   convert(celsius, units)    Preferences.converted (rounds)
//   translate(key)             FoamyI18n.t
//   now                        Date, for today's range
//   pending                    the service is starting, loading or retrying
//   unsupported                no helper or no HTTPS for this CPU
//   hasCoordinates, networkConnected
// Answers { ok: true, temperature, unit, code, condition, high, low,
// location, updatedAt } or { ok: false, reason } with reason "pending",
// "no-location", "offline", "unsupported" or "error".
function currentReply(state) {
  state = state || {}
  var report = state.report
  var point = report && state.reportCurrent ? currentCondition(report) : null
  if (point && point.temperature !== null) {
    var units = state.units === "imperial" ? "imperial" : "metric"
    var convert = typeof state.convert === "function" ? state.convert : function(value) { return Math.round(value) }
    var translate = typeof state.translate === "function" ? state.translate : function(key) { return key }
    var days = forecastDays(report, state.now instanceof Date ? state.now : new Date())
    var today = days.length ? days[0] : null
    var code = String(point.symbol || "")
    if (!/^[a-z0-9_]+$/.test(code) || code.length > REPLY_LIMITS.code) code = "cloudy"
    var fetched = new Date(report.fetchedAt)
    return {
      ok: true,
      temperature: wholeOrNull(convert(point.temperature, units)),
      unit: units === "imperial" ? "F" : "C",
      code: code,
      condition: plainText(translate(descriptionForSymbol(code)), REPLY_LIMITS.condition),
      high: today && today.high !== null ? wholeOrNull(convert(today.high, units)) : null,
      low: today && today.low !== null ? wholeOrNull(convert(today.low, units)) : null,
      location: plainText(report.locationName, REPLY_LIMITS.location),
      updatedAt: isNaN(fetched.getTime()) ? "" : fetched.toISOString()
    }
  }
  var reason = "error"
  if (state.unsupported) reason = "unsupported"
  else if (state.pending) reason = "pending"
  else if (!state.hasCoordinates) reason = "no-location"
  else if (!state.networkConnected) reason = "offline"
  return { ok: false, reason: reason }
}

if (typeof module !== "undefined") {
  module.exports = {
    HELPER: HELPER,
    HTTPS_UNSUPPORTED: HTTPS_UNSUPPORTED,
    parseLocationFile: parseLocationFile,
    parseResolvedLocation: parseResolvedLocation,
    parseGeocodingResults: parseGeocodingResults,
    locationCommit: locationCommit,
    parseBundle: parseBundle,
    uvIndex: uvIndex,
    localDateKey: localDateKey,
    forecastPoints: forecastPoints,
    currentCondition: currentCondition,
    forecastDays: forecastDays,
    descriptionForSymbol: descriptionForSymbol,
    iconForSymbol: iconForSymbol,
    windDirection: windDirection,
    formatIsoTime: formatIsoTime,
    pluginEntry: pluginEntry,
    REPLY_LIMITS: REPLY_LIMITS,
    plainText: plainText,
    currentReply: currentReply
  }
}

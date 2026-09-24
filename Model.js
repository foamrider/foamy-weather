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
  var unset = { name: "", latitude: null, longitude: null, source: "", error: "" }
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || typeof data !== "object") return unset

    var location = parseLocationFile(JSON.stringify(data))
    return {
      name: location.name,
      latitude: location.latitude,
      longitude: location.longitude,
      source: typeof data.source === "string" ? trimmed(data.source) : "",
      error: typeof data.error === "string" ? trimmed(data.error) : ""
    }
  } catch (e) {
    return unset
  }
}

function parseGeocodingResults(raw) {
  try {
    var data = JSON.parse(String(raw || "{}"))
    var results = data.results
    if (!results || !results.length) return []

    var out = []
    for (var i = 0; i < results.length; i++) {
      var result = results[i]
      if (!result || !result.name || result.latitude === undefined || result.longitude === undefined) continue
      var region = [result.admin1, result.country].filter(function(part) { return !!part }).join(", ")
      out.push({
        name: String(result.name),
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

function roundedText(value, digits) {
  var number = round(value, digits)
  return number === null ? "—" : String(number)
}

function temperature(value) {
  var number = round(value, 0)
  return number === null ? "—" : number + "°"
}

function precipitation(value) {
  var number = round(value, 1)
  if (number === null) return "—"
  return number.toFixed(number % 1 === 0 ? 0 : 1) + " mm"
}

function uvIndex(value) {
  var number = round(value, 1)
  if (number === null) return "—"
  return number.toFixed(number % 1 === 0 ? 0 : 1)
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
    clearsky: "Klart",
    fair: "Lettskyet",
    partlycloudy: "Delvis skyet",
    cloudy: "Skyet",
    fog: "Tåke",
    lightrain: "Lett regn",
    lightrainshowers: "Lette regnbyger",
    rain: "Regn",
    rainshowers: "Regnbyger",
    heavyrain: "Kraftig regn",
    heavyrainshowers: "Kraftige regnbyger",
    lightrainandthunder: "Lett tordenvær",
    lightrainshowersandthunder: "Lett tordenvær",
    rainandthunder: "Tordenvær",
    rainshowersandthunder: "Tordenvær",
    heavyrainandthunder: "Kraftig tordenvær",
    heavyrainshowersandthunder: "Kraftig tordenvær",
    lightsleet: "Lett sludd",
    lightsleetshowers: "Lett sludd",
    sleet: "Sludd",
    sleetshowers: "Sludd",
    heavysleet: "Kraftig sludd",
    heavysleetshowers: "Kraftig sludd",
    lightsleetandthunder: "Lett sludd og torden",
    lightsleetshowersandthunder: "Lett sludd og torden",
    sleetandthunder: "Sludd og torden",
    sleetshowersandthunder: "Sludd og torden",
    heavysleetandthunder: "Kraftig sludd og torden",
    heavysleetshowersandthunder: "Kraftig sludd og torden",
    lightsnow: "Lett snø",
    lightsnowshowers: "Lett snø",
    snow: "Snø",
    snowshowers: "Snø",
    heavysnow: "Kraftig snø",
    heavysnowshowers: "Kraftig snø",
    lightsnowandthunder: "Lett snø og torden",
    lightsnowshowersandthunder: "Lett snø og torden",
    snowandthunder: "Snø og torden",
    snowshowersandthunder: "Snø og torden",
    heavysnowandthunder: "Kraftig snø og torden",
    heavysnowshowersandthunder: "Kraftig snø og torden"
  }
  return descriptions[code] || code
}

function iconForSymbol(symbol) {
  var raw = String(symbol || "cloudy")
  var code = normalizedSymbol(raw)
  var night = /_night$/.test(raw)
  if (code === "clearsky" || code === "fair") return night ? "󰖔" : "󰖙"
  if (code === "partlycloudy") return night ? "󰼱" : "󰖕"
  if (code === "cloudy") return "󰖐"
  if (code === "fog") return "󰖑"
  if (code.indexOf("thunder") !== -1) return code.indexOf("snow") !== -1 ? "󰙿" : "󰙾"
  if (code.indexOf("snow") !== -1) return "󰖘"
  if (code.indexOf("sleet") !== -1) return "󰖒"
  if (code.indexOf("heavyrain") !== -1) return "󰖖"
  if (code.indexOf("rain") !== -1) return "󰖗"
  return "󰖐"
}

function windDirection(degrees) {
  var value = parseFloat(degrees)
  if (isNaN(value)) return ""
  var directions = ["N", "NØ", "Ø", "SØ", "S", "SV", "V", "NV"]
  return directions[Math.round(((value % 360) + 360) % 360 / 45) % 8]
}

function windSpeedKmh(metresPerSecond) {
  var value = parseFloat(metresPerSecond)
  return isNaN(value) ? null : Math.round(value * 3.6)
}

function formatIsoTime(value) {
  var date = new Date(value)
  if (isNaN(date.getTime())) return ""
  return String(date.getHours()).padStart(2, "0") + ":" + String(date.getMinutes()).padStart(2, "0")
}

function formatAge(value, now) {
  var date = new Date(value)
  if (isNaN(date.getTime())) return ""
  var current = now instanceof Date ? now : new Date()
  var minutes = Math.max(0, Math.round((current.getTime() - date.getTime()) / 60000))
  if (minutes < 2) return "nå"
  if (minutes < 60) return minutes + " min siden"
  var hours = Math.floor(minutes / 60)
  return hours + (hours === 1 ? " time siden" : " timer siden")
}

if (typeof module !== "undefined") {
  module.exports = {
    parseLocationFile: parseLocationFile,
    parseResolvedLocation: parseResolvedLocation,
    parseGeocodingResults: parseGeocodingResults,
    locationCommit: locationCommit,
    parseBundle: parseBundle,
    temperature: temperature,
    precipitation: precipitation,
    uvIndex: uvIndex,
    localDateKey: localDateKey,
    forecastPoints: forecastPoints,
    currentCondition: currentCondition,
    forecastDays: forecastDays,
    descriptionForSymbol: descriptionForSymbol,
    iconForSymbol: iconForSymbol,
    windDirection: windDirection,
    windSpeedKmh: windSpeedKmh,
    formatIsoTime: formatIsoTime,
    formatAge: formatAge
  }
}

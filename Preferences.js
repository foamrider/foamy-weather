// Widget preferences come from shell.json; forecasts remain in MET's original units.
function fromSettings(value) {
  value = value && typeof value === "object" && !Array.isArray(value) ? value : {}
  return {
    units: value.units === "imperial" ? "imperial" : "metric",
    automaticLocation: value.automaticLocation === true,
    animations: value.animations !== false
  }
}

// New editor messages use English keys shared by the bounded clipboard control.

function temperature(value, units) {
  if (value === null || value === undefined || !isFinite(Number(value))) return "—"
  return Math.round(units === "imperial" ? Number(value) * 9 / 5 + 32 : Number(value)) + "°"
}

function precipitation(value, units) {
  if (value === null || value === undefined || !isFinite(Number(value))) return "—"
  var imperial = units === "imperial"
  var number = Number(value) / (imperial ? 25.4 : 1)
  return String(Number(number.toFixed(imperial ? 2 : 1))) + (imperial ? " in" : " mm")
}

function wind(value, units, tr, number) {
  if (value === null || value === undefined || !isFinite(Number(value))) return "—"
  tr = tr || function(label) { return label }
  number = number || String
  return number(Math.round(Number(value) * (units === "imperial" ? 2.236936 : 3.6)))
    + " " + tr(units === "imperial" ? "mph" : "km/h")
}

function age(value, now, tr) {
  var date = new Date(value)
  if (isNaN(date.getTime())) return ""
  tr = tr || function(label, value) { return value === undefined ? label : label.replace("%1", String(value)) }
  var minutes = Math.max(0, Math.round((now.getTime() - date.getTime()) / 60000))
  if (minutes < 2) return tr("now")
  if (minutes < 60) return tr("%1 min ago", minutes)
  var hours = Math.floor(minutes / 60)
  return tr(hours === 1 ? "%1 hour ago" : "%1 hours ago", hours)
}

if (typeof module !== "undefined") module.exports = { fromSettings, temperature, precipitation, wind, age }

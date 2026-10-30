// Widget settings live in the bar entry in shell.json (manifest.json
// barWidget.schema documents them). `fields` is the schema FoamyPrefs saves
// against; forecasts themselves stay in MET's original units.
var fields = [
  { key: "units", type: "enum", options: ["metric", "imperial"], defaultValue: "metric" },
  { key: "automaticLocation", type: "boolean", defaultValue: false },
  { key: "animations", type: "boolean", defaultValue: true },
  { key: "refreshMinutes", type: "integer", min: 5, max: 1440, defaultValue: 30 },
  { key: "locationRefreshMinutes", type: "integer", min: 5, max: 1440, defaultValue: 15 },
  { key: "requestUserAgent", type: "string", maxLength: 200, pattern: "^[ -~]*$", defaultValue: "" }
]

function minutes(value, fallback) {
  var number = parseInt(value, 10)
  if (!isFinite(number)) return fallback
  return Math.max(5, Math.min(1440, number))
}

function fromSettings(value) {
  value = value && typeof value === "object" && !Array.isArray(value) ? value : {}
  var agent = typeof value.requestUserAgent === "string" && /^[ -~]{0,200}$/.test(value.requestUserAgent)
    ? value.requestUserAgent.trim() : ""
  return {
    units: value.units === "imperial" ? "imperial" : "metric",
    automaticLocation: value.automaticLocation === true,
    animations: value.animations !== false,
    refreshMinutes: minutes(value.refreshMinutes, 30),
    locationRefreshMinutes: minutes(value.locationRefreshMinutes, 15),
    requestUserAgent: agent
  }
}

// `number` writes digits for the display language (FoamyI18n.number);
// without it numbers are written as they are.
function formatter(number) {
  return typeof number === "function" ? number : function(value, decimals) {
    return decimals === undefined ? String(value) : Number(value).toFixed(decimals)
  }
}

function converted(value, units) {
  return Math.round(units === "imperial" ? Number(value) * 9 / 5 + 32 : Number(value))
}

function temperature(value, units, number) {
  if (value === null || value === undefined || !isFinite(Number(value))) return "—"
  return formatter(number)(converted(value, units)) + "°"
}

// The bare reading for the hero's number + unit row.
function temperatureValue(value, units, number) {
  if (value === null || value === undefined || !isFinite(Number(value))) return "--"
  return formatter(number)(converted(value, units))
}

function precipitation(value, units, number) {
  if (value === null || value === undefined || !isFinite(Number(value))) return "—"
  var imperial = units === "imperial"
  var amount = Number((Number(value) / (imperial ? 25.4 : 1)).toFixed(imperial ? 2 : 1))
  return formatter(number)(amount) + (imperial ? " in" : " mm")
}

function wind(value, units, tr, number) {
  if (value === null || value === undefined || !isFinite(Number(value))) return "—"
  tr = tr || function(label) { return label }
  return formatter(number)(Math.round(Number(value) * (units === "imperial" ? 2.236936 : 3.6)))
    + " " + tr(units === "imperial" ? "mph" : "km/h")
}

// tr(key) and tn(key, count) are FoamyI18n.t/tn; without them English.
function age(value, now, tr, tn) {
  var date = new Date(value)
  if (isNaN(date.getTime())) return ""
  tr = tr || function(label) { return label }
  tn = tn || function(label, count) {
    return (count === 1 ? label.replace("hours", "hour") : label).replace("%1", String(count))
  }
  var minutes = Math.max(0, Math.round((now.getTime() - date.getTime()) / 60000))
  if (minutes < 2) return tr("now")
  if (minutes < 60) return tn("%1 min ago", minutes)
  return tn("%1 hours ago", Math.floor(minutes / 60))
}

if (typeof module !== "undefined") module.exports = { fields, fromSettings, temperature, temperatureValue, precipitation, wind, age }

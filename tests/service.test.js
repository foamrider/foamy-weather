// The service entry's pure parts (Model.js): reading the plugin's shell.json
// entry, and the `current()` IPC reply.
process.env.TZ = "Europe/Oslo"
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const Model = require("../Model.js")
const P = require("../Preferences.js")
const I = require("./i18n.cjs")

// --- pluginEntry -------------------------------------------------------------------
const config = (extra) => JSON.stringify(Object.assign({ version: 1, plugins: [], bar: { layout: {} } }, extra))
assert.deepEqual(Model.pluginEntry("", "foamy.weather").valid, false, "empty file is not a config")
assert.deepEqual(Model.pluginEntry("{ half", "foamy.weather").valid, false, "half-written file is not a config")
assert.deepEqual(Model.pluginEntry("[]", "foamy.weather").valid, false, "an array is not a config")
assert.deepEqual(Model.pluginEntry(config({}), "foamy.weather"), { valid: true, found: false, settings: {} })
// The plugins[] entry, without its id.
const plugin = { id: "foamy.weather", units: "imperial", automaticLocation: true, requestUserAgent: "me/1" }
assert.deepEqual(Model.pluginEntry(config({ plugins: [{ id: "foamy.lock" }, plugin] }), "foamy.weather"),
  { valid: true, found: true, settings: { units: "imperial", automaticLocation: true, requestUserAgent: "me/1" } })
// The bar entry when there is no plugins[] entry (a widget in any section).
const bar = { id: "foamy.weather", language: "nb", units: "metric", animations: false }
const barOnly = config({ bar: { layout: { left: [{ id: "omarchy.workspaces" }], centerBegin: [bar] } } })
assert.deepEqual(Model.pluginEntry(barOnly, "foamy.weather").settings, { language: "nb", units: "metric", animations: false })
// plugins[] wins over the bar entry.
const both = config({ plugins: [plugin], bar: { layout: { right: [bar] } } })
assert.equal(Model.pluginEntry(both, "foamy.weather").settings.units, "imperial")
// Malformed sections and entries are skipped, other ids never match.
assert.equal(Model.pluginEntry(config({ plugins: [null, "foamy.weather", { id: "foamy.weather.x" }],
  bar: { layout: { left: "foamy.weather", right: [null, ["foamy.weather"]] } } }), "foamy.weather").found, false)
// Settings read through the schema as everywhere else: the legacy `language`
// key is ignored (the condition follows Omarchy's language), bad values read
// as defaults.
const Prefs = require("../kit/node-loader.cjs").load("FoamyPrefs")
const read = settings => ({ ...Prefs.values(P.fields, settings) })
assert.deepEqual(read(Model.pluginEntry(barOnly, "foamy.weather").settings),
  { units: "metric", automaticLocation: false, animations: false, refreshMinutes: 30, locationRefreshMinutes: 15, requestUserAgent: "" })

// --- currentReply ------------------------------------------------------------------
function entry(time, temperature, symbol) {
  return { time, data: { instant: { details: { air_temperature: temperature, wind_speed: 2 } },
    next_1_hours: { summary: { symbol_code: symbol }, details: { precipitation_amount: 0 } } } }
}
const report = {
  fetchedAt: "2026-11-08T09:30:00+01:00",
  stale: false,
  locationName: "Bergen",
  forecast: { type: "Feature", properties: { timeseries: [
    entry("2026-11-08T09:00:00Z", 6.4, "lightrain"),
    entry("2026-11-08T13:00:00Z", 9.6, "cloudy"),
    entry("2026-11-08T20:00:00Z", 2.2, "clearsky_night"),
    entry("2026-11-09T12:00:00Z", 11, "fair_day")
  ] } },
  sun: []
}
const now = new Date("2026-11-08T10:00:00+01:00")
const base = { report, reportCurrent: true, units: "metric", convert: P.converted, now,
  translate: key => I.text(key, "en"), pending: false, unsupported: false, hasCoordinates: true, networkConnected: true }
const reply = state => Model.currentReply(Object.assign({}, base, state))

assert.deepEqual(reply({}), { ok: true, temperature: 6, unit: "C", code: "lightrain", condition: "Light rain",
  high: 10, low: 2, location: "Bergen", updatedAt: "2026-11-08T08:30:00.000Z" })
// Units and the translated condition.
const imperial = reply({ units: "imperial", translate: key => I.text(key, "no") })
assert.equal(imperial.unit, "F")
assert.equal(imperial.temperature, P.converted(6.4, "imperial"))
assert.equal(imperial.high, P.converted(10, "imperial"))
assert.equal(imperial.condition, I.text("Light rain", "no"))
assert.notEqual(imperial.condition, "Light rain", "the Norwegian catalog translates the condition")
// Keys and order are the contract.
assert.deepEqual(Object.keys(reply({})), ["ok", "temperature", "unit", "code", "condition", "high", "low", "location", "updatedAt"])
// Data stays ok while a refresh, a retry or a stale cache is underway.
assert.equal(reply({ pending: true, networkConnected: false }).ok, true)
assert.equal(reply({ report: Object.assign({}, report, { stale: true }) }).ok, true)

// Without data for the configured place: the reason, in order of precedence.
assert.deepEqual(reply({ report: null }), { ok: false, reason: "error" })
assert.deepEqual(reply({ reportCurrent: false, pending: true }), { ok: false, reason: "pending" }, "another place's report is not reused")
assert.deepEqual(reply({ report: null, pending: true, hasCoordinates: false }), { ok: false, reason: "pending" })
assert.deepEqual(reply({ report: null, hasCoordinates: false, networkConnected: false }), { ok: false, reason: "no-location" })
assert.deepEqual(reply({ report: null, networkConnected: false }), { ok: false, reason: "offline" })
assert.deepEqual(reply({ report: null, unsupported: true, pending: true }), { ok: false, reason: "unsupported" })
const noTemperature = JSON.parse(JSON.stringify(report))
noTemperature.forecast.properties.timeseries[0].data.instant.details.air_temperature = null
assert.deepEqual(reply({ report: noTemperature }), { ok: false, reason: "error" })
assert.deepEqual(Model.currentReply(undefined), { ok: false, reason: "no-location" })

// Bounded, single-line strings whatever the report holds.
const hostile = JSON.parse(JSON.stringify(report))
hostile.locationName = "Line\none " + "\u{1F326}".repeat(200)
hostile.forecast.properties.timeseries[0].data.next_1_hours.summary.symbol_code = "x".repeat(49)
hostile.fetchedAt = "yesterday"
const bounded = reply({ report: hostile, translate: () => "A\tvery " + "long ".repeat(40) })
assert.equal(bounded.code, "cloudy", "an over-long or odd code reads as cloudy")
assert.equal(reply({ report: Object.assign({}, report, { forecast: { properties: { timeseries: [entry("2026-11-08T09:00:00Z", 5, "Rain\"<b>")] } } }) }).code, "cloudy")
assert.ok(Array.from(bounded.location).length <= Model.REPLY_LIMITS.location, "location bounded")
assert.ok(bounded.location.startsWith("Line one "), "control and separator characters become spaces: " + bounded.location)
assert.doesNotMatch(bounded.location, /[\uD800-\uDBFF]$/, "never ends in half a surrogate pair")
assert.ok(Array.from(bounded.condition).length <= Model.REPLY_LIMITS.condition && !/\t/.test(bounded.condition), "condition bounded")
assert.equal(bounded.updatedAt, "", "an unreadable fetch time is empty")
assert.ok(JSON.stringify(bounded).length < 600, "reply stays small")
assert.equal(Model.plainText(null, 5), "")
assert.equal(Model.plainText("  a \r\n b  ", 10), "a b")

// Every condition the reply can carry has a Norwegian entry (it is translated).
const symbols = fs.readFileSync(path.join(__dirname, "../Model.js"), "utf8")
const table = symbols.slice(symbols.indexOf("var descriptions = {"), symbols.indexOf("}", symbols.indexOf("var descriptions = {")))
const descriptions = [...table.matchAll(/: "([^"]+)"/g)].map(m => m[1])
assert.ok(descriptions.length > 30, "condition table found")
for (const key of descriptions) assert.ok(Object.hasOwn(I.no, key), `missing condition translation: ${key}`)

console.log("Weather service tests passed.")

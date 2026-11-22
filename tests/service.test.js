// The service entry's pure parts (Model.js): reading the plugin's shell.json
// entry, and the `current()` IPC reply.
process.env.TZ = "Europe/Oslo"
const assert = require("node:assert/strict")
const test = require("node:test")
const Model = require("../Model.js")
const P = require("../Preferences.js")
const I = require("./i18n.cjs")

// --- pluginEntry -------------------------------------------------------------------
test("the service entry reads its settings from shell.json", () => {
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
})

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
const copy = value => JSON.parse(JSON.stringify(value))

test("current() replies with the shown report", () => {
  assert.deepEqual(reply({}), { ok: true, temperature: 6, unit: "C", code: "lightrain", condition: "Light rain",
    high: 10, low: 2, location: "Bergen", updatedAt: "2026-11-08T08:30:00.000Z" })
  // The widget's units and the display language. The day's range is
  // rounded once, after converting: 9.6 °C is 49.28 °F and 1.6 °C is
  // 34.88 °F (rounding to 10 and 2 °C first gives 50 and 36).
  const range = copy(report)
  range.forecast.properties.timeseries[2].data.instant.details.air_temperature = 1.6
  assert.deepEqual(reply({ report: range, units: "imperial", translate: key => I.text(key, "no") }),
    { ok: true, temperature: 44, unit: "F", code: "lightrain", condition: "Lett regn",
      high: 49, low: 35, location: "Bergen", updatedAt: "2026-11-08T08:30:00.000Z" })
  // Data stays ok while a refresh, a retry or a stale cache is underway.
  assert.equal(reply({ pending: true, networkConnected: false }).ok, true)
  assert.equal(reply({ report: Object.assign({}, report, { stale: true }) }).ok, true)
})

test("current() without data for the configured place says why", () => {
  // The reason, in order of precedence.
  assert.deepEqual(reply({ report: null }), { ok: false, reason: "error" })
  assert.deepEqual(reply({ reportCurrent: false, pending: true }), { ok: false, reason: "pending" }, "another place's report is not reused")
  assert.deepEqual(reply({ report: null, pending: true, hasCoordinates: false }), { ok: false, reason: "pending" })
  assert.deepEqual(reply({ report: null, hasCoordinates: false, networkConnected: false }), { ok: false, reason: "no-location" })
  assert.deepEqual(reply({ report: null, networkConnected: false }), { ok: false, reason: "offline" })
  assert.deepEqual(reply({ report: null, unsupported: true, pending: true }), { ok: false, reason: "unsupported" })
  const noTemperature = copy(report)
  noTemperature.forecast.properties.timeseries[0].data.instant.details.air_temperature = null
  assert.deepEqual(reply({ report: noTemperature }), { ok: false, reason: "error" })
  assert.deepEqual(Model.currentReply(undefined), { ok: false, reason: "no-location" })
})

test("current() gives bounded, single-line strings whatever the report holds", () => {
  const hostile = copy(report)
  hostile.locationName = "Line\none " + "\u{1F326}".repeat(200)
  hostile.forecast.properties.timeseries[0].data.next_1_hours.summary.symbol_code = "x".repeat(49)
  hostile.fetchedAt = "yesterday"
  const bounded = reply({ report: hostile, translate: () => "A\tvery " + "long ".repeat(40) })
  assert.equal(bounded.code, "cloudy", "an over-long or odd code reads as cloudy")
  assert.equal(reply({ report: Object.assign({}, report, { forecast: { properties: { timeseries: [entry("2026-11-08T09:00:00Z", 5, "Rain\"<b>")] } } }) }).code, "cloudy")
  assert.ok(bounded.location.length <= Model.REPLY_LIMITS.location, "location bounded")
  assert.ok(bounded.location.startsWith("Line one "), "control and separator characters become spaces: " + bounded.location)
  assert.doesNotMatch(bounded.location, /[\uD800-\uDBFF]$/, "never ends in half a surrogate pair")
  assert.ok(bounded.condition.length <= Model.REPLY_LIMITS.condition && !/\t/.test(bounded.condition), "condition bounded")
  assert.equal(bounded.updatedAt, "", "an unreadable fetch time is empty")
  assert.ok(JSON.stringify(bounded).length < 600, "reply stays small")
  // A report without a place name, and one with padding and a line break.
  assert.equal(reply({ report: Object.assign({}, report, { locationName: undefined }) }).location, "")
  assert.equal(reply({ report: Object.assign({}, report, { locationName: "  a \r\n b  " }) }).location, "a b")
})

// What a JavaScript reader such as the Foamy lock screen accepts: at most
// `limit` UTF-16 code units, and no control, line separator or direction
// formatting character; anything else makes it drop the whole reply.
const READER_UNSAFE = /[\u0000-\u001f\u007f-\u009f\u200e\u200f\u2028\u2029\u202a-\u202e\u2066-\u2069\ufeff]/
for (const [label, name, condition] of [
  ["characters outside the BMP", "\u{1D538}".repeat(60), "\u{1F326} ".repeat(40)],
  ["an odd cut through a surrogate pair", "a" + "\u{1D538}".repeat(60), "a" + "\u{1F326}".repeat(40)],
  ["direction marks and isolates", "\u200f\u05EA\u05DC \u05D0\u05D1\u05D9\u05D1\u200e \u2067x\u2069 \u202bq\u202c\ufeff",
    "\u2068Light rain\u2069"]
]) {
  test(`current() strings stay within what JavaScript readers accept: ${label}`, () => {
    const odd = copy(report)
    odd.locationName = name
    const answer = reply({ report: odd, translate: () => condition })
    for (const [field, limit] of [["location", Model.REPLY_LIMITS.location], ["condition", Model.REPLY_LIMITS.condition]]) {
      const text = answer[field]
      assert.ok(text.length > 0 && text.length <= limit, `${field} has ${text.length} UTF-16 units`)
      assert.doesNotMatch(text, READER_UNSAFE, field)
      assert.doesNotMatch(text, /[\uD800-\uDBFF]$/, `${field} ends in half a surrogate pair`)
      assert.ok(Array.from(text).every(c => c.length === 1 || /^[\uD800-\uDBFF][\uDC00-\uDFFF]$/.test(c)), `${field} has a lone surrogate`)
    }
  })
}

// --- wiring --------------------------------------------------------------------------
test("the manifest loads the service and the bar widget", () => {
  const manifest = require("../manifest.json")
  assert.deepEqual(manifest.kinds, ["service", "bar-widget"])
  assert.equal(manifest.entryPoints.service, "Service.qml")
  assert.equal(manifest.entryPoints.barWidget, "BarWidget.qml")
  assert.notEqual(manifest.keepLoaded, true, "the service reloads with the widgets (one WeatherService)")
  // Omarchy restores its stock weather widget through this.
  assert.equal(manifest.omarchy.clonedFrom, "omarchy.weather")
})

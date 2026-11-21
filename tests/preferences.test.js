const I18n = require('./i18n.cjs');
const assert = require("node:assert/strict")
const test = require("node:test")
const P = require("../Preferences.js")
const Prefs = require("../kit/node-loader.cjs").load("FoamyPrefs")
// Reads go through the save schema (Panel and WeatherService), so a stored
// value the settings UI would refuse reads as its default, never clamped.
// (Spread: the kit runs in its own vm context, with its own Object prototype.)
const read = settings => ({...Prefs.values(P.fields, settings)})
const defaults = {units:'metric', automaticLocation:false, animations:true, refreshMinutes:30, locationRefreshMinutes:15, requestUserAgent:''};

test("stored settings read through the schema", () => {
  assert.deepEqual(read({language: 'nb'}), defaults);
  assert.deepEqual(read({language:'en', units:'imperial', automaticLocation:true, animations:false}), {...defaults, units:'imperial', automaticLocation:true, animations:false});
  // Both bounds of both intervals are allowed values.
  for (const key of ["refreshMinutes", "locationRefreshMinutes"])
    for (const value of [5, 1440]) assert.equal(read({[key]: value})[key], value, `${key}: ${value}`);
  for (const [key, value] of [["refreshMinutes", 2], ["refreshMinutes", 1441], ["refreshMinutes", "45"], ["refreshMinutes", 30.5],
                              ["locationRefreshMinutes", 99999], ["locationRefreshMinutes", 4], ["locationRefreshMinutes", "60"], ["units", "kelvin"]])
    assert.deepEqual(read({[key]: value})[key], defaults[key], `${key}: ${JSON.stringify(value)} reads as the default`);
});

test("the User-Agent is one printable line of at most 200 characters", () => {
  assert.equal(read({requestUserAgent: "bad\nagent"}).requestUserAgent, "");
  assert.equal(read({requestUserAgent: "x".repeat(201)}).requestUserAgent, "");
  assert.equal(read({requestUserAgent: "x".repeat(200)}).requestUserAgent, "x".repeat(200));
  // The schema keeps a realistic agent as stored; WeatherService trims it
  // (tests/runtime.py).
  assert.equal(read({requestUserAgent: "  my-app/1.0 (me@example.com)  "}).requestUserAgent, "  my-app/1.0 (me@example.com)  ");
});

test("the manifest documents exactly the settings the schema saves", () => {
  const manifest = require('../manifest.json');
  const schema = manifest.barWidget.schema;
  assert.deepEqual(P.fields.map(f => f.key).sort(), schema.map(f => f.key).sort());
  for (const field of P.fields) {
    const documented = schema.find(f => f.key === field.key);
    for (const property of ["type", "defaultValue", "options", "min", "max"])
      assert.deepEqual(documented[property], field[property], `${field.key}.${property}`);
  }
  assert.deepEqual(manifest.barWidget.defaults, Object.fromEntries(P.fields.map(f => [f.key, f.defaultValue])));
});

test("readings in the chosen units", () => {
  assert.equal(P.temperature(-3.4, "metric", v => "٫" + v), "٫-3°", "numbers go through the language formatter");
  assert.equal(P.temperatureValue(21.6, "metric"), "22");
  const no = (key, values) => I18n.text(key, 'no', values);
  assert.equal(P.temperature(0, "imperial"), "32°")
  assert.equal(P.temperature(-40, "imperial"), "-40°")
  assert.equal(P.temperature(14.2, "metric"), "14°")
  assert.equal(P.precipitation(25.4, "imperial"), "1 in")
  assert.equal(P.precipitation(1.25, "metric"), "1.3 mm")
  assert.equal(P.precipitation(0, "imperial"), "0 in")
  assert.equal(P.wind(10, "imperial"), "22 mph")
  assert.equal(P.wind(10, "metric"), "36 km/h")
  assert.equal(P.wind(10, "metric", no), "36 km/t")
  for (const value of [null, undefined, NaN, Infinity]) {
    assert.equal(P.temperature(value, "imperial"), "—")
    assert.equal(P.precipitation(value, "imperial"), "—")
    assert.equal(P.wind(value, "imperial"), "—")
  }
});

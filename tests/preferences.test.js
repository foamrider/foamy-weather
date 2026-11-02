const I18n = require('./i18n.cjs');
const assert = require("node:assert/strict")
const P = require("../Preferences.js")
const Prefs = require("../kit/node-loader.cjs").load("FoamyPrefs")
// Reads go through the save schema (Panel and WeatherService), so a stored
// value the settings UI would refuse reads as its default, never clamped.
// (Spread: the kit runs in its own vm context, with its own Object prototype.)
const read = settings => ({...Prefs.values(P.fields, settings)})
const defaults = {units:'metric', automaticLocation:false, animations:true, refreshMinutes:30, locationRefreshMinutes:15, requestUserAgent:''};
assert.deepEqual(read({language: 'nb'}), defaults);
assert.deepEqual(read({language:'en', units:'imperial', automaticLocation:true, animations:false}), {...defaults, units:'imperial', automaticLocation:true, animations:false});
assert.equal(read({refreshMinutes: 60}).refreshMinutes, 60);
assert.equal(read({refreshMinutes: 5, locationRefreshMinutes: 1440}).locationRefreshMinutes, 1440);
for (const [key, value] of [["refreshMinutes", 2], ["refreshMinutes", 1441], ["refreshMinutes", "45"], ["refreshMinutes", 30.5],
                            ["locationRefreshMinutes", 99999], ["locationRefreshMinutes", 4], ["locationRefreshMinutes", "60"], ["units", "kelvin"]])
  assert.deepEqual(read({[key]: value})[key], defaults[key], `${key}: ${JSON.stringify(value)} reads as the default`);
assert.equal(read({requestUserAgent: "bad\nagent"}).requestUserAgent, "");
assert.equal(read({requestUserAgent: "x".repeat(201)}).requestUserAgent, "");
// WeatherService trims after the read; a blank agent leaves the scripts' default.
assert.equal(read({requestUserAgent: "  my-app/1.0 (me@example.com)  "}).requestUserAgent.trim(), "my-app/1.0 (me@example.com)");
// The save schema covers every documented setting and matches the manifest.
const manifest = require('../manifest.json');
assert.deepEqual(P.fields.map(f => f.key).sort(), manifest.barWidget.schema.map(f => f.key).sort());
for (const f of P.fields) assert.deepEqual(manifest.barWidget.defaults[f.key], f.defaultValue, f.key);
assert.equal(P.temperature(-3.4, "metric", v => "٫" + v), "٫-3°", "numbers go through the language formatter");
assert.equal(P.temperatureValue(21.6, "metric"), "22");
assert.equal(read({automaticLocation:'true'}).automaticLocation,false);
assert.equal(read(null).units,'metric');
assert.equal(read([]).animations,true);
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
assert.equal(I18n.text("Partly cloudy", "en"), "Partly cloudy")
assert.equal(I18n.text("Partly cloudy", "no"), "Delvis skyet")
assert.equal(P.age("2026-09-24T10:00:00Z", new Date("2026-09-24T10:31:00Z")), "31 min ago")
assert.equal(P.age("2026-09-24T10:00:00Z", new Date("2026-09-24T11:31:00Z")), "1 hour ago")
const Model = require("../Model.js")
for (const weight of ["light", "", "heavy"])
  for (const precipitation of ["rain", "snow", "sleet"])
    for (const showers of ["", "showers"])
      for (const thunder of ["", "andthunder"]) {
        const symbol = weight + precipitation + showers + thunder + "_night"
        const description = Model.descriptionForSymbol(symbol)
        assert.notEqual(description, symbol.replace(/_night$/, ""), symbol)
        assert.ok(Object.hasOwn(I18n.en, description), symbol)
      }
assert.equal(Model.descriptionForSymbol("lightssleetshowersandthunder_day"), "Light sleet and thunder")
for (const [english, norwegian] of [
  ["Paste", "Lim inn"],
  ["Clipboard paste timed out. Copy the text again.", "Innlimingen tok for lang tid. Kopier teksten på nytt."],
  ["Clipboard text is too large or contains invalid characters.", "Teksten er for stor eller inneholder ugyldige tegn."],
  ["Could not paste clipboard text. Copy plain text and try again.", "Kunne ikke lime inn teksten. Kopier ren tekst og prøv igjen."]
]) {
  assert.equal(I18n.text(english, "no"), norwegian)
  assert.equal(I18n.text(english, "en"), english)
}
console.log("Weather preferences, translations and unit conversion tests passed.")

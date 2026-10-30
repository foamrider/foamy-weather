const I18n = require('./i18n.cjs');
const assert = require("node:assert/strict")
const P = require("../Preferences.js")
const defaults = {units:'metric', automaticLocation:false, animations:true, refreshMinutes:30, locationRefreshMinutes:15, requestUserAgent:''};
assert.deepEqual(P.fromSettings({language: 'nb'}), defaults);
assert.deepEqual(P.fromSettings({language:'en', units:'imperial', automaticLocation:true, animations:false}), {...defaults, units:'imperial', automaticLocation:true, animations:false});
assert.equal(P.fromSettings({refreshMinutes: 1}).refreshMinutes, 5);
assert.equal(P.fromSettings({refreshMinutes: "60"}).refreshMinutes, 60);
assert.equal(P.fromSettings({locationRefreshMinutes: 99999}).locationRefreshMinutes, 1440);
assert.equal(P.fromSettings({requestUserAgent: "bad\nagent"}).requestUserAgent, "");
// The save schema covers every documented setting and matches the manifest.
const manifest = require('../manifest.json');
assert.deepEqual(P.fields.map(f => f.key).sort(), manifest.barWidget.schema.map(f => f.key).sort());
for (const f of P.fields) assert.deepEqual(manifest.barWidget.defaults[f.key], f.defaultValue, f.key);
assert.equal(P.temperature(-3.4, "metric", v => "٫" + v), "٫-3°", "numbers go through the language formatter");
assert.equal(P.temperatureValue(21.6, "metric"), "22");
assert.equal(P.fromSettings({automaticLocation:'true'}).automaticLocation,false);
assert.equal(P.fromSettings(null).units,'metric');
assert.equal(P.fromSettings([]).animations,true);
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

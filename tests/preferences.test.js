const I18n = require('./i18n.cjs');
const assert = require("node:assert/strict")
const P = require("../Preferences.js")
assert.deepEqual(P.fromSettings({language: 'nb'}), {units:'metric', automaticLocation:false, animations:true});
assert.deepEqual(P.fromSettings({language:'en', units:'imperial', automaticLocation:true, animations:false}), {units:'imperial', automaticLocation:true, animations:false});
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
assert.equal(P.age("2026-09-24T10:00:00Z", new Date("2026-09-24T10:31:00Z"), no), "31 min siden")
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

// Exercise the production callback, not a test translator that bypasses it.
const fs = require('node:fs');
const vm = require('node:vm');
const panelSource = fs.readFileSync(require('node:path').join(__dirname, '../Panel.qml'), 'utf8');
const wrapper = panelSource.match(/function tr\([^\n]+\}/)[0];
for (const language of ['en', 'no']) {
  const context = vm.createContext({FoamyI18n: {t: (key, values) => I18n.text(key, language, values)}});
  vm.runInContext(wrapper, context);
  for (const [minutes, key, amount] of [[2, '%1 min ago', 2], [60, '%1 hour ago', 1], [180, '%1 hours ago', 3]]) {
    const now = new Date(Date.parse('2026-09-24T10:00:00Z') + minutes * 60000);
    assert.equal(P.age('2026-09-24T10:00:00Z', now, context.tr), I18n.text(key, language, amount));
  }
}

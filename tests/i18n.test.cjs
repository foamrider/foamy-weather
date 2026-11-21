const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const I = require('./i18n.cjs');
const P = require('../Preferences.js');
const Model = require('../Model.js');
const read = name => fs.readFileSync(path.join(__dirname, '..', name), 'utf8');
// Comment lines hold examples, not texts the popup shows.
const codeLines = source => source.split('\n').filter(line => !/^\s*\/\//.test(line)).join('\n');
const hasEntries = key => Object.hasOwn(I.en, key) && Object.hasOwn(I.no, key);
const tokens = s => [...s.matchAll(/%[1-9][0-9]*|\{\w+\}/g)].map(m => m[0]).sort();
const forms = value => typeof value === 'object' ? Object.values(value) : [value];

test('the catalogs have the same keys and every translation keeps its placeholders', () => {
  for (const [key, value] of Object.entries(I.en)) {
    if (typeof value === 'object') assert.equal(value.other, key, `English plural source key: ${key}`);
    else assert.equal(value, key, `English source key: ${key}`);
    if (Object.hasOwn(I.no, key))
      for (const translated of forms(I.no[key])) assert.deepEqual(tokens(translated), tokens(key), key);
  }
  assert.deepEqual(Object.keys(I.no).sort(), Object.keys(I.en).sort(), 'every English key has a Norwegian entry');
});

test('ages read through the catalogs', () => {
  const fetched = '2026-09-24T10:00:00Z';
  for (const [language, minutes, expected] of [
    ['en', 0, 'now'], ['en', 1, 'now'], ['en', 2, '2 min ago'], ['en', 59, '59 min ago'],
    ['en', 60, '1 hour ago'], ['en', 91, '1 hour ago'], ['en', 180, '3 hours ago'],
    // A fetch time ahead of the clock (a clock step back) reads as now.
    ['en', -5, 'now'],
    ['no', 1, 'nå'], ['no', 2, '2 min siden'], ['no', 60, '1 time siden'], ['no', 180, '3 timer siden'],
  ]) {
    const now = new Date(Date.parse(fetched) + minutes * 60000);
    const t = (key, values) => I.text(key, language, values);
    const tn = (key, count) => I.plural(key, language, count);
    assert.equal(P.age(fetched, now, t, tn), expected, `${language}, ${minutes} min`);
  }
  assert.equal(P.age('yesterday', new Date(), key => key, key => key), '', 'an unreadable fetch time shows no age');
});

test('every key the plugin and its helper emit has a catalog entry', () => {
  const sources = ['Panel.qml', 'WeatherView.qml', 'WeatherSettings.qml', 'WeatherService.qml'].map(read).join('\n');
  for (const [, key] of sources.matchAll(/FoamyI18n\.tn?\("((?:[^"\\]|\\.)*)"/g)) assert.ok(Object.hasOwn(I.en, key), `missing catalog key: ${key}`);
  // Errors travel as keys: `settingsError = "…"`, `setError("…")`, and a
  // fallback after `||` on an error assignment.
  const errors = new Set();
  for (const [, key] of sources.matchAll(/(?:settingsError = |setError\()"([^"]+)"/g)) errors.add(key);
  for (const [, key] of sources.matchAll(/Error = [^\n]*\|\| "([^"]+)"/g)) errors.add(key);
  assert.ok(errors.size >= 7, `error keys found: ${[...errors].join(' | ')}`);
  assert.ok(errors.has('Could not read automatic location'), 'the automatic location fallback error is collected');
  for (const key of errors) assert.ok(hasEntries(key), `missing error key: ${key}`);
});

test('every text the popup shows has a catalog entry', () => {
  // Wind directions travel as data through windLabel's table.
  const panel = codeLines(read('Panel.qml'));
  const wind = panel.slice(panel.indexOf('function windLabel'));
  const table = wind.slice(wind.indexOf('var names = {'), wind.indexOf('}', wind.indexOf('var names = {')));
  const directions = [...table.matchAll(/: "([^"]+)"/g)].map(m => m[1]);
  assert.equal(directions.length, 8, `wind direction names found: ${directions}`);
  for (const name of directions) assert.ok(hasEntries(name), `missing wind direction: ${name}`);

  // Every MET symbol code: the description it maps to has both entries.
  const codes = ['cloudy', 'fog'];
  for (const base of ['clearsky', 'fair', 'partlycloudy'])
    for (const suffix of ['_day', '_night', '_polartwilight']) codes.push(base + suffix);
  for (const weight of ['light', '', 'heavy'])
    for (const precipitation of ['rain', 'sleet', 'snow'])
      for (const showers of ['', 'showers'])
        for (const thunder of ['', 'andthunder'])
          for (const suffix of ['', '_day', '_night', '_polartwilight'])
            codes.push(weight + precipitation + showers + thunder + suffix);
  // MET's own spelling of two codes (double "s").
  codes.push('lightssleetshowersandthunder_day', 'lightssnowshowersandthunder_night');
  for (const code of codes) {
    const description = Model.descriptionForSymbol(code);
    assert.notEqual(description, code.replace(/_(day|night|polartwilight)$/, ''), `${code} has no description`);
    assert.ok(hasEntries(description), `missing condition: ${description} (${code})`);
  }
  assert.equal(Model.descriptionForSymbol('lightssleetshowersandthunder_day'), 'Light sleet and thunder');

  // Kit texts the weather popup shows: the field's menu and paste errors,
  // the save queue's error, the settings save errors, the settings header
  // and error row, and the footer.
  const kit = [];
  const field = codeLines(read('kit/SafeTextField.qml'));
  for (const [, label] of field.matchAll(/root\.translate\("([^"]+)"\)/g)) kit.push(label);
  for (const line of field.split('\n').filter(l => l.includes('pasteError =')))
    for (const [, text] of line.matchAll(/"([^"]+)"/g)) kit.push(text);
  for (const [, text] of codeLines(read('kit/FoamyPrefsQueue.qml')).matchAll(/\berror = "([^"]+)"/g)) kit.push(text);
  const Prefs = require('../kit/node-loader.cjs').load('FoamyPrefs');
  kit.push(Prefs.NOT_ALLOWED, Prefs.NO_ENTRY);
  for (const name of ['kit/FoamySettingsHeader.qml', 'kit/FoamySettingsError.qml', 'kit/FoamyPanelFooter.qml'])
    for (const [, text] of codeLines(read(name)).matchAll(/FoamyI18n\.t\("([^"]+)"\)/g)) kit.push(text);
  const texts = new Set(kit);
  assert.ok(texts.size >= 18, `kit texts found: ${[...texts].join(' | ')}`);
  for (const text of texts) assert.ok(hasEntries(text), `missing kit text: ${text}`);
});

test('the helper error keys and the HTTPS text have catalog entries', () => {
  // The native helper's error keys (native/src/util.rs `mod keys`), the kit's
  // HTTPS-unsupported text it passes on, and the helper-unavailable message.
  const util = read('native/src/util.rs');
  const keys = util.slice(util.indexOf('pub mod keys {'), util.indexOf('}', util.indexOf('pub mod keys {')));
  const helperKeys = [...keys.matchAll(/: &str = "([^"]+)";/g)].map(m => m[1]);
  assert.ok(helperKeys.length >= 7, 'helper error keys found');
  const tls = read('kit/rust/foamy-helper/src/tls.rs');
  assert.equal(tls.match(/pub const UNSUPPORTED: &str = "([^"]+)";/)[1], Model.HTTPS_UNSUPPORTED, 'Model.HTTPS_UNSUPPORTED is tls::UNSUPPORTED');
  const FoamyNative = require('../kit/node-loader.cjs').load('FoamyNative');
  for (const key of [...helperKeys, Model.HTTPS_UNSUPPORTED, FoamyNative.UNAVAILABLE_TEXT])
    assert.ok(Object.hasOwn(I.en, key), `missing helper error key: ${key}`);
  // No other (stale) wording of the HTTPS-unsupported message stays in the catalogs.
  for (const key of Object.keys(I.en).filter(k => k.startsWith("HTTPS isn't supported on this CPU")))
    assert.equal(key, Model.HTTPS_UNSUPPORTED, 'HTTPS-unsupported key matches the kit\'s tls::UNSUPPORTED');
});

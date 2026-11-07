const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const I = require('./i18n.cjs');
const manifest = require('../manifest.json');
const tokens = s => [...s.matchAll(/%[1-9][0-9]*|\{\w+\}/g)].map(m => m[0]).sort();
const forms = value => typeof value === 'object' ? Object.values(value) : [value];
for (const [key, value] of Object.entries(I.en)) {
  if (typeof value === 'object') assert.equal(value.other, key, `English plural source key: ${key}`);
  else assert.equal(value, key, `English source key: ${key}`);
  if (Object.hasOwn(I.no, key))
    for (const translated of forms(I.no[key])) assert.deepEqual(tokens(translated), tokens(key), key);
}
assert.deepEqual(Object.keys(I.no).sort(), Object.keys(I.en).sort(), 'every English key has a Norwegian entry');
assert.equal(manifest.barWidget?.defaults?.language, undefined);
assert.equal((manifest.barWidget?.schema || []).some(f => f.key === 'language'), false);
assert.equal(I.text('Unknown %1 {name}', 'no', ['$& %2']), '$& %2 {name}'.replace(/^/, 'Unknown '));
assert.equal(I.text('constructor', 'no'), 'constructor');
const ui = fs.readFileSync(path.join(__dirname, '../kit/FoamyI18n.qml'), 'utf8');
assert.ok(ui.includes('Qt.createQmlObject'), '4.0 must not statically require a 4.5 QML type');
const P = require('../Preferences.js');
for (const language of ['en', 'no']) {
  const t = (key, values) => I.text(key, language, values);
  const tn = (key, count) => I.plural(key, language, count);
  for (const [minutes, expected] of [[1, t('now')], [2, tn('%1 min ago', 2)], [60, tn('%1 hours ago', 1)], [180, tn('%1 hours ago', 3)]]) {
    const now = new Date(Date.parse('2026-09-24T10:00:00Z') + minutes * 60000);
    assert.equal(P.age('2026-09-24T10:00:00Z', now, t, tn), expected);
  }
}
assert.equal(I.plural('%1 hours ago', 'en', 1), '1 hour ago');
assert.equal(I.plural('%1 hours ago', 'no', 3), '3 timer siden');
// Every key the plugin and its helper emit has a catalog entry.
const sources = ['Panel.qml', 'WeatherView.qml', 'WeatherSettings.qml', 'WeatherService.qml']
  .map(name => fs.readFileSync(path.join(__dirname, '..', name), 'utf8')).join('\n');
for (const [, key] of sources.matchAll(/FoamyI18n\.tn?\("((?:[^"\\]|\\.)*)"/g)) assert.ok(Object.hasOwn(I.en, key), `missing catalog key: ${key}`);
for (const [, key] of sources.matchAll(/(?:settingsError = |setError\()"([^"]+)"/g)) assert.ok(Object.hasOwn(I.en, key), `missing error key: ${key}`);
// The native helper's error keys (native/src/util.rs `mod keys`), the kit's
// HTTPS-unsupported text it passes on, and the helper-unavailable message.
const util = fs.readFileSync(path.join(__dirname, '../native/src/util.rs'), 'utf8');
const keys = util.slice(util.indexOf('pub mod keys {'), util.indexOf('}', util.indexOf('pub mod keys {')));
const helperKeys = [...keys.matchAll(/: &str = "([^"]+)";/g)].map(m => m[1]);
assert.ok(helperKeys.length >= 7, 'helper error keys found');
assert.doesNotMatch(helperKeys.join('\n'), /Mangler|Ukjent/, 'helper errors are English keys');
const Model = require('../Model.js');
const tls = fs.readFileSync(path.join(__dirname, '../kit/rust/foamy-helper/src/tls.rs'), 'utf8');
assert.equal(tls.match(/pub const UNSUPPORTED: &str = "([^"]+)";/)[1], Model.HTTPS_UNSUPPORTED, 'Model.HTTPS_UNSUPPORTED is tls::UNSUPPORTED');
const FoamyNative = require('../kit/node-loader.cjs').load('FoamyNative');
for (const key of [...helperKeys, Model.HTTPS_UNSUPPORTED, FoamyNative.UNAVAILABLE_TEXT])
  assert.ok(Object.hasOwn(I.en, key), `missing helper error key: ${key}`);
// No other (stale) wording of the HTTPS-unsupported message stays in the catalogs.
for (const key of Object.keys(I.en).filter(k => /^HTTPS isn't supported on this CPU/.test(k)))
  assert.equal(key, Model.HTTPS_UNSUPPORTED, 'HTTPS-unsupported key matches the kit\'s tls::UNSUPPORTED');
console.log('Weather i18n tests passed.');

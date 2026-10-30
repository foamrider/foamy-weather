// Exercise the kit's real substitution function with catalog data in pure model tests.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../kit/FoamyI18n.qml'), 'utf8');
const start = source.indexOf('  function substitute(');
const end = source.indexOf('\n  function t(', start);
const scope = vm.createContext({});
vm.runInContext(source.slice(start, end), scope);
scope.root = {number: value => String(value)};
const en = require('../i18n/en.json');
const no = require('../i18n/no.json');
const catalogFor = language => language === 'no' || language === 'nb' ? no : en;
// English plural rule (one/other) is enough for en and no.
function form(value, count) {
  if (value && typeof value === 'object') return Math.abs(Number(count)) === 1 && value.one ? value.one : value.other;
  return value;
}
function text(key, language, values) {
  const catalog = catalogFor(language);
  return scope.substitute(Object.hasOwn(catalog, key) ? form(catalog[key]) : key, values);
}
function plural(key, language, count) {
  const catalog = catalogFor(language);
  return scope.substitute(Object.hasOwn(catalog, key) ? form(catalog[key], count) : key, [count]);
}
module.exports = {text, plural, no, en, norwegian: no, nb: no};

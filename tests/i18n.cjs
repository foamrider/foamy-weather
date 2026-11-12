// Exercise the kit's real substitution (FoamyI18nText, which FoamyI18n calls)
// with catalog data in pure model tests.
const I18n = require('../kit/node-loader.cjs').load('FoamyI18nText');
const en = require('../i18n/en.json');
const no = require('../i18n/no.json');
const scopes = {en: I18n.translator(en, en), no: I18n.translator(no, en)};
const scope = language => (language === 'no' || language === 'nb' ? scopes.no : scopes.en);
const text = (key, language, values) => scope(language).t(key, values);
const plural = (key, language, count) => scope(language).tn(key, count);
module.exports = {text, plural, no, en, norwegian: no, nb: no};

#!/usr/bin/env node
/* Generate prize codes for game nights.
   Usage: node tools/make-codes.js --set placeholder --packs 3 --count 10
   (Remember to change SECRET in js/codes.js before sharing the site.) */
const codes = require('../js/codes.js');
const args = process.argv.slice(2);
const opt = (n, d) => { const i = args.indexOf('--' + n); return i >= 0 ? args[i + 1] : d; };
const set = opt('set', 'placeholder'), packs = +opt('packs', 3), count = +opt('count', 5);
if (codes.usingDefaultSecret) console.warn('Note: js/codes.js still uses the default SECRET.\n');
for (let i = 0; i < count; i++) console.log(codes.make(set, packs));

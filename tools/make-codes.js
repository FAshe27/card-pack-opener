#!/usr/bin/env node
/* Generate prize codes for game nights. Each code grants packs of ONE set
   (the set id is baked into the code's checksum, same as the in-app generator).

   Usage:
     node tools/make-codes.js --set placeholder --packs 3 --count 10
     node tools/make-codes.js --list          (show set ids found in sets/)

   Remember to change SECRET in js/codes.js before sharing the site. */
const fs = require('fs');
const path = require('path');
const codes = require('../js/codes.js');

const args = process.argv.slice(2);
const opt = (n, d) => { const i = args.indexOf('--' + n); return i >= 0 ? args[i + 1] : d; };

// find set ids/names declared in the set files listed in sets/manifest.js
const setsDir = path.join(__dirname, '..', 'sets');
const manifest = fs.readFileSync(path.join(setsDir, 'manifest.js'), 'utf8');
const files = [...manifest.matchAll(/['"]([^'"]+\.js)['"]/g)].map(m => m[1]);
const known = {};
for (const f of files) {
  try {
    const src = fs.readFileSync(path.join(setsDir, f), 'utf8');
    const id = (src.match(/["']?id["']?\s*:\s*["']([^"']+)["']/) || [])[1];
    const name = (src.match(/["']?name["']?\s*:\s*["']([^"']+)["']/) || [])[1];
    if (id) known[id.trim().toLowerCase()] = name || id;
  } catch (e) { /* missing file: skip */ }
}

if (args.includes('--list')) {
  Object.entries(known).forEach(([id, name]) => console.log(`${id}\t${name}`));
  process.exit(0);
}
const set = String(opt('set', 'fast-food')).trim().toLowerCase();
const packs = Math.max(1, Math.min(99, +opt('packs', 3) || 1));
const count = Math.max(1, +opt('count', 5) || 1);
if (!known[set]) {
  console.warn(`Warning: no set with id "${set}" in sets/manifest.js. Known: ${Object.keys(known).join(', ') || '(none)'}`);
  console.warn('Codes for a browser-imported set only work in browsers that imported that set.\n');
}
if (codes.usingDefaultSecret) console.warn('Note: js/codes.js still uses the default SECRET.\n');
console.log(`# ${count} code(s) for ${known[set] || set} (${packs} pack(s) each)`);
for (let i = 0; i < count; i++) console.log(codes.make(set, packs));

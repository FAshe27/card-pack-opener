#!/usr/bin/env node
/* Turn a CSV of cards into a set file and register it in sets/manifest.js.

   Usage:
     node tools/csv-to-set.js my-cards.csv --name "Backyard Birds" [--id birds] [--code BRD]
                              [--primary "#ff7a59"] [--secondary "#7b2ff7"] [--no-manifest]

   CSV columns (header row, any order): name, rarity, subtitle, details, image, id
   Only name and rarity are required. "details" is the free-text box at the bottom
   of the card (stats, fun facts, flavor text...). */
const fs = require('fs');
const path = require('path');
const csv = require('../js/csv.js');

const args = process.argv.slice(2);
const file = args.find(a => !a.startsWith('--') && !isFlagValue(a));
function isFlagValue(a) { const i = args.indexOf(a); return i > 0 && args[i - 1].startsWith('--') && args[i - 1] !== '--no-manifest'; }
function opt(name) { const i = args.indexOf('--' + name); return i >= 0 ? args[i + 1] : undefined; }
if (!file) { console.error('Usage: node tools/csv-to-set.js cards.csv --name "Set Name" [--id my-set] [--code ABC]'); process.exit(1); }

const name = opt('name') || path.basename(file, path.extname(file)).replace(/[_-]+/g, ' ');
const res = csv.toSet(fs.readFileSync(file, 'utf8'), {
  name, id: opt('id'), code: opt('code'), description: opt('description'),
  primary: opt('primary'), secondary: opt('secondary')
});
res.errors.forEach(e => console.warn('  ! ' + e));
if (!res.set || !res.set.cards.length) { console.error('No cards written.'); process.exit(1); }

const setsDir = path.join(__dirname, '..', 'sets');
const outFile = res.set.id + '.js';
fs.writeFileSync(path.join(setsDir, outFile), csv.toJsFile(res.set));
console.log(`Wrote sets/${outFile}: ${res.set.cards.length} cards`, res.counts);

if (!args.includes('--no-manifest')) {
  const mPath = path.join(setsDir, 'manifest.js');
  let m = fs.readFileSync(mPath, 'utf8');
  if (!m.includes(`'${outFile}'`)) {
    m = m.replace(/CardSets\.manifest\s*=\s*\[([\s\S]*?)\]/, (all, inner) => {
      const items = inner.trim().replace(/,\s*$/, '');
      return `CardSets.manifest = [\n  ${items ? items + ',\n  ' : ''}'${outFile}'\n]`;
    });
    fs.writeFileSync(mPath, m);
    console.log(`Added '${outFile}' to sets/manifest.js`);
  }
}

#!/usr/bin/env node
/* Turn a CSV of cards into a set file and register it in sets/manifest.js.

   Usage:
     node tools/csv-to-set.js my-cards.csv --name "Backyard Birds" [--id birds] [--code BRD]
                              [--primary "#ff7a59"] [--secondary "#7b2ff7"] [--no-manifest]
                              [--site-root <dir>]   (default: this repo)

   CSV columns (header row, any order): name, rarity, subtitle, details, image, logo, id
   Only name and rarity are required. "details" is the free-text box at the bottom
   of the card (stats, fun facts, flavor text...). "logo" is an optional brand logo:
   with no details it fills the details box (and the art gets bigger); with details
   it sits as a small chip beside the text.

   image / logo values can be web URLs, paths inside the site (e.g. assets/...), or
   files on this computer (absolute paths, or paths relative to the CSV file). Local
   files are copied into assets/sets/<set-id>/images|logos/ and the paths rewritten
   to site-relative URLs. Identical files are stored once. */
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const csv = require('../js/csv.js');

const args = process.argv.slice(2);
const VALUE_FLAGS = ['name', 'id', 'code', 'description', 'primary', 'secondary', 'site-root'];
const file = args.find((a, i) => !a.startsWith('--') && !(i > 0 && VALUE_FLAGS.includes(args[i - 1].replace(/^--/, ''))));
function opt(name) { const i = args.indexOf('--' + name); return i >= 0 ? args[i + 1] : undefined; }
if (!file) { console.error('Usage: node tools/csv-to-set.js cards.csv --name "Set Name" [--id my-set] [--code ABC]'); process.exit(1); }

const siteRoot = path.resolve(opt('site-root') || path.join(__dirname, '..'));
const csvDir = path.dirname(path.resolve(file));
const name = opt('name') || path.basename(file, path.extname(file)).replace(/[_-]+/g, ' ');
const res = csv.toSet(fs.readFileSync(file, 'utf8'), {
  name, id: opt('id'), code: opt('code'), description: opt('description'),
  primary: opt('primary'), secondary: opt('secondary')
});
res.errors.forEach(e => console.warn('  ! ' + e));
if (!res.set || !res.set.cards.length) { console.error('No cards written.'); process.exit(1); }

// ---- copy local image/logo files into the site
const copied = new Map();   // sha256 -> site-relative path (dedupe identical files)
const used = new Set();     // site-relative paths already taken
const stats = { copied: 0, deduped: 0, missing: 0 };
const isUrl = v => /^(https?:|data:|\/\/)/i.test(v);
function localFileFor(v) {
  if (isUrl(v)) return null;
  const p = v.replace(/^file:\/\//i, '');
  if (path.isAbsolute(p)) {                                           // e.g. /home/me/logos/logo.png
    if (!fs.existsSync(p) && fs.existsSync(path.join(siteRoot, p))) return null; // "/assets/x.png" style site path
    return p;
  }
  if (fs.existsSync(path.join(siteRoot, p))) return null;             // already a path inside the site
  const rel = path.resolve(csvDir, p);
  return fs.existsSync(rel) ? rel : null;                             // relative to the CSV file
}
function safeName(base) { return base.toLowerCase().replace(/[^a-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '') || 'file'; }
function importAsset(value, kind, cardName) {
  const src = localFileFor(value);
  if (!src) return value;
  if (!fs.existsSync(src) || !fs.statSync(src).isFile()) {
    console.warn(`  ! ${cardName}: ${kind} file not found: ${value} (left out)`);
    stats.missing++; return '';
  }
  const data = fs.readFileSync(src);
  const hash = crypto.createHash('sha256').update(data).digest('hex');
  if (copied.has(hash)) { stats.deduped++; return copied.get(hash); }
  const dirRel = ['assets', 'sets', res.set.id, kind === 'logo' ? 'logos' : 'images'].join('/');
  const ext = path.extname(src).toLowerCase(), stem = safeName(path.basename(src, path.extname(src)));
  let rel = `${dirRel}/${stem}${ext}`, n = 2;
  while (used.has(rel) || (fs.existsSync(path.join(siteRoot, rel)) &&
         crypto.createHash('sha256').update(fs.readFileSync(path.join(siteRoot, rel))).digest('hex') !== hash)) {
    rel = `${dirRel}/${stem}-${n++}${ext}`;
  }
  fs.mkdirSync(path.join(siteRoot, dirRel), { recursive: true });
  fs.writeFileSync(path.join(siteRoot, rel), data);
  used.add(rel); copied.set(hash, rel); stats.copied++;
  return rel;
}
res.set.cards.forEach(c => {
  ['image', 'logo'].forEach(k => {
    if (!c[k]) return;
    const v = importAsset(c[k], k, c.name);
    if (v) c[k] = v; else delete c[k];
  });
});
if (stats.copied || stats.deduped || stats.missing) {
  console.log(`Assets: ${stats.copied} file(s) copied to assets/sets/${res.set.id}/, ${stats.deduped} duplicate reference(s) reused, ${stats.missing} missing`);
}

const setsDir = path.join(siteRoot, 'sets');
const outFile = res.set.id + '.js';

// ---- re-importing over an existing set file keeps its hand-edited settings
// (description, pack name/emblem/odds, theme extras); --description/--primary/--secondary still win.
if (fs.existsSync(path.join(setsDir, outFile))) {
  let old = null;
  try {
    const vm = require('vm'), ctx = { CardSets: { register: s => { old = s; } } };
    vm.createContext(ctx); vm.runInContext(fs.readFileSync(path.join(setsDir, outFile), 'utf8'), ctx);
  } catch (e) { console.warn(`  ! could not read the existing sets/${outFile} (${e.message}); writing a fresh one`); }
  if (old) {
    const kept = [];
    if (old.description && opt('description') == null) { res.set.description = old.description; kept.push('description'); }
    if (old.pack) { res.set.pack = old.pack; kept.push('pack'); }
    if (old.theme) {
      const t = Object.assign({}, old.theme, res.set.theme || {});
      if (opt('primary') == null && old.theme.primary) t.primary = old.theme.primary;
      if (opt('secondary') == null && old.theme.secondary) t.secondary = old.theme.secondary;
      res.set.theme = t; kept.push('theme');
    }
    if (kept.length) console.log(`Kept ${kept.join(', ')} from the existing sets/${outFile}`);
  }
}
{ // settings first, the long card list last (easier to hand-edit)
  const { cards, ...rest } = res.set, order = ['id', 'name', 'code', 'description', 'theme', 'pack'];
  const tidy = {}; order.forEach(k => { if (k in rest) tidy[k] = rest[k]; }); Object.assign(tidy, rest, { cards });
  res.set = tidy;
}
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

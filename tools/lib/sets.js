/* Load set files exactly the way the browser does (same normalization and
   resolved pack odds), and turn them into the payload the server stores. */
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.join(__dirname, '..', '..');

function loadAll() {
  const ctx = { console, crypto: require('crypto').webcrypto, Uint32Array };
  ctx.window = ctx; ctx.self = ctx;
  vm.createContext(ctx);
  for (const f of ['js/util.js', 'js/rarities.js', 'js/registry.js']) {
    vm.runInContext(fs.readFileSync(path.join(ROOT, f), 'utf8'), ctx, { filename: f });
  }
  const manifestSrc = fs.readFileSync(path.join(ROOT, 'sets/manifest.js'), 'utf8');
  vm.runInContext(manifestSrc, ctx, { filename: 'sets/manifest.js' });
  for (const f of ctx.CardSets.manifest) {
    const p = path.join(ROOT, 'sets', f);
    if (!fs.existsSync(p)) { console.warn(`  ! sets/${f} listed in manifest but missing`); continue; }
    vm.runInContext(fs.readFileSync(p, 'utf8'), ctx, { filename: 'sets/' + f });
  }
  ctx.CardSets.errors.forEach(e => console.warn('  ! ' + e));
  return ctx.CardSets;
}

/* Payload for cps_admin_upsert_set / seed SQL */
function payload(set) {
  return {
    id: set.id,
    name: set.name,
    code: set.code,
    pack: {
      name: set.pack.name,
      slots: set.pack.slots.map(s => ({ count: s.count, label: s.label, odds: s.odds })),
      holo: set.pack.holo
    },
    cards: set.cards.map(c => ({ id: c.id, num: typeof c.num === 'number' ? c.num : parseInt(c.num, 10) || null, name: c.name, rarity: c.rarity }))
  };
}

function sqlLiteral(s) { return "'" + String(s).replace(/'/g, "''") + "'"; }

/* SQL that upserts a set directly (for the SQL editor / setup.sql) */
function seedSql(set) {
  const p = payload(set);
  return `-- set: ${p.name} (${p.cards.length} cards)
insert into cps.card_sets (id, name, code, pack, card_count, active, updated_at)
values (${sqlLiteral(p.id)}, ${sqlLiteral(p.name)}, ${sqlLiteral(p.code)}, ${sqlLiteral(JSON.stringify(p.pack))}::jsonb, ${p.cards.length}, true, now())
on conflict (id) do update set name = excluded.name, code = excluded.code, pack = excluded.pack, card_count = excluded.card_count, active = true, updated_at = now();
insert into cps.cards (set_id, card_id, num, name, rarity)
select ${sqlLiteral(p.id)}, c->>'id', nullif(c->>'num','')::int, c->>'name', c->>'rarity'
from jsonb_array_elements(${sqlLiteral(JSON.stringify(p.cards))}::jsonb) c
on conflict (set_id, card_id) do update set num = excluded.num, name = excluded.name, rarity = excluded.rarity;
`;
}

module.exports = { loadAll, payload, seedSql, ROOT };

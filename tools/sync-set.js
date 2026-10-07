#!/usr/bin/env node
/* Upload set(s) from sets/ to the server so packs of that set can be opened online.
   (Packs are rolled server-side, so the server needs the cards + odds.)

   Options:
     node sync-set.js placeholder birds         # via the API, logs in as admin
         -> needs env CPS_ADMIN_USERNAME (your secret admin username)
     node sync-set.js --all                     # every set in sets/manifest.js
     node sync-set.js birds --sql > birds.sql   # print SQL to paste into the Supabase SQL Editor
     node sync-set.js birds --db                # write directly using SUPABASE_DB_URL

   Easiest of all: in the app, log in as admin -> Dev mode -> Admin tab -> "Upload". */
const path = require('path');
const fs = require('fs');
const { loadAll, payload, seedSql, ROOT } = require('./lib/sets');

const args = process.argv.slice(2);
const flags = new Set(args.filter(a => a.startsWith('--')));
let ids = args.filter(a => !a.startsWith('--'));
const CardSets = loadAll();
if (flags.has('--all') || !ids.length) ids = CardSets.ids();
const sets = ids.map(id => { const s = CardSets.get(id); if (!s) { console.error(`No set "${id}" in sets/manifest.js`); process.exit(1); } return s; });

if (flags.has('--sql')) { process.stdout.write(sets.map(seedSql).join('\n') + "\nnotify pgrst, 'reload schema';\n"); process.exit(0); }

(async () => {
  if (flags.has('--db')) {
    const url = process.env.SUPABASE_DB_URL;
    if (!url) { console.error('SUPABASE_DB_URL is not set.'); process.exit(1); }
    const { Client } = require('pg');
    const c = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
    try { await c.connect(); for (const s of sets) { await c.query(seedSql(s)); console.log(`Synced ${s.id} (${s.cards.length} cards)`); } }
    catch (e) { console.error('Failed:', String(e.message).split(url).join('<db-url>')); process.exitCode = 1; }
    finally { await c.end().catch(() => {}); }
    return;
  }
  const vm = require('vm');
  const ctx = { window: {} }; vm.createContext(ctx);
  vm.runInContext(fs.readFileSync(path.join(ROOT, 'js/config.js'), 'utf8'), ctx);
  const cfg = Object.assign({}, ctx.window.CPS_CONFIG, process.env.CPS_SUPABASE_URL ? { supabaseUrl: process.env.CPS_SUPABASE_URL, supabaseKey: process.env.CPS_SUPABASE_KEY } : {});
  const user = process.env.CPS_ADMIN_USERNAME;
  if (!user) { console.error('Set CPS_ADMIN_USERNAME to your admin username (or use --sql / --db).'); process.exit(1); }
  const rpc = async (fn, body) => {
    const r = await fetch(cfg.supabaseUrl.replace(/\/+$/, '') + '/rest/v1/rpc/' + fn, {
      method: 'POST', headers: { apikey: cfg.supabaseKey, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    const j = await r.json().catch(() => null);
    if (!r.ok) throw new Error((j && j.message) || r.status);
    return j;
  };
  const login = await rpc('cps_login', { p_username: user, p_user_agent: 'tools/sync-set.js' });
  if (!login.ok) { console.error('Login failed:', login.error); process.exit(1); }
  try {
    for (const s of sets) {
      const r = await rpc('cps_admin_upsert_set', { p_token: login.token, p_set: payload(s) });
      console.log(`Synced ${r.set_id}: ${r.cards} cards${r.removed ? `, removed ${r.removed} unowned old cards` : ''}`);
    }
  } catch (e) { console.error('Failed:', e.message); process.exitCode = 1; }
  finally { await rpc('cps_logout', { p_token: login.token }).catch(() => {}); }
})();

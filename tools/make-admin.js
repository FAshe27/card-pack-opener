#!/usr/bin/env node
/* Create (or promote) the site owner's ADMIN account.
   The username is the login secret, so it's never stored in plain text and is not
   printed unless you ask for a generated one.

   Usage (needs the database connection string in SUPABASE_DB_URL):
     cd tools && npm install
     node make-admin.js --username "your-secret-username" [--name "Display Name"] [--packs 3]
     node make-admin.js --generate --name "FAshe27"        # makes up a strong username and prints it once

   No direct DB access? Paste this in Supabase Dashboard -> SQL Editor instead:
     select cps.bootstrap_admin('your-secret-username', 'Your Name');            */
const crypto = require('crypto');
const args = process.argv.slice(2);
const opt = (n, d) => { const i = args.indexOf('--' + n); return i >= 0 ? args[i + 1] : d; };
const envName = opt('db-env', 'SUPABASE_DB_URL');
const url = process.env[envName];
let username = opt('username');
const name = opt('name', 'Admin');
const packs = opt('packs') != null ? parseInt(opt('packs'), 10) : null;
if (args.includes('--generate')) {
  const ALPH = '23456789abcdefghjkmnpqrstuvwxyz';
  const base = name.toLowerCase().replace(/[^a-z0-9]+/g, '').slice(0, 12) || 'admin';
  username = base + '-' + Array.from(crypto.randomBytes(10), b => ALPH[b % ALPH.length]).join('');
}
if (!username || username.trim().length < 6) { console.error('Give --username (6+ chars) or --generate.'); process.exit(1); }
if (!url) { console.error(`${envName} is not set. Use the SQL editor snippet from the comment at the top of this file instead.`); process.exit(1); }

const { Client } = require('pg');
(async () => {
  const c = new Client({ connectionString: url, ssl: url.includes('localhost') || url.includes('host=/') ? false : { rejectUnauthorized: false } });
  try {
    await c.connect();
    const r = await c.query('select cps.bootstrap_admin($1, $2, $3) as id', [username.trim(), name, packs]);
    console.log(`Admin account ready (id ${r.rows[0].id}, display name "${name}").`);
    if (args.includes('--generate')) console.log(`Secret username (save it now, it is not stored in plain text): ${username}`);
  } catch (e) {
    console.error('Failed:', String(e.message).split(url).join('<db-url>'));
    process.exitCode = 1;
  } finally { await c.end().catch(() => {}); }
})();

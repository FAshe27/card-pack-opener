#!/usr/bin/env node
/* Create (or promote) the site owner's ADMIN account. Login is username + 4-digit PIN.
   The PIN is stored only as a bcrypt hash; it is printed once if this script makes it up.

   Usage (needs the database connection string in SUPABASE_DB_URL):
     cd tools && npm install
     node make-admin.js --username "YourName" --name "Display Name" [--pin 1234] [--packs 3]
       (no --pin: a random PIN is generated and printed once)
     Running it for an existing username makes that account admin and, with --pin, resets its PIN.

   No direct DB access? Paste this in Supabase Dashboard -> SQL Editor instead:
     select cps.bootstrap_admin('YourName', 'Display Name', '1234');                 */
const crypto = require('crypto');
const args = process.argv.slice(2);
const opt = (n, d) => { const i = args.indexOf('--' + n); return i >= 0 ? args[i + 1] : d; };
const envName = opt('db-env', 'SUPABASE_DB_URL');
const url = process.env[envName];
let username = opt('username');
const name = opt('name', 'Admin');
const packs = opt('packs') != null ? parseInt(opt('packs'), 10) : null;
let pin = opt('pin');
const generatedPin = !pin;
if (!pin) pin = String(crypto.randomInt(0, 10000)).padStart(4, '0');
if (!/^[0-9]{4}$/.test(pin)) { console.error('--pin must be exactly 4 digits.'); process.exit(1); }
if (!username || username.trim().length < 2) { console.error('Give --username (2+ characters).'); process.exit(1); }
if (!url) { console.error(`${envName} is not set. Use the SQL editor snippet from the comment at the top of this file instead.`); process.exit(1); }

const { Client } = require('pg');
(async () => {
  const c = new Client({ connectionString: url, ssl: url.includes('localhost') || url.includes('host=/') ? false : { rejectUnauthorized: false } });
  try {
    await c.connect();
    const r = await c.query('select cps.bootstrap_admin($1, $2, $3, $4) as id', [username.trim(), name, pin, packs]);
    console.log(`Admin account ready (id ${r.rows[0].id}, display name "${name}").`);
    console.log(`Username: ${username.trim()}`);
    if (generatedPin) console.log(`PIN (save it now, it is only stored hashed): ${pin}`);
  } catch (e) {
    console.error('Failed:', String(e.message).split(url).join('<db-url>'));
    process.exitCode = 1;
  } finally { await c.end().catch(() => {}); }
})();

# PackRip — Card Pack Opener Simulator

A browser-based trading card pack opener. Open packs, build a collection, chase ultra-rare cards, and redeem prize codes. Vanilla HTML / CSS / JS — no build step. Works from `file://` or any static host (GitHub Pages, Netlify, etc.).

Cards are for collecting and trading only. Each card has a free-form **details** text box at the bottom of the face (stats, fun facts, flavor text — whatever you want).

## Quick start

- **Local:** open `index.html` in a browser, or `python3 -m http.server 8000` from this folder and visit http://localhost:8000
- **Host:** push this folder to GitHub Pages / Netlify / any static host. Point the site root at this directory.

First visit gives you 3 starter packs. **Dev mode** (Sets & Settings, or add `?dev` to the URL) adds free packs and a prize-code generator. It's password protected: only a SHA-256 hash of the password is stored (`DEV_HASH` in `js/devlock.js`). Once unlocked it stays on in that browser; switching it off means the password is needed again. To change the password, run `printf 'new-password' | sha256sum` and paste the hex into `DEV_HASH`.

## Placeholder set (~250 cards)

| Rarity | Cards in set | Chance of ≥1 per pack | Specific card |
|--------|-------------:|----------------------:|--------------:|
| Common | 120 | every pack | ~1 in 22 packs |
| Uncommon | 70 | every pack | ~1 in 31 packs |
| Rare | 35 | ~84% | ~1 in 37 packs |
| Epic | 15 | ~17% | ~1 in 88 packs |
| Legendary | 6 | ~4% (1 in 25) | ~1 in 150 packs |
| Chase | 4 | ~0.2% (1 in 500) | ~1 in 2,000 packs |

Each pack has **9 cards**: 5 Common + 2 Uncommon + 1 wild (mostly Common/Uncommon, sometimes Rare/Epic) + **1 guaranteed Rare or better**. Holo foil chance grows with rarity (2% Common → 25% Chase).

There's also a tiny **Demo Mini Set** (30 cards) that shows CSV import and a real `image` path.

## Adding a new set

Sets live in `sets/` as `.js` files that call `CardSets.register({...})`. List them in `sets/manifest.js`.

### From a CSV (easiest)

```bash
node tools/csv-to-set.js my-cards.csv --name "Backyard Birds" --id birds --code BRD
```

That writes `sets/birds.js` and adds it to the manifest. Columns (header row, any order):

| Column | Required | Notes |
|--------|----------|-------|
| `name` | yes | Card title |
| `rarity` | yes | `common` / `uncommon` / `rare` / `epic` / `legendary` / `chase` (or C/U/R/E/L/X) |
| `subtitle` | no | Short line under the name (species, team, category…) |
| `details` | no | Free-form text box on the card face — stats, fun facts, flavor text, anything |
| `image` | no | Path or URL to art; leave blank for procedural placeholder art |
| `id` | no | Stable id (defaults to 001, 002, …) |

You can also paste a CSV in the app under **Sets & Settings → Import a set from CSV**. That stores the set in this browser only; use **Download set file (.js)** and drop it into `sets/` to share it with everyone.

Aliases for the details column: `flavor`, `text`, `description`.

### Hand-written set file

```js
CardSets.register({
  id: "birds",
  name: "Backyard Birds",
  code: "BRD",
  description: "Optional blurb shown on the Odds page.",
  theme: { primary: "#ff7a59", secondary: "#7b2ff7" },
  // pack: { ... }  // optional — falls back to the default 9-card layout
  cards: [
    { name: "Northern Cardinal", rarity: "common",  subtitle: "Songbird", details: "Males are bright red; females are tan." },
    { name: "Bald Eagle",        rarity: "legendary", subtitle: "Raptor", details: "Wingspan up to 7.5 feet." }
  ]
});
```

Optional pack config (weights are relative; they don't need to sum to 100):

```js
pack: {
  name: "Booster Pack",
  slots: [
    { count: 5, label: "Common", odds: { common: 100 } },
    { count: 2, label: "Uncommon", odds: { uncommon: 100 } },
    { count: 1, label: "Wild card", odds: { common: 55, uncommon: 30, rare: 12, epic: 3 } },
    { count: 1, label: "Rare or better", odds: { rare: 81.8, epic: 14, legendary: 4, chase: 0.2 } }
  ],
  holo: { common: 2, uncommon: 3, rare: 6, epic: 10, legendary: 15, chase: 25 }
}
```

If a slot asks for a rarity your set doesn't have, its weight moves to the nearest rarity you do have.

Regenerate the numbered placeholder set with `node tools/make-placeholder-set.js`.

## Prize codes

Format: `PACK-<packs>-<nonce>-<check>` (e.g. `PACK-3-K7QZ2-9XH4M`). Each code grants packs of one specific set; the app tells the player which set got the packs and switches to it.

**Online (logged in):** codes live in the database. An admin makes them in Dev mode → Sets & Settings → Prize code generator (pick the set, packs per code, how many codes, **max uses**, optional note). A code with max uses 1 works once; with max uses 5, five different players can redeem it once each. The Admin tab lists recent codes and who redeemed them. Server codes can't be forged.

**Guest / offline:** codes are checked in the browser with `js/codes.js` (same generator in guest mode, or `node tools/make-codes.js --set placeholder --packs 3 --count 10`, `--list` shows set ids). Anyone who reads `js/codes.js` can mint these, so change `SECRET` before sharing. Guest codes don't work for online accounts and vice versa.

## Online accounts (Supabase)

### How it works

- **Login is a username only.** No password, no email, no public sign-up. The site owner (admin) creates each account and gives the friend their username privately. The username *is* the secret, so make it long and random (the Admin tab's **Suggest** button makes ones like `alex-k3m9q2x`).
- Logging in calls `cps_login`, which returns a random 256-bit session token. Only its SHA-256 hash is stored server-side. Usernames are also stored only as hashes (plus a short hint like `al…(12)` for the admin list). With **Remember me** the token sits in `localStorage` (valid 365 days); without it, in `sessionStorage` (gone when the tab closes). **Log out** revokes it on the server.
- Failed logins are rate-limited per IP: each miss waits about 0.4 s, and 8 misses in 15 minutes locks that IP out for the rest of the window.
- **All data lives in a private `cps` schema** that the API doesn't expose. Every table has row-level security on with no policies, and the `anon`/`authenticated` roles have no privileges on it. The browser can only call `public.cps_*` functions (`SECURITY DEFINER`), which check the token first. Nobody can list accounts or read usernames, and only admin tokens pass the `cps_admin_*` functions.
- **Packs are opened on the server** (`cps_open_pack`): it spends a pack, rolls the cards with the set's odds, and saves the collection and stats, so results can't be faked from the browser. The browser only animates what the server rolled.
- **Guest mode still works:** "Play as guest instead" (or `file://` with no network, or if the server can't be reached) uses the old local storage. Once logged in, an account can upload its guest collection **once** (Your account → Upload guest collection). The upload is validated against the server's card list and capped at 10 packs' worth by default (`guest_import_max_packs`).
- **Trading groundwork:** `cps.card_transfers` and `cps.transfer_card()` move copies between accounts with an audit row. There's no trading UI or public RPC yet.

### Config file

`js/config.js` holds the project URL and the **publishable** key (safe to be public; it only allows calling the `cps_*` functions). Set `onlineEnabled: false` to turn accounts off entirely (pure guest mode). Never put the database URL, the service-role key, or any username in this repo.

### One-time setup (Supabase dashboard)

1. Supabase Dashboard → your project → **SQL Editor** → **New query**.
2. Paste the whole of `supabase/setup.sql` → **Run**. It's safe to run again later; it creates the schema, functions and the two bundled sets.
3. In a new query, create your admin account with a long, private username (don't reuse a public handle):
   ```sql
   select cps.bootstrap_admin('your-secret-username', 'Your Name');
   ```
   Or, from a machine that can reach the database: `cd tools && npm install && SUPABASE_DB_URL=... node make-admin.js --generate --name "Your Name"`.
4. Open the site → **Log in** with that username → Sets & Settings → turn on **Dev mode** (password) → the **Admin** tab appears.

No Auth settings, email provider, or API settings need changing. Settings live in the `cps.app_config` table (welcome packs, default set, session length, login limits, guest uploads), and you can edit them in the Table Editor.

### Admin tab (admin login + Dev mode)

- **Create account:** display name, secret username (or Suggest), starting packs (default 3) and which set they're for, optional admin flag. The username is shown **once** with a Copy button, so send it to your friend privately.
- **Accounts list:** give or take packs for any set, rename, issue a new username (which logs them out everywhere), disable/enable, delete.
- **Sets on the server:** Upload / Re-sync any set the site has loaded (including a CSV import), so packs for it can be opened and codes made for it.
- **Prize codes:** recent codes with uses and who redeemed them.

### Adding a set to the online version

Add the set to `sets/` as usual (above) and push. Then get it into the database with any one of these:
- Admin tab → **Sets on the server** → Upload.
- `cd tools && CPS_ADMIN_USERNAME=... node sync-set.js birds` (uses the HTTPS API with your admin login; `--all` for every set).
- `node tools/sync-set.js birds --sql`, then paste the printed SQL into the SQL Editor.
- `node tools/build-setup-sql.js` regenerates `supabase/setup.sql` with every set in the manifest.

Card ids are stable: re-syncing updates names, rarities, odds and details without touching anyone's collection.

### Making someone else an admin

Admin tab → Create account → tick "Make this an admin account". For an existing account, run in the SQL Editor: `update cps.accounts set is_admin = true where display_name = 'Their Name';`.

## Features

- Procedural SVG placeholder art (seeded per card); real images when a card has an `image` path
- Rarity tiers Common → Chase, holo foils, glow / confetti for big pulls
- Pack tear animation, click-to-flip or Reveal all, WebAudio sounds (no audio files)
- Collection with owned / missing / dupe / holo filters, completion % by rarity
- Stats, odds panel, set picker, CSV importer, prize codes, multi-player profiles (guest)
- Optional online accounts with server-side pack opening (Supabase)
- Works from `file://` (sets are `.js` modules, not JSON fetches)

## Project layout

```
index.html
css/style.css
js/           util, rarities, registry, csv, codes, storage, cardface, packs, audio, fx, devlock,
              config (Supabase URL + publishable key), cloud (API client), app
sets/         manifest.js + one .js file per set (+ optional images/)
supabase/     migrations/001_core.sql, setup.sql (migrations + bundled sets; paste into SQL Editor)
tools/        make-placeholder-set.js, csv-to-set.js, make-codes.js, example.csv,
              build-setup-sql.js, sync-set.js, make-admin.js (npm install in tools/ for the pg driver)
```

## Known limitations

- The username is the only secret. Anyone who learns it can use that account, so treat it like a password. If one leaks, Admin tab → New username.
- Guest-mode prize codes are forgeable (see above); online codes are not.
- The dev-mode password is a client-side gate only. Real admin powers come from the admin account (checked on the server); Dev mode just shows the tools.
- A guest collection upload can't be verified (it came from the browser), so it's capped and allowed once per account.
- Guest collections are local to the browser; clear site data and they're gone (export first or upload to an account).
- No trading UI yet (database groundwork only).
- Supabase's free tier pauses a project after a week without activity; un-pause it in the dashboard. While it's unreachable the site falls back to guest mode.
- Holo / foil is CSS-only (no WebGL). Reduced-motion preference turns particle FX off.

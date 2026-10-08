# PackRip — Card Pack Opener Simulator

A browser-based trading card pack opener. Open packs, build a collection, chase ultra-rare cards, and redeem prize codes. Vanilla HTML / CSS / JS — no build step. Works from `file://` or any static host (GitHub Pages, Netlify, etc.).

Cards are for collecting and trading only. Each card has a free-form **details** text box at the bottom of the face (stats, fun facts, flavor text — whatever you want).

## Quick start

- **Local:** open `index.html` in a browser, or `python3 -m http.server 8000` from this folder and visit http://localhost:8000
- **Host:** push this folder to GitHub Pages / Netlify / any static host. Point the site root at this directory.

The site is **accounts-only**: everyone logs in with a username + 4-digit PIN that the site owner creates (see [Online accounts](#online-accounts-supabase)). To open a pack, click the pack in **Your packs** (it opens and tears in one go), or use the **Open a pack** button / Space.

**Admin tab** (admin accounts only) holds the account tools plus everything that used to be under Sets & Settings (card sets, CSV import, prize code generator, Dev tools). It's guarded twice: the server checks the account is an admin, and the browser asks for the **Dev password** before showing the tools. Only a SHA-256 hash of that password is stored (`DEV_HASH` in `js/devlock.js`). Once unlocked it stays on in that browser; untick "Admin tools unlocked" to lock it again. To change the password, run `printf 'new-password' | sha256sum` and paste the hex into `DEV_HASH`. Regular players only see Open Packs, Collection, Stats and Odds, plus the sound button and their account menu (log out, export).

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

**Fast Food Collection** (249 cards, code FF) uses real product photos and brand logos: 10 Chase, 14 Legendary, 24 Epic, 39 Rare, 66 Uncommon, 96 Common, in a red/yellow "Value Meal Pack".

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
| `name` | yes | Card title. Long names shrink to fit the header (down to 70%), then wrap to two lines; nothing is cut off unless a name is longer than two lines can hold |
| `rarity` | yes | `common` / `uncommon` / `rare` / `epic` / `legendary` / `chase` (or C/U/R/E/L/X) |
| `subtitle` | no | Short line under the name (species, team, category…) |
| `details` | no | Free-form text box on the card face — stats, fun facts, flavor text, anything |
| `image` | no | Path or URL to art; leave blank for procedural placeholder art |
| `logo` | no | Path or URL to a logo (PNG/SVG/JPG; transparent PNG or SVG looks best) |
| `id` | no | Stable id (defaults to 001, 002, …) |

Header used by the tools: `name,rarity,subtitle,details,image,logo`. Without a header row the columns are read in that order.

**Logos change the card layout:**

- **Logo, no details:** the logo is shown centered on a light plate where the details box would be, and the art area grows to fill the extra space. Good for item cards (a product photo plus the brand logo).
- **Details and logo:** a small logo chip sits beside the details text.
- **Details only (or nothing):** unchanged.
- Cards you haven't collected yet stay a plain `?` silhouette (number and rarity only): no logo, no art.
- A logo file that fails to load is simply hidden.

The same layout is used in the pack reveal, the zoom view and the collection.

**Image and logo files.** `csv-to-set.js` copies local files into the site so the set works when published:

- Absolute paths (`/home/me/logos/taco.png`), `file://` URLs and paths relative to the CSV are copied to `assets/sets/<set-id>/logos/` or `assets/sets/<set-id>/images/`, and rewritten to those site-relative URLs in the set file.
- Identical files are stored once, even if several cards (or two differently named copies) use them. Re-running the tool doesn't create extra copies.
- Missing files are reported (`! Card: logo file not found: …`) and left out; that card falls back to the normal layout or placeholder art.
- `http(s)://` URLs and paths already inside the site (e.g. `assets/…`, `sets/images/…`) are kept as they are.
- `--site-root <dir>` writes the set, manifest entry and assets into a different copy of the site (handy for trying a set out without touching the real one).

Commit the `assets/sets/<set-id>/` folder together with `sets/<set-id>.js`.

Re-running `csv-to-set.js` for a set that already has a file keeps that file's `description`, `pack` and `theme` settings (unless you pass `--description` / `--primary` / `--secondary`), so you can hand-tune those and still re-import the cards. The tool copies files as they are, so shrink big photos first (about 600px wide is plenty).

Logos and images live only in the set file. The server stores just each card's id, number, name and rarity, so adding or changing logos needs **no database change** and no re-sync (re-sync only if you add, remove or rename cards).

You can also paste a CSV in the app under **Admin → Sets & settings → Import a set from CSV**. That stores the set in this browser only; use **Download set file (.js)** and drop it into `sets/` to share it with everyone. The in-app importer can't copy files from your computer, so `image`/`logo` there must be URLs or paths already in the site (it warns if a value looks like a local file); use `csv-to-set.js` for local files.

Aliases for the details column: `flavor`, `text`, `description`.

### Hand-written set file

```js
CardSets.register({
  id: "birds",
  name: "Backyard Birds",
  code: "BRD",
  description: "Optional blurb shown on the Odds page.",
  theme: { primary: "#ff7a59", secondary: "#7b2ff7" },   // pack wrapper colors
  // theme: { ..., artBackground: "#ffffff", artFit: "contain" }  // optional: photos on a white panel, never cropped
  // pack: { name: "Value Meal Pack", emblem: "🍔" }              // optional: wrapper name + icon (default ✦)
  // pack: { slots: [...] }  // optional — falls back to the default 9-card layout
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

Codes live in the database. An admin makes them under Admin → Sets & settings → Prize code generator (pick the set, packs per code, how many codes, **max uses**, optional note). A code with max uses 1 works once; with max uses 5, five different players can redeem it once each. The Admin tab lists recent codes and who redeemed them. Server codes can't be forged.

*Offline mode only* (`onlineEnabled: false` in `js/config.js`): codes are checked in the browser with `js/codes.js` (`node tools/make-codes.js --set placeholder --packs 3 --count 10`). Anyone who reads `js/codes.js` can mint those, so they're for local testing only and don't work on the live site.

## Online accounts (Supabase)

### How it works

- **Login = username + 4-digit PIN.** No email, no public sign-up: the site owner (admin) creates each account in the Admin tab and gives the friend their username and PIN. Usernames are 2–32 characters, not case-sensitive (`Alex` = `alex`), and aren't secret. PINs are stored only as **bcrypt hashes** (pgcrypto `crypt()` with a per-row salt).
- **Brute-force protection:** each failed login waits ~0.4 s+ and counts against the caller's IP (8 failures in 15 min locks that IP out for the rest of the window). Each account also locks after **5 wrong PINs in 15 minutes**: 15 minutes the first time, doubling on repeat locks up to 2 hours. A correct login or an admin **Reset PIN** clears it. Errors don't say whether the username or the PIN was wrong. All limits are in `cps.app_config` (`pin_max_failures`, `pin_window_minutes`, `pin_lock_minutes`, `pin_lock_max_minutes`, `login_max_failures`, `login_window_minutes`).
- Logging in returns a random 256-bit session token; only its SHA-256 hash is stored server-side. With **Remember me** the token sits in `localStorage` (valid 365 days); without it, in `sessionStorage`. **Log out** revokes it on the server. A PIN reset logs that account out everywhere else.
- **All data lives in a private `cps` schema** that the API doesn't expose. Every table has row-level security on with no policies, and the `anon`/`authenticated` roles have no privileges on it. The browser can only call `public.cps_*` functions (`SECURITY DEFINER`), which check the token first. Players can't list accounts; only admin tokens pass the `cps_admin_*` functions.
- **Packs are opened on the server** (`cps_open_pack`): it spends a pack, rolls the cards with the set's odds, and saves the collection and stats, so results can't be faked from the browser. The browser only animates what the server rolled.
- **Accounts-only:** nothing is playable without logging in, and the login screen can't be dismissed. If the server can't be reached, the site says "Can't reach the server right now. Please try again later." with a **Try again** button (it doesn't fall back to a local mode).
- **Trading groundwork:** `cps.card_transfers` and `cps.transfer_card()` move copies between accounts with an audit row. There's no trading UI or public RPC yet.

### Config file

`js/config.js` holds the project URL and the **publishable** key (safe to be public; it only allows calling the `cps_*` functions). `onlineEnabled: false` is a developer/offline mode (no server; collections live in the browser and the Admin tab becomes "Sets & Settings"); the automated UI tests use it. Never put the database URL, the service-role key, or any PIN in this repo.

### One-time setup (Supabase dashboard)

1. Supabase Dashboard → your project → **SQL Editor** → **New query**.
2. Paste the whole of `supabase/setup.sql` → **Run**. It's safe to run again; it creates the schema, functions (all migrations in `supabase/migrations/`) and the two bundled sets.
3. In a new query, create your admin account with your username and a 4-digit PIN:
   ```sql
   select cps.bootstrap_admin('YourName', 'Display Name', '1234');
   ```
   (Running it again for an existing username makes it admin and resets the PIN, which is also the way back in if you ever lock yourself out.) From a machine that can reach the database you can instead run `cd tools && npm install && SUPABASE_DB_URL=... node make-admin.js --username YourName --name "Display Name"` (it prints a random PIN once).
4. Open the site → log in → **Admin** tab → enter the Dev password.

**Upgrading an existing install** to PIN logins: run `supabase/migrations/002_pin.sql` in the SQL Editor (or re-run `setup.sql`), then set PINs: `select cps.bootstrap_admin('YourName', 'Display Name', '1234');` for yourself, and Admin → Reset PIN for everyone else. Accounts without a PIN can't log in until one is set.

No Auth settings, email provider, or API settings need changing. Settings live in the `cps.app_config` table (welcome packs, default set, session length, login limits), and you can edit them in the Table Editor.

### Admin tab (admin login + Dev password)

- **Create account:** display name, username ("From name" fills it in), **PIN** (type one or press **Random**), starting packs (default 3) and which set they're for, optional admin flag. Username + PIN are shown once with a **Copy both** button.
- **Accounts list:** shows each username, packs, Locked / No PIN status. Give or take packs, rename, change username (PIN and sessions stay), **Reset PIN** (also unlocks and logs them out elsewhere), disable/enable, delete.
- **Sets on the server:** Upload / Re-sync any set the site has loaded (including a CSV import), so packs for it can be opened and codes made for it.
- **Prize codes:** recent codes with uses and who redeemed them.
- **Sets & settings:** card sets, CSV import, prize code generator, sound, export, Dev tools (free pack button).

### Adding a set to the online version

Add the set to `sets/` as usual (above) and push. Then get it into the database with any one of these:
- Admin tab → **Sets on the server** → Upload.
- `cd tools && CPS_ADMIN_USERNAME=... CPS_ADMIN_PIN=... node sync-set.js birds` (uses the HTTPS API with your admin login; `--all` for every set).
- `node tools/sync-set.js birds --sql`, then paste the printed SQL into the SQL Editor.
- `node tools/build-setup-sql.js` regenerates `supabase/setup.sql` with every set in the manifest.

Card ids are stable: re-syncing updates names, rarities, odds and details without touching anyone's collection.

### Making someone else an admin

Admin tab → Create account → tick "Make this an admin account". For an existing account, run in the SQL Editor: `update cps.accounts set is_admin = true where display_name = 'Their Name';`.

## Features

- Procedural SVG placeholder art (seeded per card); real images when a card has an `image` path; optional per-card `logo`
- Rarity tiers Common → Chase, holo foils, glow / confetti for big pulls
- Pack tear animation, click-to-flip or Reveal all, WebAudio sounds (no audio files)
- Collection with owned / missing / dupe / holo filters, completion % by rarity
- Stats, odds panel, set picker, CSV importer, prize codes
- Online accounts (username + PIN) with server-side pack opening (Supabase)
- Click the pack to open + tear it in one go
- Works from `file://` (sets are `.js` modules, not JSON fetches)

## Project layout

```
index.html
css/style.css
js/           util, rarities, registry, csv, codes, storage, cardface, packs, audio, fx, devlock,
              config (Supabase URL + publishable key), cloud (API client), app
sets/         manifest.js + one .js file per set (+ optional images/)
assets/       sets/<set-id>/images|logos/ copied in by csv-to-set.js
supabase/     migrations/001_core.sql, setup.sql (migrations + bundled sets; paste into SQL Editor)
tools/        make-placeholder-set.js, csv-to-set.js, make-codes.js, example.csv,
              build-setup-sql.js, sync-set.js, make-admin.js (npm install in tools/ for the pg driver)
```

## Known limitations

- A 4-digit PIN only has 10,000 combinations. The per-IP limit and per-account lockout make guessing slow (with the defaults, a few dozen guesses a day per account), but it's game-night security, not bank security.
- The lockout can be abused: someone who knows a username can type wrong PINs to lock that account for up to 2 hours. An admin can unlock any account with Reset PIN, and the owner can always reset their own PIN in the SQL Editor (`select cps.bootstrap_admin(...)`).
- The Dev password is a client-side gate only. Real admin powers come from the admin account (checked on the server); the password just hides the tools in the browser.
- No trading UI yet (database groundwork only).
- Supabase's free tier pauses a project after a week without activity; un-pause it in the dashboard. While it's unreachable the site shows a "can't reach the server" message.
- Holo / foil is CSS-only (no WebGL). Reduced-motion preference turns particle FX off.

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

Format: `PACK-<packs>-<nonce>-<check>` (e.g. `PACK-3-K7QZ2-9XH4M`).

Each code grants packs of one specific set. The set id is baked into the code's checksum, so a code made for the Demo Mini Set only ever credits Demo Mini packs; the app tells the player which set the packs went to and switches to it.

- In the app: turn on Dev mode → Sets & Settings → Prize code generator, pick the set from the dropdown.
- From the CLI: `node tools/make-codes.js --set placeholder --packs 3 --count 10` (`--list` shows set ids). Both use the same `js/codes.js`, so codes are interchangeable.
- Codes for a set imported in one browser (CSV import) only work in browsers that have that set. Put the set file in `sets/` to make its codes work everywhere.

**Client-side only.** Anyone who reads `js/codes.js` can mint codes. Change the `SECRET` string before sharing the site. Real prize codes (unforgeable, one redeem per friend) need a server that issues codes and marks them used.

## Accounts, trading, and swapping storage later

Everything is saved per player in `localStorage` through `js/storage.js` (`CPS.Store`). Multiple players on one device are supported (handy for game night). Export / import your collection as JSON under Sets & Settings.

To add real accounts or trading later, replace `js/storage.js` with a version that talks to a server API but keeps the same method names (`listPlayers`, `loadPlayer`, `savePlayer`, `isCodeRedeemed`, `markCodeRedeemed`, `listCustomSets`, …). The rest of the app does not need to change.

## Features

- Procedural SVG placeholder art (seeded per card); real images when a card has an `image` path
- Rarity tiers Common → Chase, holo foils, glow / confetti for big pulls
- Pack tear animation, click-to-flip or Reveal all, WebAudio sounds (no audio files)
- Collection with owned / missing / dupe / holo filters, completion % by rarity
- Stats, odds panel, set picker, CSV importer, prize codes, multi-player profiles
- Works from `file://` (sets are `.js` modules, not JSON fetches)

## Project layout

```
index.html
css/style.css
js/           util, rarities, registry, csv, codes, storage, cardface, packs, audio, fx, devlock, app
sets/         manifest.js + one .js file per set (+ optional images/)
tools/        make-placeholder-set.js, csv-to-set.js, make-codes.js, example.csv
```

## Known limitations

- Prize codes are forgeable without a server (see above).
- The dev-mode password is a client-side gate only: someone determined could flip the saved setting in their browser's storage. Fine for friends, not real security.
- Collection is local to the browser; clear site data and it's gone (export first).
- No trading or accounts yet — storage module is ready to be swapped.
- Holo / foil is CSS-only (no WebGL). Reduced-motion preference turns particle FX off.

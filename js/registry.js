/* Set registry. Set files call CardSets.register({...}).
   See README "Adding a new set" for the format. */
(function (CPS) {
  var R = window.CPSRarities, U = CPS.util;

  /* Default pack layout, used by any set that doesn't define its own "pack".
     Odds are relative weights per slot (they don't need to add up to 100). */
  var DEFAULT_PACK = {
    name: 'Booster Pack',
    slots: [
      { count: 5, label: 'Common',  odds: { common: 100 } },
      { count: 2, label: 'Uncommon', odds: { uncommon: 100 } },
      { count: 1, label: 'Wild card', odds: { common: 55, uncommon: 30, rare: 12, epic: 3 } },
      { count: 1, label: 'Rare or better (guaranteed)', odds: { rare: 81.8, epic: 14, legendary: 4, chase: 0.2 } }
    ],
    // % chance that a pulled card of each rarity is a holo foil
    holo: { common: 1, uncommon: 1.5, rare: 3, epic: 5, legendary: 7.5, chase: 12.5 }
  };

  var sets = new Map();
  var order = [];
  var errors = [];

  /* If a slot asks for a rarity the set has no cards of, its weight moves to the
     nearest lower rarity that has cards (or the nearest higher one). */
  function effectiveOdds(odds, pools) {
    var out = {}, total = 0;
    Object.keys(odds || {}).forEach(function (k) {
      var key = R.normRarity(k), w = Number(odds[k]);
      if (!key || !(w > 0)) return;
      var target = pools[key].length ? key : null, i = R.INDEX[key], j;
      for (j = i - 1; !target && j >= 0; j--) if (pools[R.RARITIES[j].key].length) target = R.RARITIES[j].key;
      for (j = i + 1; !target && j < R.RARITIES.length; j++) if (pools[R.RARITIES[j].key].length) target = R.RARITIES[j].key;
      if (target) { out[target] = (out[target] || 0) + w; total += w; }
    });
    Object.keys(out).forEach(function (k) { out[k] /= total; });
    return out;
  }

  function normalize(raw, source) {
    if (!raw || typeof raw !== 'object') throw new Error('Set must be an object');
    if (!raw.id) throw new Error('Set is missing an "id"');
    if (!Array.isArray(raw.cards) || !raw.cards.length) throw new Error('Set "' + raw.id + '" has no cards');
    var id = String(raw.id).trim().toLowerCase().replace(/[^a-z0-9_-]+/g, '-');
    var total = raw.cards.length, width = Math.max(3, String(total).length);
    var seen = {};
    var cards = raw.cards.map(function (c, i) {
      var rarity = R.normRarity(c.rarity);
      if (!rarity) throw new Error('Card #' + (i + 1) + ' ("' + c.name + '") in "' + id + '" has unknown rarity "' + c.rarity + '"');
      var cid = String(c.id != null ? c.id : U.pad(i + 1, width));
      if (seen[cid]) throw new Error('Duplicate card id "' + cid + '" in "' + id + '"');
      seen[cid] = 1;
      return {
        id: cid,
        num: c.number != null ? c.number : i + 1,
        name: String(c.name != null ? c.name : 'Card ' + U.pad(i + 1, width)),
        rarity: rarity,
        subtitle: c.subtitle ? String(c.subtitle) : '',
        details: c.details != null ? String(c.details) : '',
        image: c.image ? String(c.image) : '',
        logo: c.logo ? String(c.logo) : ''
      };
    });
    var pools = {};
    R.RARITIES.forEach(function (r) { pools[r.key] = []; });
    cards.forEach(function (c) { pools[c.rarity].push(c); });
    var p = raw.pack || {};
    var slots = (p.slots || DEFAULT_PACK.slots).map(function (s) {
      return { count: Math.max(1, s.count | 0 || 1), label: s.label || '', odds: effectiveOdds(s.odds, pools) };
    }).filter(function (s) { return Object.keys(s.odds).length; });
    var holo = Object.assign({}, DEFAULT_PACK.holo, p.holo || {});
    var theme = raw.theme || {};
    return {
      id: id,
      name: String(raw.name || id),
      code: String(raw.code || id.slice(0, 3)).toUpperCase().slice(0, 6),   // 1-6 chars, e.g. PH1, FF, SPACE
      description: String(raw.description || ''),
      theme: { primary: theme.primary || '#6d5dfc', secondary: theme.secondary || '#12c2e9',
               // optional: photo art on a plain panel, e.g. product shots on white -> { artBackground: '#fff', artFit: 'contain' }
               artBackground: /^#[0-9a-f]{3,8}$/i.test(theme.artBackground || '') ? theme.artBackground : '',
               artFit: theme.artFit === 'contain' ? 'contain' : '' },
      cards: cards,
      byId: new Map(cards.map(function (c) { return [c.id, c]; })),
      pools: pools,
      numWidth: width,
      pack: { name: p.name || DEFAULT_PACK.name, emblem: p.emblem ? String(p.emblem).slice(0, 8) : '', skin: p.skin ? String(p.skin).toLowerCase().replace(/[^a-z0-9_-]+/g, '').slice(0, 24) : '', slots: slots, holo: holo,
              size: slots.reduce(function (a, s) { return a + s.count; }, 0) },
      source: source || 'file',
      raw: raw
    };
  }

  /* Per-rarity odds for the info panel. */
  function oddsTable(set) {
    return R.RARITIES.map(function (r) {
      var n = set.pools[r.key].length, pNone = 1, expected = 0, pNoneOne = 1;
      set.pack.slots.forEach(function (s) {
        var p = s.odds[r.key] || 0;
        pNone *= Math.pow(1 - p, s.count);
        expected += p * s.count;
        if (n) pNoneOne *= Math.pow(1 - p / n, s.count);
      });
      return { rarity: r, count: n, perPack: 1 - pNone, expected: expected, perCard: 1 - pNoneOne,
               holo: (set.pack.holo[r.key] || 0) / 100 };
    }).filter(function (row) { return row.count > 0; });
  }

  /* --- lazy set loading (boot diet) --------------------------------
     sets/boot-index.js (generated; see tools/build-boot-index.js)
     carries display metadata for every set. installBootIndex() plants
     metadata stubs in manifest order so every list-type surface works
     instantly; load(id) fetches the set's real file(s) on demand and
     register() swaps the stub for the real set in place. If the index
     never loads, nothing here runs and the caller falls back to the
     old load-everything boot. */
  var bootIdx = null;
  var inflight = {};

  /* --- lazy per-set CSS -------------------------------------------
     A set's stylesheet is NOT in index.html at all; the first time a
     set loads, a <link> for its sheet is injected — inserted just
     before css/surprise.css so its cascade position matches the old
     all-eager order (feature sheets carry no set-scoped selectors, so
     nothing else can tie). boot-index's per-set "css" field (generated
     by scanning the css folder) names the file, so injection never
     404s. Surfaces that draw set visuals from metadata alone (the
     Shop's booth packs) call CardSets.ensureCss(ids) instead. */
  var cssDone = {};
  function enableCss(base) {
    if (!base || cssDone[base]) return;
    cssDone[base] = true;
    var l = document.createElement('link');
    l.rel = 'stylesheet';
    l.href = 'css/' + base + '.css';
    l.setAttribute('data-setcss', base);
    var anchor = document.querySelector('link[href="css/surprise.css"]');
    if (anchor && anchor.parentNode) anchor.parentNode.insertBefore(l, anchor);
    else document.head.appendChild(l);
  }
  function cssForId(id) {
    var m = bootIdx && bootIdx.sets[id];
    return m ? m.css : '';
  }
  /* Fallback-only list (eager boot without a boot-index): mirrors the
     generator's css scan. The lazy path never uses it — boot-index's
     per-set css field is authoritative there. */
  var KNOWN_CSS = ['acrs', 'aquariums', 'beverages', 'calendar', 'candy', 'cars', 'civ', 'coasters', 'countries', 'disney', 'dogs', 'gas', 'gems', 'hero', 'hwy', 'iconic-dishes', 'indy', 'minecraft', 'motorcycles', 'natural-wonders', 'nps', 'pixar', 'playing', 'pokemon', 'skyrim', 'stage', 'stardew', 'states', 'tech', 'theme-parks', 'water', 'world-landmarks', 'world-cities', 'zelda'];

  function loadSetFile(src) {
    return new Promise(function (res) {
      var s = document.createElement('script');
      s.src = src; s.async = false;
      s.onload = function () { res(true); };
      s.onerror = function () { res(false); };
      document.head.appendChild(s);
    });
  }

  function stubFor(id, meta) {
    var pools = {};
    R.RARITIES.forEach(function (r) { pools[r.key] = []; });
    return {
      id: id, name: meta.name, code: meta.code, description: '',
      theme: { primary: meta.primary, secondary: meta.secondary, artBackground: '', artFit: '' },
      cards: [], byId: new Map(), pools: pools, numWidth: 3,
      pack: { name: meta.packName || 'Booster Pack', emblem: meta.emblem, skin: meta.skin,
              slots: [], holo: {}, size: 9 },
      source: 'stub', stub: true, total: meta.total, raw: null
    };
  }

  function installBootIndex(idx) {
    if (!idx || !idx.sets || !idx.order) return 0;
    bootIdx = idx;
    var n = 0;
    idx.order.forEach(function (id) {
      if (!sets.has(id) && idx.sets[id]) { sets.set(id, stubFor(id, idx.sets[id])); order.push(id); n++; }
    });
    return n;
  }

  function loadSet(id) {
    var cur = sets.get(id);
    if (cur && !cur.stub) return Promise.resolve(cur);
    if (!bootIdx || !bootIdx.sets[id]) return Promise.resolve(cur || null);
    if (inflight[id]) return inflight[id];
    enableCss(cssForId(id));
    var files = bootIdx.sets[id].files;
    var p = Promise.resolve(true);
    files.forEach(function (f) {
      p = p.then(function (ok) { return ok ? loadSetFile('sets/' + f) : false; });
    });
    inflight[id] = p.then(function () {
      delete inflight[id];
      var s = sets.get(id);
      return (s && !s.stub) ? s : null;
    });
    return inflight[id];
  }

  function loadIds(ids) {
    return Promise.all((ids || []).map(loadSet));
  }

  function loadAllSets() {
    return bootIdx ? loadIds(bootIdx.order.slice()) : Promise.resolve([]);
  }

  function pendingStubs() {
    var n = 0;
    order.forEach(function (id) { var s = sets.get(id); if (s && s.stub) n++; });
    return n;
  }

  window.CardSets = {
    manifest: [],
    DEFAULT_PACK: DEFAULT_PACK,
    errors: errors,
    register: function (raw, source) {
      try {
        var set = normalize(raw, source);
        sets.set(set.id, set);
        if (order.indexOf(set.id) < 0) order.push(set.id);
        return set;
      } catch (e) {
        errors.push(e.message);
        console.warn('[CardSets] set rejected:', e.message);
        return null;
      }
    },
    validate: function (raw) { return normalize(raw, 'preview'); },
    unregister: function (id) { sets.delete(id); var i = order.indexOf(id); if (i >= 0) order.splice(i, 1); },
    get: function (id) { return sets.get(id); },
    installBootIndex: installBootIndex,
    load: loadSet,
    loadIds: loadIds,
    loadAll: loadAllSets,
    ensureCss: function (ids) { (ids || []).forEach(function (id) { enableCss(cssForId(id)); }); },
    enableAllCss: function () { KNOWN_CSS.forEach(enableCss); },
    pending: pendingStubs,
    all: function () { return order.map(function (id) { return sets.get(id); }); },
    ids: function () { return order.slice(); },
    oddsTable: oddsTable
  };
})(window.CPS);

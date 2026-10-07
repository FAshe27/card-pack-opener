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
    holo: { common: 2, uncommon: 3, rare: 6, epic: 10, legendary: 15, chase: 25 }
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
        image: c.image ? String(c.image) : ''
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
      code: String(raw.code || id.slice(0, 3)).toUpperCase().slice(0, 4),
      description: String(raw.description || ''),
      theme: { primary: theme.primary || '#6d5dfc', secondary: theme.secondary || '#12c2e9' },
      cards: cards,
      byId: new Map(cards.map(function (c) { return [c.id, c]; })),
      pools: pools,
      numWidth: width,
      pack: { name: p.name || DEFAULT_PACK.name, slots: slots, holo: holo,
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
    all: function () { return order.map(function (id) { return sets.get(id); }); },
    ids: function () { return order.slice(); },
    oddsTable: oddsTable
  };
})(window.CPS);

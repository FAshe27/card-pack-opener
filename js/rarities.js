/* Rarity tiers shared by the browser app and the Node tools (UMD).
   Order matters: lowest -> highest. */
(function (root, factory) {
  var api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.CPSRarities = api;
})(typeof self !== 'undefined' ? self : this, function () {
  var RARITIES = [
    { key: 'common',    label: 'Common',    short: 'C', color: '#a3adbb' },
    { key: 'uncommon',  label: 'Uncommon',  short: 'U', color: '#38c97f' },
    { key: 'rare',      label: 'Rare',      short: 'R', color: '#3f8cff' },
    { key: 'epic',      label: 'Epic',      short: 'E', color: '#b35cff' },
    { key: 'legendary', label: 'Legendary', short: 'L', color: '#ffb21e' },
    { key: 'chase',     label: 'Chase',     short: 'X', color: '#ff4fa3' }
  ];
  // Anything on the left is accepted in set files / CSVs and mapped to the key on the right.
  var ALIASES = {
    c: 'common', common: 'common', com: 'common',
    u: 'uncommon', uncommon: 'uncommon', unc: 'uncommon',
    r: 'rare', rare: 'rare',
    e: 'epic', epic: 'epic', 'super rare': 'epic', sr: 'epic',
    l: 'legendary', leg: 'legendary', legend: 'legendary', legendary: 'legendary',
    x: 'chase', chase: 'chase', secret: 'chase', 'secret rare': 'chase', ultra: 'chase', 'ultra rare': 'chase', ur: 'chase'
  };
  var INDEX = {};
  RARITIES.forEach(function (r, i) { INDEX[r.key] = i; });
  function normRarity(v) {
    var k = String(v == null ? '' : v).trim().toLowerCase();
    return ALIASES[k] || null;
  }
  return { RARITIES: RARITIES, ALIASES: ALIASES, INDEX: INDEX, normRarity: normRarity };
});

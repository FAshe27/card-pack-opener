/* Pack generation. */
(function (CPS) {
  var U = CPS.util, R = window.CPSRarities;
  function roll(odds) {
    var x = U.rand(), acc = 0, last = null;
    for (var k in odds) { acc += odds[k]; last = k; if (x < acc) return k; }
    return last;
  }
  /* Returns [{card, holo, slot}] in slot order (the guaranteed rare+ slot is last). */
  function open(set) {
    var out = [], used = {};
    set.pack.slots.forEach(function (slot) {
      for (var i = 0; i < slot.count; i++) {
        var rarity = roll(slot.odds), pool = set.pools[rarity];
        var avail = pool.filter(function (c) { return !used[c.id]; });
        if (!avail.length) avail = pool; // tiny pools may repeat
        var card = avail[Math.floor(U.rand() * avail.length)];
        used[card.id] = 1;
        out.push({ card: card, holo: U.rand() * 100 < (set.pack.holo[rarity] || 0), slot: slot.label });
      }
    });
    return out;
  }
  function score(card, holo) { return R.INDEX[card.rarity] * 10 + (holo ? 5 : 0); }
  CPS.packs = { open: open, roll: roll, score: score };
})(window.CPS);

/* Pack helpers. Local pack generation was removed with offline mode —
   packs are rolled server-side now; only the pull scorer remains. */
(function (CPS) {
  var R = window.CPSRarities;
  function score(card, holo) { return R.INDEX[card.rarity] * 10 + (holo ? 5 : 0); }
  CPS.packs = { score: score };
})(window.CPS);

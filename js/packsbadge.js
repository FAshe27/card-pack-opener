/* Open Packs tab badge: total unopened packs across all sets (incl. Jumbled).
   Consumes CPS.appCtx (S, $) and registers as CPS.packsBadge. Called from
   renderPacksSide in app.js, which runs after every pack-count change. */
(function (CPS) {
  function update() {
    var ctx = CPS.appCtx;
    if (!ctx) return;
    var b = ctx.$('#packsBadge');
    if (!b) return;
    var n = 0, k, sets = (ctx.S.player && ctx.S.player.sets) || {};
    for (k in sets) n += sets[k].packs || 0;
    b.textContent = n;
    b.classList.toggle('hidden', !(n > 0));
  }
  CPS.packsBadge = { update: update };
})(window.CPS);

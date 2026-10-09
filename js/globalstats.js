/* Global stats box + latest big pull panel on the Stats view.
   Split out of js/app.js (which was outgrowing the push size limit).
   Uses the shared context exposed as CPS.appCtx; registers as CPS.globalStats. */
(function (CPS) {
  var C = CPS.appCtx;
  var S = C.S, $ = C.$, esc = C.esc, U = C.U, R = C.R;
  var isCloud = C.isCloud, rarityOf = C.rarityOf;

  function hide() {
    var gp = $('#globalStatsPanel'); if (gp) gp.style.display = 'none';
    var bp = $('#bigPullPanel'); if (bp) bp.style.display = 'none';
  }

  async function render() {
    var gp = $('#globalStatsPanel');
    if (!isCloud() || !gp) { hide(); return; }
    gp.style.display = '';
    try {
      var g = await CPS.cloud.call('global_pull_stats', {});
      if (S.view !== 'stats') return;
      var br = g.by_rarity || {};
      $('#globalTiles').innerHTML = [['Cards pulled', g.pulled], ['Holo pulls', g.holos]].map(function (t) {
        return '<div class="tile"><span>' + t[0] + '</span><b>' + t[1] + '</b></div>';
      }).join('');
      var gmax = Math.max.apply(null, R.RARITIES.map(function (r) { return br[r.key] || 0; }).concat([1]));
      $('#globalBars').innerHTML = R.RARITIES.map(function (r) {
        var n = br[r.key] || 0;
        return '<div class="barrow r-' + r.key + '"><span class="bl">' + r.label + '</span><span class="bar"><i style="width:' + (n / gmax * 100).toFixed(1) + '%"></i></span><span class="bn">' + n + (g.pulled ? ' <em>' + U.pct(n / g.pulled) + '</em>' : '') + '</span></div>';
      }).join('');
      var lb = g.latest_big, bp = $('#bigPullPanel');
      if (lb && bp) {
        bp.style.display = '';
        var bset = window.CardSets.get(lb.set_id), bcard = bset && bset.byId.get(lb.card_id);
        $('#bigPull').innerHTML = bcard ? CPS.cards.render(bset, bcard, {}) : '';
        $('#bigPullCap').innerHTML = '<b>' + esc(lb.player) + '</b> pulled <b class="rt-' + lb.rarity + '">' + esc(lb.card_name) + '</b>' +
          '<span>' + rarityOf(lb.rarity).label + ' · ' + esc(lb.set_name) + ' · ' + new Date(lb.pulled_at).toLocaleDateString() + '</span>';
      } else if (bp) { bp.style.display = 'none'; }
    } catch (e) { hide(); }
  }

  CPS.globalStats = { render: render };
})(window.CPS);

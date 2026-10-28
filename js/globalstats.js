/* Global stats box + latest big pull panel on the Stats view.
   Split out of js/app.js (which was outgrowing the push size limit).
   Uses the shared context exposed as CPS.appCtx; registers as CPS.globalStats. */
(function (CPS) {
  var C = CPS.appCtx;
  var S = C.S, $ = C.$, esc = C.esc, U = C.U, R = C.R;
  var isCloud = C.isCloud, rarityOf = C.rarityOf;
  var bigPullTried = {};

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
      $('#globalTiles').innerHTML = [['Cards pulled', g.pulled], ['Cards turned in', g.turned_in || 0], ['Holo pulls', g.holos], ['Sets Completed', g.sets_completed || 0]].map(function (t) {
        return '<div class="tile"><span>' + t[0] + '</span><b>' + U.fmt(t[1]) + '</b></div>';
      }).join('');
      var gnum = g.numbered || 0;
      var gmax = Math.max.apply(null, R.RARITIES.map(function (r) { return br[r.key] || 0; }).concat([gnum, 1]));
      $('#globalBars').innerHTML = R.RARITIES.map(function (r) {
        var n = br[r.key] || 0;
        return '<div class="barrow r-' + r.key + '"><span class="bl">' + r.label + '</span><span class="bar"><i style="width:' + (n / gmax * 100).toFixed(1) + '%"></i></span><span class="bn">' + U.fmt(n) + (g.pulled ? ' <em>' + U.pct(n / g.pulled) + '</em>' : '') + '</span></div>';
      }).join('') + '<div class="barrow r-numbered"><span class="bl">Numbered</span><span class="bar"><i style="width:' + (gnum / gmax * 100).toFixed(1) + '%"></i></span><span class="bn">' + U.fmt(gnum) + '</span></div>';
      var lb = g.latest_big, bp = $('#bigPullPanel');
      if (lb && bp) {
        bp.style.display = '';
        var bset = window.CardSets.get(lb.set_id), bcard = bset && bset.byId.get(lb.card_id);
        if (!bcard && bset && bset.stub && window.CardSets.load && !bigPullTried[lb.set_id]) {
          /* The face needs the set file (the caption is built from
             server fields and renders either way). Load just this set
             and repaint — this used to be masked by the Stats view's
             loadAll. One attempt per set per session. */
          bigPullTried[lb.set_id] = 1;
          window.CardSets.load(lb.set_id).then(function () { if (S.view === 'stats') render(); });
        }
        var bvar = lb.variant_tier ? { tier: lb.variant_tier, serial: lb.variant_serial } : null;
        $('#bigPull').innerHTML = bcard ? CPS.cards.render(bset, bcard, { variant: bvar }) : '';
        $('#bigPull').onclick = (bcard && C.openCardModal) ? function () { C.openCardModal(lb.set_id, lb.card_id); } : null;
        $('#bigPullCap').innerHTML = '<span class="bpc-line"><b>' + esc(lb.player) + '</b> pulled</span><b class="rt-' + lb.rarity + '">' + esc(lb.card_name) + '</b>' +
          '<span>' + rarityOf(lb.rarity).label + ' · ' + esc(lb.set_name) + ' · ' + new Date(lb.pulled_at).toLocaleDateString() + '</span>';
      } else if (bp) { bp.style.display = 'none'; }
    } catch (e) {
      var gt = $('#globalTiles'); if (gt) gt.innerHTML = '<div class="muted small">Global stats unavailable right now.</div>';
      var gb = $('#globalBars'); if (gb) gb.innerHTML = '';
      var bpx = $('#bigPullPanel'); if (bpx) bpx.style.display = 'none';
    }
  }

  CPS.globalStats = { render: render };
})(window.CPS);

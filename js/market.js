/* Market tab: Buyers (Bounty Board) / Sellers (Trading Post) toggle.
   Split out of js/app.js (which was outgrowing the push size limit).
   Uses the shared context exposed as CPS.appCtx; registers as CPS.market. */
(function (CPS) {
  var ctx = CPS.appCtx;
  function render() {
    var S = ctx.S, $ = ctx.$;
    var t = S.marketTab || 'buyers';
    var bb = $('#marketBuyersBtn'), sb = $('#marketSellersBtn');
    if (bb) bb.classList.toggle('active', t === 'buyers');
    if (sb) sb.classList.toggle('active', t === 'sellers');
    var bp = $('#bountyPanel'), tp = $('#tradingPanel');
    if (bp) bp.classList.toggle('hidden', t !== 'buyers');
    if (tp) tp.classList.toggle('hidden', t !== 'sellers');
    if (t === 'buyers' && CPS.bounties) CPS.bounties.render();
    if (t === 'sellers' && CPS.trading) CPS.trading.render();
    updateBadge();
  }
  function updateBadge() {
    var mb = ctx.$('#marketBadge'); if (!mb) return;
    var n = 0, bb = ctx.$('#bountyBadge'), tb = ctx.$('#tradeBadge');
    if (bb && !bb.classList.contains('hidden')) n += parseInt(bb.textContent, 10) || 0;
    if (tb && !tb.classList.contains('hidden')) n += parseInt(tb.textContent, 10) || 0;
    mb.textContent = n;
    mb.classList.toggle('hidden', !(n > 0));
  }
  function init() {
    var S = ctx.S;
    var bb = ctx.$('#marketBuyersBtn'), sb = ctx.$('#marketSellersBtn');
    if (bb) bb.addEventListener('click', function () { S.marketTab = 'buyers'; render(); });
    if (sb) sb.addEventListener('click', function () { S.marketTab = 'sellers'; render(); });
    var obs = new MutationObserver(function () { updateBadge(); });
    ['bountyBadge', 'tradeBadge'].forEach(function (id) {
      var el = document.getElementById(id);
      if (el) obs.observe(el, { childList: true, attributes: true, attributeFilter: ['class'] });
    });
  }
  CPS.market = { render: render, init: init, updateBadge: updateBadge };
})(window.CPS);

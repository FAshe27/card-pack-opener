/* All-sets collection view: combined grid across every set.
   Split out of js/app.js (which was outgrowing the push size limit).
   Uses the shared context exposed as CPS.appCtx; registers as CPS.allsets. */
(function (CPS) {
  var ctx = CPS.appCtx;
  function render() {
    var S = ctx.S, st = ctx.ps(), f = S.coll, $ = ctx.$, esc = ctx.esc, R = ctx.R;
    var sets = window.CardSets.all().filter(function (s) { return s.id !== 'jumbled'; });
    var total = 0, owned = 0, copies = 0, holoU = 0;
    sets.forEach(function (s) {
      total += s.cards.length;
      s.cards.forEach(function (c) { var e = st.cards[c.id]; if (e && e.n > 0) { owned++; copies += e.n; if (e.h) holoU++; } });
    });
    var pct = total ? owned / total : 0;
    $('#compRing').style.setProperty('--p', (pct * 100).toFixed(1));
    $('#compPct').textContent = (pct * 100 >= 99.95 || pct === 0 ? Math.round(pct * 100) : (pct * 100).toFixed(1)) + '%';
    $('#compTitle').textContent = 'All Sets';
    $('#compSub').textContent = owned + ' / ' + total + ' unique cards · ' + copies + ' total copies · ' + holoU + ' holo';
    $('#rarityProgress').innerHTML = '';
    var sel = $('#collRarity');
    sel.innerHTML = '<option value="">All rarities</option>' + R.RARITIES.map(function (r) { return '<option value="' + r.key + '">' + r.label + '</option>'; }).join('');
    sel.value = f.rarity;
    var q = f.q.trim().toLowerCase();
    var list = [];
    sets.forEach(function (s) {
      s.cards.forEach(function (c) {
        var e = st.cards[c.id], has = e && e.n > 0;
        if (f.rarity && c.rarity !== f.rarity) return;
        if (f.own === 'owned' && !has) return;
        if (f.own === 'missing' && has) return;
        if (f.own === 'dupes' && !(e && e.n > 1)) return;
        if (f.own === 'holo' && !(e && e.h > 0)) return;
        if (f.own === 'fav' && !ctx.isFav(s.id, c.id)) return;
        if (f.own === 'numbered') {
          var hasV = (S.myVariants || []).some(function (v) { return v.set_id === s.id && v.card_id === c.id; });
          if (!hasV) return;
        }
        if (q) {
          var hay = c.name + ' ' + c.subtitle + ' ' + c.details + ' #' + c.num + ' ' + c.rarity + ' ' + s.name;
          if (hay.toLowerCase().indexOf(q) < 0) return;
        }
        list.push({ set: s, card: c });
      });
    });
    var cnt = function (x) { var e = st.cards[x.card.id]; return e ? e.n : 0; };
    if (f.sort === 'rarity') list.sort(function (a, b) { return R.INDEX[b.card.rarity] - R.INDEX[a.card.rarity] || a.card.num - b.card.num; });
    else if (f.sort === 'count') list.sort(function (a, b) { return cnt(b) - cnt(a) || a.card.num - b.card.num; });
    else if (f.sort === 'name') list.sort(function (a, b) { return a.card.name.localeCompare(b.card.name, undefined, { numeric: true }); });
    else list.sort(function (a, b) { return a.set.name.localeCompare(b.set.name) || a.card.num - b.card.num; });
    if (q) list.sort(function (a, b) { return (cnt(a) > 0 ? 0 : 1) - (cnt(b) > 0 ? 0 : 1); });
    $('#collCount').textContent = list.length + ' shown';
    $('#collGrid').innerHTML = list.length ? list.map(function (x) {
      var e = st.cards[x.card.id];
      return '<div class="coll-item allsets-item" data-set="' + esc(x.set.id) + '" data-card="' + esc(x.card.id) + '">' +
        CPS.cards.collected(x.set, x.card, e ? e.n : 0, e ? e.h : 0) +
        '<div class="allsets-setname muted small">' + esc(x.set.name) + '</div></div>';
    }).join('') : '<div class="empty">No cards match these filters.</div>';
    $('#collGrid').querySelectorAll('.allsets-item').forEach(function (el) {
      el.addEventListener('click', function () { ctx.openCardModal(el.dataset.set, el.dataset.card); });
    });
    renderVariants();
  }
  async function renderVariants() {
    var ctx2 = CPS.appCtx, S = ctx2.S;
    var panel = $('#variantsPanel'), grid = $('#variantsGrid');
    if (!ctx2.isCloud()) { panel.classList.add('hidden'); return; }
    var all = await ctx2.ensureVariants();
    if (!S.coll.allSets) return;
    if (!all.length) { panel.classList.add('hidden'); return; }
    panel.classList.remove('hidden');
    $('#variantsCount').textContent = all.length + ' numbered ' + (all.length === 1 ? 'card' : 'cards');
    grid.innerHTML = all.map(function (v) {
      var s = window.CardSets.get(v.set_id); if (!s) return '';
      var card = s.byId.get(v.card_id); if (!card) return '';
      return '<div class="coll-item" data-vset="' + ctx2.esc(v.set_id) + '" data-variant-card="' + ctx2.esc(v.card_id) + '" data-tier="' + ctx2.esc(v.tier) + '" data-serial="' + v.serial + '">' +
        CPS.cards.render(s, card, { variant: { tier: v.tier, serial: v.serial } }) +
        '<div class="vserial-cap"><b>' + ctx2.esc(CPS.cards.VARIANTS[v.tier].name) + ' #' + v.serial + '/' + CPS.cards.VARIANTS[v.tier].run + '</b><div class="muted small">' + ctx2.esc(s.name) + '</div></div></div>';
    }).join('');
    grid.querySelectorAll('[data-variant-card]').forEach(function (el) {
      el.addEventListener('click', function () {
        ctx2.openCardModal(el.dataset.vset, el.dataset.variantCard, null, { tier: el.dataset.tier, serial: parseInt(el.dataset.serial, 10) });
      });
    });
  }
  CPS.allsets = { render: render };
})(window.CPS);

/* Cross-set dupe trade-in for spin tickets.
   Split out of js/app.js (which was outgrowing the push size limit).
   Uses the shared context exposed as CPS.appCtx; registers as CPS.tickets. */
(function (CPS) {
  var C = CPS.appCtx;
  var S = C.S, $ = C.$, esc = C.esc, audio = C.audio;
  var isCloud = C.isCloud, save = C.save, toast = C.toast, cloudError = C.cloudError;
  var refreshCloud = C.refreshCloud, renderCollection = C.renderCollection;
  var renderPacksSide = C.renderPacksSide, updateWheelGlow = C.updateWheelGlow;
  var refreshQuests = C.refreshQuests, dupeCounts = C.dupeCounts;
  var DUPE_RARS = C.DUPE_RARS, variantCountMap = C.variantCountMap;

  var DUPE_TICKET_TIERS = [
    { tier: 'common', rate: 20, label: 'Common' },
    { tier: 'uncommon', rate: 12, label: 'Uncommon' },
    { tier: 'rare', rate: 6, label: 'Rare' },
    { tier: 'epic', rate: 4, label: 'Epic+' }
  ];

  /* Tradable dupes pooled across all sets. Numbered variant copies are never tradable. */
  function ticketDupeCounts() {
    var out = { common: 0, uncommon: 0, rare: 0, epic: 0 };
    var vmap = isCloud() ? variantCountMap() : null;
    window.CardSets.all().forEach(function (set) {
      var st = S.player.sets[set.id];
      if (!st) return;
      var c = dupeCounts(set, st, vmap);
      out.common += c.common; out.uncommon += c.uncommon; out.rare += c.rare; out.epic += c.epic;
    });
    return out;
  }

  function renderTicketTradein() {
    var el = $('#ticketRows');
    if (!el) return;
    var counts = ticketDupeCounts();
    el.innerHTML = DUPE_TICKET_TIERS.map(function (t) {
      var n = counts[t.tier], tickets = Math.floor(n / t.rate);
      return '<div class="tradein-row">' +
        '<span class="pill r-' + (t.tier === 'epic' ? 'epic' : t.tier) + '">' + t.label + '</span>' +
        '<span class="tradein-mid"><b>' + n + '</b><span class="muted">/' + t.rate + '</span> dupes <span class="muted">&rarr;</span> <b>' + tickets + '</b> ticket' + (tickets === 1 ? '' : 's') + '</span>' +
        '<button class="btn small" data-ticket-trade="' + t.tier + '"' + (tickets < 1 ? ' disabled' : '') + '>Trade</button>' +
        '</div>';
    }).join('');
  }

  async function tradeDupesTickets(tier) {
    var t = null;
    DUPE_TICKET_TIERS.forEach(function (x) { if (x.tier === tier) t = x; });
    if (!t) return;
    if (isCloud()) {
      try {
        var r = await CPS.cloud.call('trade_dupes_tickets', { p_tier: tier });
        toast('Traded ' + r.dupes_used + ' dupes for ' + r.tickets + ' spin ticket' + (r.tickets === 1 ? '' : 's') + '!', 'good');
        audio.coin();
        S.spins = r.spins_now; updateWheelGlow();
        await refreshCloud();
      } catch (e) { cloudError(e); }
      return;
    }
    /* Guest mode: deduct across sets, most dupes first. Guests have no numbered variants. */
    var counts = ticketDupeCounts(), tickets = Math.floor(counts[tier] / t.rate);
    if (tickets < 1) { toast('Not enough duplicate cards.', 'warn'); return; }
    var need = tickets * t.rate, rars = DUPE_RARS[tier];
    window.CardSets.all().slice().sort(function (a, b) {
      var sa = S.player.sets[a.id], sb = S.player.sets[b.id];
      return (sb ? dupeCounts(b, sb)[tier] : 0) - (sa ? dupeCounts(a, sa)[tier] : 0);
    }).forEach(function (set) {
      if (need <= 0) return;
      var st = S.player.sets[set.id];
      if (!st) return;
      set.cards.forEach(function (c) {
        if (need <= 0 || rars.indexOf(c.rarity) < 0) return;
        var e = st.cards[c.id];
        if (!e || e.n <= 1) return;
        var h = e.h || 0, takeNh, takeH;
        if (h > 0) takeNh = Math.min(e.n - h, need);
        else takeNh = Math.min(Math.max(e.n - 1, 0), need);
        need -= takeNh;
        takeH = h > 0 ? Math.min(h - 1, need) : 0;
        need -= takeH;
        e.n -= (takeNh + takeH);
        e.h = h - takeH;
        if (e.n <= 0) delete st.cards[c.id];
      });
    });
    S.player.spins = (S.player.spins || 0) + tickets;
    await save();
    toast('Traded ' + (tickets * t.rate) + ' dupes for ' + tickets + ' spin ticket' + (tickets === 1 ? '' : 's') + '!', 'good');
    audio.coin();
    updateWheelGlow();
    refreshQuests();
    renderCollection();
    renderPacksSide();
  }

  $('#ticketRows').addEventListener('click', function (e) {
    var b = e.target.closest('[data-ticket-trade]');
    if (b && !b.disabled) tradeDupesTickets(b.dataset.ticketTrade);
  });

  CPS.tickets = { render: renderTicketTradein, trade: tradeDupesTickets, counts: ticketDupeCounts };
})(window.CPS);

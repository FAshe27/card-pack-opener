/* Shop tab (Sandbox): rotating pack stock for Store Credit.
   3 slots, restock every 12h at midnight/noon America/Chicago.
   Slot 1&2: $5 unlimited. Slot 3: $2, max 3/player/cycle. */
(function (CPS) {
  var ctx = CPS.appCtx;
  var S, timer = null;

  function $(s, r) { return (r || document).querySelector(s); }
  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }

  function fmtTime(sec) {
    var h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
    return (h < 10 ? '0' : '') + h + ':' + (m < 10 ? '0' : '') + m + ':' + (s < 10 ? '0' : '') + s;
  }

  async function load() {
    try {
      var r = await CPS.cloud.call('shop_status', {});
      return r;
    } catch (e) { ctx.cloudError(e); return null; }
  }

  function setName(id) {
    var s = window.CardSets.get(id);
    return s ? s.name : id;
  }
  function packVisual(setId) {
    var s = window.CardSets.get(setId);
    if (!s || !CPS.cards.pack) return '<div class="shop-pack"><span>' + esc(setId) + '</span></div>';
    return '<div class="shop-pack-wrap">' + CPS.cards.pack(s, '') + '</div>';
  }

  async function render(el) {
    S = ctx.S;
    el.innerHTML = '<div class="panel"><p class="muted">Loading shop…</p></div>';
    var data = await load();
    if (!data) { el.innerHTML = '<div class="panel"><p class="muted">Shop unavailable.</p></div>'; return; }
    draw(el, data);
    renderDupeSell(el);
    // countdown timer
    var secs = data.seconds_to_restock;
    var cdEl = $('#shopCountdown', el);
    if (timer) clearInterval(timer);
    timer = setInterval(function () {
      secs = Math.max(0, secs - 1);
      if (cdEl) cdEl.textContent = fmtTime(secs);
      if (secs <= 0) { clearInterval(timer); render(el); } // auto-refresh on restock
    }, 1000);
  }

  function draw(el, data) {
    var slots = data.slots.map(function (sl) {
      var remaining = sl.limit == null ? null : Math.max(0, sl.limit - sl.bought);
      var canBuy = data.store_credit >= sl.price && (remaining == null || remaining > 0);
      var isTicket = sl.kind === 'ticket';
      var visual = isTicket ? '<div class="shop-ticket"><div class="shop-ticket-icon">\uD83C\uDFAB</div><div class="muted small">Spin Ticket</div></div>'
        : sl.mystery ? '<div class="shop-mystery"><div class="shop-mystery-q">?</div><div class="muted small">Mystery Pack</div></div>' : packVisual(sl.set_id);
      var name = isTicket ? '<b>Spin Ticket</b>' : sl.mystery ? '<b>???</b>' : '<b>' + esc(setName(sl.set_id)) + '</b>';
      var tag = sl.slot === 3 ? '<div class="shop-deal-tag">DEAL</div>' : (sl.mystery ? '<div class="shop-deal-tag mystery">MYSTERY</div>' : (isTicket ? '<div class="shop-deal-tag ticket">WHEEL</div>' : ''));
      return '<div class="shop-booth">' + tag + visual +
        '<div class="shop-info">' +
        '<div class="shop-packname">' + name + '</div>' +
        '<div class="shop-price">💵 $' + sl.price + '</div>' +
        '<div class="muted small shop-left">' + (remaining != null ? remaining + ' of ' + sl.limit + ' left' : '&nbsp;') + '</div>' +
        '<button class="btn primary" data-buyslot="' + sl.slot + '"' + (canBuy ? '' : ' disabled') + '>Buy</button>' +
        '</div></div>';
    }).join('');

    el.innerHTML =
      '<div class="panel shop-head">' +
      '<div class="shop-title-row"><h2>🏪 Shop</h2>' +
      '<div class="shop-balance" id="shopBalance">💵 <b>$' + data.store_credit + '</b></div></div>' +
      '<div class="shop-restock muted small">New stock in <b id="shopCountdown">' + fmtTime(data.seconds_to_restock) + '</b></div>' +
      '</div>' +
      '<div class="shop-grid">' + slots + '</div>' +
      '<div class="panel" id="shopDupeSell"></div>' +

'';



    el.querySelectorAll('[data-buyslot]').forEach(function (btn) {
      btn.addEventListener('click', async function () {
        var slotNum = parseInt(btn.getAttribute('data-buyslot'), 10);
        btn.disabled = true;
        try {
          var r = await CPS.cloud.call('shop_buy', { p_slot: slotNum });
          var msg = 'Pack purchased! Check your packs.';
          if (r.kind === 'ticket') {
            msg = '\uD83C\uDFAB Spin Ticket purchased!';
            if (r.spins_now != null && S && S.player) {
              S.player.spins = r.spins_now;
              if (ctx.updateWheelBadge) ctx.updateWheelBadge();
            }
          }
          if (r.revealed_set) msg = '🎁 Mystery revealed: ' + setName(r.revealed_set) + '! Check your packs.';
          ctx.toast(msg, 'good');
          ctx.audio.coin();
          // in-place update: no full re-render, timer keeps running
          data.store_credit = r.store_credit;
          var sl = data.slots[slotNum - 1];
          sl.bought = (sl.bought || 0) + 1;
          var booth = btn.closest('.shop-booth');
          var balEl = $('#shopBalance', el);
          if (balEl) balEl.innerHTML = '💵 <b>$' + data.store_credit + '</b>';
          var leftEl = $('.shop-left', booth);
          if (sl.limit != null) {
            var remaining = Math.max(0, sl.limit - sl.bought);
            if (leftEl) leftEl.textContent = remaining + ' of ' + sl.limit + ' left';
            if (remaining <= 0) btn.disabled = true;
            else btn.disabled = data.store_credit < sl.price;
          } else {
            btn.disabled = data.store_credit < sl.price;
          }
          // Update local pack inventory so Open Packs + set dropdown reflect the purchase
          // without a full refresh (which would restart the shop timer).
          if (r.set_id != null && r.packs_now != null && ctx.S && ctx.S.sets) {
            var st = ctx.S.sets[r.set_id];
            if (!st) {
              // Set not in local state yet (e.g. first pack of a set) — create the entry
              st = ctx.S.sets[r.set_id] = { packs: 0, cards: {}, recent: [], stats: { opened: 0, pulled: 0, holos: 0, byRarity: {}, best: null } };
            }
            st.packs = r.packs_now;
            if (ctx.renderPacksSide) ctx.renderPacksSide();
          }
          // Note: no refreshCloud() here — in-place update above is sufficient.
          // refreshCloud() would re-render the shop and restart the timer.
        } catch (e) { btn.disabled = false; ctx.cloudError(e); }
      });
    });
  }

  var DUPE_CREDIT_TIERS = [
    { tier: 'common', rate: 20, label: 'Common' },
    { tier: 'uncommon', rate: 12, label: 'Uncommon' },
    { tier: 'rare', rate: 6, label: 'Rare' },
    { tier: 'epic', rate: 4, label: 'Epic+' }
  ];

  function dupeCounts() {
    // pooled across all sets, mirrors CPS.tickets.ticketDupeCounts
    var out = { common: 0, uncommon: 0, rare: 0, epic: 0 };
    if (!ctx.S || !ctx.S.player) return out;
    var vmap = null;
    try { vmap = ctx.variantCountMap ? ctx.variantCountMap() : null; } catch (e) {}
    window.CardSets.all().forEach(function (set) {
      var st = ctx.S.player.sets[set.id];
      if (!st || !ctx.dupeCounts) return;
      var c = ctx.dupeCounts(set, st, vmap);
      out.common += c.common || 0; out.uncommon += c.uncommon || 0;
      out.rare += c.rare || 0; out.epic += c.epic || 0;
    });
    return out;
  }

  function renderDupeSell(el) {
    var counts = dupeCounts();
    var rows = DUPE_CREDIT_TIERS.map(function (t) {
      var n = counts[t.tier], credit = Math.floor(n / t.rate);
      return '<div class="tradein-row">' +
        '<span class="pill r-' + (t.tier === 'epic' ? 'epic' : t.tier) + '">' + t.label + '</span>' +
        '<span class="tradein-mid"><b>' + n + '</b><span class="muted">/' + t.rate + '</span> dupes <span class="muted">&rarr;</span> <b>$' + credit + '</b></span>' +
        '<button class="btn small" data-dupe-sell="' + t.tier + '"' + (credit < 1 ? ' disabled' : '') + '>Sell</button>' +
        '</div>';
    }).join('');
    var box = $('#shopDupeSell', el);
    if (box) {
      box.innerHTML = '<h3>💰 Sell your dupes to the shop</h3>' +
        '<p class="muted small">Trade duplicate cards for Store Credit. Rates are the same across all sets.</p>' +
        '<div class="tradein-rows">' + rows + '</div>';
      box.querySelectorAll('[data-dupe-sell]').forEach(function (btn) {
        btn.addEventListener('click', async function () {
          btn.disabled = true;
          try {
            var r = await CPS.cloud.call('trade_dupes_credit', { p_tier: btn.getAttribute('data-dupe-sell') });
            ctx.toast('Sold ' + r.dupes_used + ' dupes for $' + r.credit + ' Store Credit!', 'good');
            ctx.audio.coin();
            var balEl = document.getElementById('shopBalance');
            if (balEl) balEl.innerHTML = '💵 <b>$' + r.credit_now + '</b>';
            renderDupeSell(el);
          } catch (e) { btn.disabled = false; ctx.cloudError(e); }
        });
      });
    }
  }

  function teardown() {
    if (timer) { clearInterval(timer); timer = null; }
  }

  CPS.shop = { render: render, teardown: teardown };
})(window.CPS);

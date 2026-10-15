/* Shop tab (Sandbox): rotating pack stock for Store Credit.
   3 slots, restock every 12h at midnight/noon America/Chicago.
   Slot 1&2: $5 unlimited. Slot 3: $2, max 3/player/cycle. */
(function (CPS) {
  var ctx = CPS.appCtx;
  var S, timer = null;
  var lastHTML = null, lastFor = null; // last fully-drawn shop frame (seamless refresh)

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
    // A refresh re-enters here after the stage was emptied: stubbing the
    // panel with a short "Loading" box collapses the page and the browser
    // dumps the reader back at the top. Keep the last drawn frame on
    // screen while fresh data loads (its buttons are inert), then hand
    // the reader their scroll position back.
    var y = window.scrollY || 0;
    var acct = S && S.player && S.player.id;
    if (lastHTML && lastFor === acct) el.innerHTML = lastHTML;
    else el.innerHTML = '<div class="panel"><p class="muted">Loading shop…</p></div>';
    var data = await load();
    if (!data) { el.innerHTML = '<div class="panel"><p class="muted">Shop unavailable.</p></div>'; return; }
    draw(el, data);
    renderDupeSell(el);
    lastHTML = el.innerHTML; lastFor = acct;
    var sec = el.closest ? el.closest('section.view') : null;
    if (!sec || sec.classList.contains('active')) window.scrollTo(0, y);
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
      var isToken = sl.kind === 'token';
      var visual = isTicket ? '<div class="shop-ticket"><div class="shop-ticket-icon">\uD83C\uDFAB</div><div class="muted small">Spin Ticket</div></div>'
        : isToken ? '<div class="shop-ticket"><div class="shop-ticket-icon">\uD83E\uDE99</div><div class="muted small">Arcade Token</div></div>'
        : sl.mystery ? '<div class="shop-mystery"><div class="shop-mystery-q">?</div><div class="muted small">Mystery Pack</div></div>' : packVisual(sl.set_id);
      var name = isTicket ? '<b>Spin Ticket</b>' : isToken ? '<b>Arcade Token</b>' : sl.mystery ? '<b>???</b>' : '<b>' + esc(setName(sl.set_id)) + '</b>';
      var tag = sl.slot === 3 ? '<div class="shop-deal-tag">DEAL</div>' : (sl.mystery ? '<div class="shop-deal-tag mystery">MYSTERY</div>' : (isTicket ? '<div class="shop-deal-tag ticket">WHEEL</div>' : (isToken ? '<div class="shop-deal-tag ticket">ARCADE</div>' : '')));
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
            if (r.spins_now != null && S) {
              // Cloud mode reads S.spins (spinsAvail); S.player.spins is the local-mode field.
              S.spins = r.spins_now;
              if (S.player) S.player.spins = r.spins_now;
              if (ctx.updateWheelBadge) ctx.updateWheelBadge();
            }
          }
          if (r.kind === 'token') {
            msg = '\uD83E\uDE99 Arcade Token purchased!';
            if (r.tokens_now != null && S) {
              S.gameTokens = r.tokens_now;
              if (CPS.games && CPS.games.updateBadge) CPS.games.updateBadge();
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
          if (r.set_id != null && r.packs_now != null && ctx.S && ctx.S.player && ctx.S.player.sets) {
            var st = ctx.S.player.sets[r.set_id];
            if (!st) {
              // Set not in local state yet (e.g. first pack of a set) — create the entry
              st = ctx.S.player.sets[r.set_id] = { packs: 0, cards: {}, recent: [], stats: { opened: 0, pulled: 0, holos: 0, byRarity: {}, best: null } };
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
    { tier: 'common', rate: 20, dollars: 1, label: 'Common' },
    { tier: 'uncommon', rate: 12, dollars: 1, label: 'Uncommon' },
    { tier: 'rare', rate: 6, dollars: 1, label: 'Rare' },
    { tier: 'epic', rate: 4, dollars: 1, label: 'Epic' },
    { tier: 'legendary', rate: 2, dollars: 1, label: 'Legendary' },
    { tier: 'chase', rate: 1, dollars: 2, label: 'Chase' }
  ];

  function dupeCounts() {
    // Pooled across all sets, bucketed by each card's OWN rarity: the
    // Shop sells every tier separately (migration 142), while app.js's
    // ctx.dupeCounts pools epic+legendary+chase for the ticket trade.
    // Per-card formula mirrors app.js exactly: dupes =
    // max(0, (copies - vaulted) - max(1, unvaulted variants)).
    var out = { common: 0, uncommon: 0, rare: 0, epic: 0, legendary: 0, chase: 0 };
    if (!ctx.S || !ctx.S.player) return out;
    var vmap = null;
    try { vmap = ctx.variantCountMap ? ctx.variantCountMap() : null; } catch (e) {}
    window.CardSets.all().forEach(function (set) {
      var st = ctx.S.player.sets[set.id];
      if (!st || !st.cards) return;
      set.cards.forEach(function (c) {
        if (out[c.rarity] == null) return;
        var e = st.cards[c.id];
        if (!e || !e.n) return;
        var v = vmap ? (vmap[set.id + ':' + c.id] || 0) : 0;
        out[c.rarity] += Math.max(0, (e.n - (e.v || 0)) - Math.max(1, v));
      });
    });
    return out;
  }

  function dupeNotTurnedCounts() {
    // Per-tier dupes that belong to cards NOT yet turned in (for the sell
    // confirm's heads-up). Mirrors ctx.dupeCounts' per-card formula in
    // app.js exactly — keep the two in sync: dupes per card =
    // max(0, (copies - vaulted) - max(1, unvaulted variants)).
    var out = { common: 0, uncommon: 0, rare: 0, epic: 0, legendary: 0, chase: 0 };
    if (!ctx.S || !ctx.S.player || !ctx.isTurned) return out;
    var vmap = null;
    try { vmap = ctx.variantCountMap ? ctx.variantCountMap() : null; } catch (e) {}
    window.CardSets.all().forEach(function (set) {
      var st = ctx.S.player.sets[set.id];
      if (!st || !st.cards) return;
      set.cards.forEach(function (c) {
        if (ctx.isTurned(set.id, c.id)) return;
        var e = st.cards[c.id];
        if (!e || !e.n) return;
        var t = c.rarity;
        if (out[t] == null) return;
        var v = vmap ? (vmap[set.id + ':' + c.id] || 0) : 0;
        out[t] += Math.max(0, (e.n - (e.v || 0)) - Math.max(1, v));
      });
    });
    return out;
  }

  function renderDupeSell(el) {
    var counts = dupeCounts();
    var rows = DUPE_CREDIT_TIERS.map(function (t) {
      var n = counts[t.tier], credit = Math.floor(n / t.rate) * t.dollars;
      return '<div class="tradein-row">' +
        '<span class="pill r-' + (t.tier === 'epic' ? 'epic' : t.tier) + '">' + t.label + '</span>' +
        '<span class="tradein-mid"><b>' + n + '</b><span class="muted">/' + t.rate + '</span> dupes <span class="muted">&rarr;</span> <b>$' + credit + '</b></span>' +
        '<button class="btn small" data-dupe-sell="' + t.tier + '"' + (credit < 1 ? ' disabled' : '') + '>Sell</button>' +
        '</div>';
    }).join('');
    var box = $('#shopDupeSell', el);
    if (box) {
      box.innerHTML = '<h3>💰 Sell your dupes to the shop</h3>' +
        '<p class="muted small">Sell full batches of duplicates for Store Credit: 20 Commons = $1 \u00b7 12 Uncommons = $1 \u00b7 6 Rares = $1 \u00b7 4 Epics = $1 \u00b7 2 Legendaries = $1 \u00b7 1 Chase = $2. The counter shows dupes you have / dupes per batch.</p>' +
        '<div class="tradein-rows">' + rows + '</div>';
      box.querySelectorAll('[data-dupe-sell]').forEach(function (btn) {
        btn.addEventListener('click', async function () {
          var tier = btn.getAttribute('data-dupe-sell');
          var t = null; DUPE_CREDIT_TIERS.forEach(function (x) { if (x.tier === tier) t = x; });
          var n = dupeCounts()[tier] || 0, batches = t ? Math.floor(n / t.rate) : 0, credit = t ? batches * t.dollars : 0;
          if (!t || batches < 1) return;
          btn.disabled = true;
          var nt = dupeNotTurnedCounts()[tier] || 0;
          var ntLine = nt > 0
            ? '<p style="color:#ffd97a">⚠️ <b>' + nt + '</b> of your ' + n + ' ' + t.label + ' duplicates are copies of cards you haven\'t turned in yet.</p>'
            : '<p class="muted">All of these cards have already been turned in.</p>';
          var ok = await ctx.confirmDialog('Sell duplicates?',
            '<p>Sell <b>' + (batches * t.rate) + ' ' + t.label + '</b> duplicate' + (batches * t.rate === 1 ? '' : 's') + ' for <b>$' + credit + ' Store Credit</b>?</p>' +
            ntLine +
            '<p class="muted">The cards are removed from your collection. <b>There is no undo.</b> Numbered and vaulted copies are never sold.</p>',
            'Sell them');
          if (!ok) { btn.disabled = false; return; }
          try {
            var r = await CPS.cloud.call('trade_dupes_credit', { p_tier: tier });
            ctx.toast('Sold ' + r.dupes_used + ' dupes for $' + r.credit + ' Store Credit!', 'good');
            ctx.audio.coin();
            var balEl = document.getElementById('shopBalance');
            if (balEl) balEl.innerHTML = '💵 <b>$' + r.credit_now + '</b>';
            // The sale removed cards server-side, but dupeCounts() reads the
            // LOCAL collection (ctx.S) — re-rendering alone shows the same
            // stale counts and a re-enabled Sell button. Pull fresh state:
            // refreshCloud() reloads get_state, then re-renders the Shop with
            // the real remaining dupes (and refreshes the dupe_trade quest).
            // refreshCloud re-renders the whole shop: save the scroll
            // position first (the re-render's own restore can read it
            // after the browser has already clamped the collapsed page)
            // and put it back once the fresh shop is on screen.
            var sy = window.scrollY || 0;
            if (ctx.refreshCloud) await ctx.refreshCloud();
            else renderDupeSell(el);
            window.scrollTo(0, sy);
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

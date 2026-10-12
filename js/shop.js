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
      var visual = sl.mystery ? '<div class="shop-mystery"><div class="shop-mystery-q">?</div><div class="muted small">Mystery Pack</div></div>' : packVisual(sl.set_id);
      var name = sl.mystery ? '<b>???</b>' : '<b>' + esc(setName(sl.set_id)) + '</b>';
      var tag = sl.slot === 3 ? '<div class="shop-deal-tag">DEAL</div>' : (sl.mystery ? '<div class="shop-deal-tag mystery">MYSTERY</div>' : '');
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
      '<div class="shop-restock muted small">Next restock in <b id="shopCountdown">' + fmtTime(data.seconds_to_restock) + '</b></div>' +
      '</div>' +
      '<div class="shop-grid">' + slots + '</div>' +

'';



    el.querySelectorAll('[data-buyslot]').forEach(function (btn) {
      btn.addEventListener('click', async function () {
        var slotNum = parseInt(btn.getAttribute('data-buyslot'), 10);
        btn.disabled = true;
        try {
          var r = await CPS.cloud.call('shop_buy', { p_slot: slotNum });
          var msg = 'Pack purchased! Check your packs.';
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

          await ctx.refreshCloud();
        } catch (e) { btn.disabled = false; ctx.cloudError(e); }
      });
    });
  }

  function teardown() {
    if (timer) { clearInterval(timer); timer = null; }
  }

  CPS.shop = { render: render, teardown: teardown };
})(window.CPS);

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
    if (!s) return '<div class="shop-pack"><span>' + esc(setId) + '</span></div>';
    var t = s.theme || {};
    var style = 'background:linear-gradient(135deg,' + (t.primary || '#333') + ',' + (t.secondary || '#111') + ');';
    return '<div class="shop-pack" style="' + style + '">' +
      '<div class="shop-pack-code">' + esc(s.code || setId) + '</div>' +
      '<div class="shop-pack-name">' + esc(s.name) + '</div>' +
      '<div class="shop-pack-sub">9 cards</div>' +
      '</div>';
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
      return '<div class="shop-booth">' +
        (sl.slot === 3 ? '<div class="shop-deal-tag">DEAL</div>' : '') +
        packVisual(sl.set_id) +
        '<div class="shop-info">' +
        '<div class="shop-packname"><b>' + esc(setName(sl.set_id)) + '</b></div>' +
        '<div class="shop-price">💵 $' + sl.price + '</div>' +
        (remaining != null ? '<div class="muted small">' + remaining + ' of ' + sl.limit + ' left</div>' : '') +
        '<button class="btn primary" data-buyslot="' + sl.slot + '"' + (canBuy ? '' : ' disabled') + '>Buy</button>' +
        '</div></div>';
    }).join('');

    var hist = (data.history || []).map(function (h) {
      return '<div class="shop-hist-row"><span>Slot ' + h.slot + ' · ' + esc(setName(h.set_id)) + '</span>' +
        '<span class="muted small">💵 $' + h.price + ' · ' + new Date(h.purchased_at).toLocaleString() + '</span></div>';
    }).join('') || '<p class="muted small">No purchases yet.</p>';

    el.innerHTML =
      '<div class="panel shop-head">' +
      '<h2>🏪 Shop</h2>' +
      '<div class="shop-balance">💵 <b>$' + data.store_credit + '</b> <span class="muted small">Store Credit</span></div>' +
      '<div class="muted small">Next restock in <b id="shopCountdown">' + fmtTime(data.seconds_to_restock) + '</b></div>' +
      '</div>' +
      '<div class="shop-grid">' + slots + '</div>' +
      '<div class="panel"><h3>Purchase history</h3><div class="shop-hist">' + hist + '</div></div>';

    el.querySelectorAll('[data-buyslot]').forEach(function (btn) {
      btn.addEventListener('click', async function () {
        btn.disabled = true;
        try {
          var r = await CPS.cloud.call('shop_buy', { p_slot: parseInt(btn.getAttribute('data-buyslot'), 10) });
          ctx.toast('Pack purchased! Check your packs.', 'good');
          ctx.audio.coin();
          await ctx.refreshCloud();
          render(el);
        } catch (e) { btn.disabled = false; ctx.cloudError(e); }
      });
    });
  }

  function teardown() {
    if (timer) { clearInterval(timer); timer = null; }
  }

  CPS.shop = { render: render, teardown: teardown };
})(window.CPS);

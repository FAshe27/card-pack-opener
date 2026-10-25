/* Trading Post: list a card, field escrowed offers, accept the best one.
   The lister's card and every offer are escrowed server-side at submit
   time; acceptance swaps them atomically. Numbered-variant serials are
   allowed on both sides, picked explicitly.
   Consumes CPS.appCtx. Loads after js/app.js. Registers as CPS.trading. */
(function (CPS) {
  var ctx = CPS.appCtx;
  var T = null;              // {listings:[], my_open} from cps_trading_post
  var F = { set: '', q: '' };       // board filters
  var PL = null;             // post-listing form state
  var OF = null;             // offer form state

  function el() { return ctx.$('#tradingPanel'); }
  function esc(s) { return ctx.esc(s); }
  function setObj(id) { return window.CardSets.get(id); }
  function cardObj(sid, cid) { var s = setObj(sid); return s && s.byId.get(cid); }
  function sortByName(a) {
    return a.slice().sort(function (x, y) {
      var n = (x.name || '').toLowerCase(), m = (y.name || '').toLowerCase();
      return n < m ? -1 : (n > m ? 1 : 0);
    });
  }
  function sortByRarity(a, b) {
    var ra = (ctx.R.INDEX[a.rarity] || 0), rb = (ctx.R.INDEX[b.rarity] || 0);
    if (rb !== ra) return rb - ra;
    var n = (a.name || '').toLowerCase(), m = (b.name || '').toLowerCase();
    return n < m ? -1 : (n > m ? 1 : 0);
  }
  function myVariants() { return (ctx.S.myVariants || []).filter(function (v) { return !v.vaulted; }); }
  function variantLabel(tier, serial) {
    var v = CPS.cards.VARIANTS[tier];
    return v ? v.name + ' #' + serial + '/' + v.run : tier + ' #' + serial;
  }

  /* ------------------------------------------------------------ board */
  async function render() {
    var box = el(); if (!box) return;
    if (!ctx.isCloud()) {
      box.innerHTML = '<div class="panel"><h2>Trading Post</h2>' +
        '<p class="muted">The Trading Post needs online play — log in to list and offer.</p></div>';
      return;
    }
    box.innerHTML =
      '<div class="panel trade-head"><h2>Trading Post</h2>' +
      '<p class="muted small">Got a card to move? List it and let the offers roll in — yours and every ' +
      'offer are held in escrow, so a deal can never fall through. Accept the best one; the rest are ' +
      'refunded automatically. Listings expire after 7 days.</p>' +
      '<div class="row wrap"><button class="btn primary" id="tradePostBtn">List a card</button>' +
      '<span class="muted small" id="tradeMyOpen"></span></div></div>' +
      '<div class="panel trade-filters"><label>Set <select id="tradeSetFilter"><option value="">All sets</option></select></label>' +
      '<label>Search <input id="tradeSearch" type="search" placeholder="Card, set, note or lister…" value="' + esc(F.q) + '"></label></div>' +
      '<div id="tradingList"><p class="muted small">Loading…</p></div>';
    ctx.$('#tradePostBtn').addEventListener('click', openPostModal);
    ctx.$('#tradeSetFilter').addEventListener('change', function (e) { F.set = e.target.value; renderList(); });
    ctx.$('#tradeSearch').addEventListener('input', function (e) { F.q = e.target.value; renderList(); });
    await load();
  }

  async function load() {
    var host = ctx.$('#tradingList');
    try {
      T = await CPS.cloud.call('trading_post', {});
      if (!T || !Array.isArray(T.listings)) throw new Error('Bad response from server (got ' + JSON.stringify(T).slice(0, 80) + ')');
      if (window.CardSets && window.CardSets.loadIds) {
        var tIds = {};
        T.listings.forEach(function (l) { tIds[l.set_id] = 1; });
        await window.CardSets.loadIds(Object.keys(tIds));
      }
      fillSetFilter();
      updateBadge();
      renderList();
      var mo = ctx.$('#tradeMyOpen');
      if (mo) mo.textContent = 'You have ' + (T.my_open || 0) + ' of 5 open listings.';
    } catch (e) {
      ctx.cloudError(e);
      if (host) host.innerHTML = '<div class="panel"><p class="error">Could not load the Trading Post: ' + esc((e && e.message) || e) + '</p>' +
        '<button class="btn" id="tradeRetry">Retry</button></div>';
      var rb = ctx.$('#tradeRetry');
      if (rb) rb.addEventListener('click', function () { host.innerHTML = '<p class="muted small">Loading…</p>'; load(); });
    }
  }

  function fillSetFilter() {
    var sel = ctx.$('#tradeSetFilter'); if (!sel || !T) return;
    var seen = {}, list = [];
    T.listings.forEach(function (l) {
      if (seen[l.set_id] || !setObj(l.set_id)) return;
      seen[l.set_id] = true;
      list.push({ id: l.set_id, name: l.set_name || l.set_id });
    });
    list = sortByName(list);
    sel.innerHTML = '<option value="">All sets</option>' + list.map(function (o) {
      return '<option value="' + esc(o.id) + '">' + esc(o.name) + '</option>';
    }).join('');
    sel.value = F.set;
  }

  function updateBadge() {
    var b = ctx.$('#tradeBadge'); if (!b) return;
    var n = T ? T.listings.filter(function (l) { return l.mine && l.offer_count > 0; }).length : 0;
    b.textContent = n;
    b.classList.toggle('hidden', !(n > 0));
    CPS._tradeNav = n; if (CPS.paintMarketNav) CPS.paintMarketNav();
  }

  /* Market nav badge, trading half (see bounties.js): my listings that
     have offers waiting. Called by bounties.navBadge on state loads;
     20s cache, best-effort. Uses the same cps_market_nav counts RPC —
     NOT trading_post, whose quest bump would complete the visit_market
     daily without a real visit. */
  var navAt = 0, navBusy = false;
  async function navBadge() {
    if (!ctx.isCloud()) { CPS._tradeNav = 0; if (CPS.paintMarketNav) CPS.paintMarketNav(); return; }
    if (navBusy || Date.now() - navAt < 20000) { if (CPS.paintMarketNav) CPS.paintMarketNav(); return; }
    navBusy = true;
    try {
      var r = await CPS.cloud.call('market_nav', {});
      navAt = Date.now();
      CPS._tradeNav = r.trade_offers || 0;
      if (CPS.paintMarketNav) CPS.paintMarketNav();
    } catch (e) { /* badge is best-effort */ }
    navBusy = false;
  }

  function expiresIn(iso) {
    var ms = new Date(iso).getTime() - Date.now();
    if (ms <= 0) return 'expired';
    var h = Math.floor(ms / 3600000);
    if (h < 1) return 'under an hour';
    if (h < 48) return h + 'h';
    return Math.floor(h / 24) + 'd';
  }

  function listingFace(l) {
    var s = setObj(l.set_id), card = s && s.byId.get(l.card_id);
    if (!s || !card) {
      return '<div class="trade-missing"><b>' + esc(l.card_name || l.card_id) + '</b><span class="muted small">' +
        esc(l.set_name || l.set_id) + '</span></div>';
    }
    var opts = { holo: !!l.holo };
    if (l.variant_tier) opts.variant = { tier: l.variant_tier, serial: l.variant_serial };
    var variantAttr = l.variant_tier ? ' data-variant-tier="' + esc(l.variant_tier) + '" data-variant-serial="' + esc(l.variant_serial) + '"' : '';
    return '<div class="trade-card-click" data-set="' + esc(l.set_id) + '" data-card="' + esc(l.card_id) + '"' +
      ' data-holo="' + (l.holo ? '1' : '0') + '"' + variantAttr +
      ' style="cursor:pointer;" title="View card">' + CPS.cards.render(s, card, opts) + '</div>';
  }

  function listingTitle(l) {
    var t = esc(l.card_name || l.card_id);
    if (l.variant_tier) t += ' <span class="pill r-' + esc(l.rarity || '') + '">' + esc(variantLabel(l.variant_tier, l.variant_serial)) + '</span>';
    else if (l.holo) t += ' <span class="muted">✦ holo</span>';
    return t;
  }

  function renderList() {
    var box = ctx.$('#tradingList'); if (!box || !T) return;
    var q = F.q.trim().toLowerCase();
    var list = T.listings.filter(function (l) {
      if (F.set && l.set_id !== F.set) return false;
      if (!q) return true;
      var hay = ((listingTitle(l) || '') + ' ' + (l.set_name || l.set_id || '') + ' ' + (l.note || '') + ' ' + (l.lister || '')).toLowerCase();
      return hay.indexOf(q) >= 0;
    });
    if (!list.length) {
      box.innerHTML = '<div class="panel"><p class="muted">' +
        (T.listings.length ? 'No listings match your filters.' : 'No open listings — post the first one!') + '</p></div>';
      return;
    }
    box.innerHTML = '<div class="trade-list">' + list.map(function (l) {
      return '<div class="panel trade-card">' +
        '<div class="trade-face">' + listingFace(l) + '</div>' +
        '<div class="trade-mid">' +
          '<div class="trade-cardname">' + listingTitle(l) + '</div>' +
          '<div class="muted small">' + esc(l.set_name || l.set_id) + ' · ' + esc(l.rarity || '') + '</div>' +
          (l.note ? '<div class="trade-note"><span class="muted small">Looking for: </span>“' + esc(l.note) + '”</div>' : '') +
          '<div class="muted small">listed by <b>' + esc(l.lister) + '</b> · expires in ' + esc(expiresIn(l.expires_at)) + '</div>' +
          '<div class="trade-offercount">' + (l.offer_count === 1 ? '1 offer' : l.offer_count + ' offers') +
            (l.my_offer ? ' · <b>you offered</b>' : '') + '</div>' +
          '<div class="trade-actions">' +
          '<button class="btn small" data-detail="' + esc(l.id) + '">View offers</button>' +
          (l.mine ? '<button class="btn small danger" data-cancel="' + esc(l.id) + '">Cancel listing</button>' : '') +
          '</div></div></div>';
    }).join('') + '</div>';
    box.querySelectorAll('[data-detail]').forEach(function (btn) {
      btn.addEventListener('click', function () { openDetail(btn.getAttribute('data-detail')); });
    });
    box.querySelectorAll('[data-cancel]').forEach(function (btn) {
      btn.addEventListener('click', function () { openCancelModal(btn.getAttribute('data-cancel')); });
    });
    // Make trading listing cards clickable -> open card modal
    bindCardClicks(box);
  }

  function findListing(id) {
    return T && T.listings.filter(function (l) { return l.id === id; })[0];
  }

  /* ------------------------------------------------------------ detail */
  function offerCardLines(c) {
    var sid = c.set_id || c.set, cid = c.card_id || c.card;
    var s = setObj(sid), card = s && s.byId.get(cid);
    var name = esc(card ? card.name : (cid || 'card'));
    var extra = '';
    if (c.tier) extra = ' <span class="pill r-' + esc((card && card.rarity) || '') + '">' + esc(variantLabel(c.tier, c.serial)) + '</span>';
    else if (c.holo) extra = ' ✦ holo';
    return '<span class="trade-offer-line">🃏 <b>' + name + '</b>' + extra +
      ' <span class="muted">(' + esc(s ? s.name : sid) + ')</span></span>';
  }

  /* Clickable card face for an offered card (same wrapper as listingFace,
     so bindCardClicks picks it up). '' when the card can't be resolved —
     the caller falls back to the text line. */
  function offerCardFace(c) {
    var sid = c.set_id || c.set, cid = c.card_id || c.card;
    var s = setObj(sid), card = s && s.byId.get(cid);
    if (!s || !card) return '';
    var opts = { holo: !!c.holo };
    if (c.tier) opts.variant = { tier: c.tier, serial: c.serial };
    var variantAttr = c.tier ? ' data-variant-tier="' + esc(c.tier) + '" data-variant-serial="' + esc(c.serial) + '"' : '';
    return '<div class="trade-card-click" data-set="' + esc(sid) + '" data-card="' + esc(cid) + '"' +
      ' data-holo="' + (c.holo ? '1' : '0') + '"' + variantAttr +
      ' style="cursor:pointer;" title="View card">' + CPS.cards.render(s, card, opts) + '</div>';
  }

  /* Offer body for the detail view: currency stays text lines, cards
     become clickable faces. (The accept-confirm keeps offerLines text.) */
  function offerBodyHtml(o) {
    var lines = [], faces = [];
    if (o.tokens > 0) lines.push('<span class="trade-offer-line">🪙 <b>' + o.tokens + '</b> game token' + (o.tokens === 1 ? '' : 's') + '</span>');
    if (o.tickets > 0) lines.push('<span class="trade-offer-line">🎟️ <b>' + o.tickets + '</b> spin ticket' + (o.tickets === 1 ? '' : 's') + '</span>');
    if (o.packs > 0) lines.push('<span class="trade-offer-line">🎁 <b>' + o.packs + '</b> ' + esc(o.pack_name || o.pack_set) + ' pack' + (o.packs === 1 ? '' : 's') + '</span>');
    (o.cards || []).forEach(function (c) {
      var f = offerCardFace(c);
      if (f) faces.push('<div class="trade-face">' + f + '</div>');
      else lines.push(offerCardLines(c));
    });
    var html = lines.join('');
    if (faces.length) html += '<div class="trade-offerfaces">' + faces.join('') + '</div>';
    return html || '<span class="muted small">—</span>';
  }

  function bindCardClicks(scope) {
    if (!scope) return;
    scope.querySelectorAll('.trade-card-click').forEach(function (el) {
      el.addEventListener('click', function (e) {
        e.stopPropagation();
        var vt = el.getAttribute('data-variant-tier');
        var variant = vt ? { tier: vt, serial: parseInt(el.getAttribute('data-variant-serial'), 10) } : null;
        ctx.openCardModal(el.getAttribute('data-set'), el.getAttribute('data-card'),
          el.getAttribute('data-holo') === '1', variant);
      });
    });
  }

  function offerLines(o) {
    var out = [];
    if (o.tokens > 0) out.push('<span class="trade-offer-line">🪙 <b>' + o.tokens + '</b> game token' + (o.tokens === 1 ? '' : 's') + '</span>');
    if (o.tickets > 0) out.push('<span class="trade-offer-line">🎟️ <b>' + o.tickets + '</b> spin ticket' + (o.tickets === 1 ? '' : 's') + '</span>');
    if (o.packs > 0) out.push('<span class="trade-offer-line">🎁 <b>' + o.packs + '</b> ' + esc(o.pack_name || o.pack_set) + ' pack' + (o.packs === 1 ? '' : 's') + '</span>');
    (o.cards || []).forEach(function (c) { out.push(offerCardLines(c)); });
    return out.join('') || '<span class="muted small">—</span>';
  }

  function openDetail(id) {
    var l = findListing(id); if (!l) return;
    if (window.CardSets && window.CardSets.loadIds) {
      var dIds = {};
      dIds[l.set_id] = 1;
      (l.offers || []).forEach(function (o) { (o.cards || []).forEach(function (c) { dIds[c.set_id] = 1; }); });
      var missing = Object.keys(dIds).filter(function (sid) { var s = window.CardSets.get(sid); return s && s.stub; });
      if (missing.length) { window.CardSets.loadIds(missing).then(function () { openDetail(id); }); return; }
    }
    var myOffer = (l.offers || []).filter(function (o) { return o.mine; })[0];
    var offersHtml = (l.offers || []).map(function (o) {
      return '<div class="panel trade-offerbox">' +
        '<div class="trade-offerhead"><b>' + esc(o.offerer) + '</b>' +
        '<span class="muted small">' + new Date(o.created_at).toLocaleString() + '</span></div>' +
        '<div class="trade-offerbody">' + offerBodyHtml(o) + '</div>' +
        '<div class="trade-actions">' +
        (l.mine ? '<button class="btn small primary" data-accept="' + esc(o.id) + '">Accept this offer</button>' : '') +
        (o.mine ? '<button class="btn small" data-withdraw="' + esc(o.id) + '">Withdraw</button>' : '') +
        '</div></div>';
    }).join('') || '<p class="muted">No offers yet — be the first!</p>';

    ctx.openModal(
      '<button class="modal-x" data-close aria-label="Close">×</button>' +
      '<h3>Trading Post</h3>' +
      '<div class="trade-detail">' +
        '<div class="trade-face">' + listingFace(l) + '</div>' +
        '<div><div class="trade-cardname">' + listingTitle(l) + '</div>' +
        '<div class="muted small">' + esc(l.set_name || l.set_id) + ' · ' + esc(l.rarity || '') + '</div>' +
        (l.note ? '<div class="trade-note"><span class="muted small">Looking for: </span>“' + esc(l.note) + '”</div>' : '') +
        '<div class="muted small">listed by <b>' + esc(l.lister) + '</b> · expires in ' + esc(expiresIn(l.expires_at)) + '</div></div>' +
      '</div>' +
      '<h4>Offers (' + (l.offers || []).length + ')</h4>' +
      '<div class="trade-offers">' + offersHtml + '</div>' +
      '<div class="row wrap">' +
      (l.mine
        ? '<button class="btn danger" data-cancellisting="' + esc(l.id) + '">Cancel listing</button>'
        : '<button class="btn primary" data-makeoffer="' + esc(l.id) + '">' +
          (myOffer ? 'Update your offer' : 'Make an offer') + '</button>') +
      '<button class="btn" data-close>Close</button></div>' +
      '<p class="muted small">Everything is escrowed: the listed card and every offer are locked until the listing is accepted, cancelled, or expires (7 days).</p>',
      function (box) {
        box.querySelectorAll('[data-close]').forEach(function (x) {
          x.addEventListener('click', function () { ctx.closeModal(); });
        });
        bindCardClicks(box);
        box.querySelectorAll('[data-accept]').forEach(function (btn) {
          btn.addEventListener('click', async function () {
            var o = (l.offers || []).filter(function (x) { return x.id === btn.getAttribute('data-accept'); })[0];
            if (!o) return;
            var ok = await ctx.confirmDialog('Accept this offer?',
              '<p>You give: <b>' + listingTitle(l) + '</b></p>' +
              '<p style="margin-top:10px">You get:</p><div class="trade-offerbody">' + offerLines(o) + '</div>' +
              '<p class="muted" style="margin-top:10px">This swap is <b>final</b> — it happens immediately and can\'t be undone. Every other offer on this listing is refunded.</p>',
              'Accept trade');
            if (!ok) return;
            acceptOffer(l.id, o.id, btn);
          });
        });
        box.querySelectorAll('[data-withdraw]').forEach(function (btn) {
          btn.addEventListener('click', async function () {
            btn.disabled = true;
            try {
              await CPS.cloud.call('trade_withdraw', { p_offer: btn.getAttribute('data-withdraw') });
              ctx.closeModal(); ctx.toast('Offer withdrawn — everything refunded.', 'good');
              ctx.audio.click(); await ctx.refreshCloud();
            } catch (e) { btn.disabled = false; ctx.cloudError(e); }
          });
        });
        var mc = box.querySelector('[data-makeoffer]');
        if (mc) mc.addEventListener('click', function () { openOfferModal(l.id); });
        var cc = box.querySelector('[data-cancellisting]');
        if (cc) cc.addEventListener('click', function () { ctx.closeModal(); openCancelModal(l.id); });
      });
  }

  async function acceptOffer(listingId, offerId, btn) {
    btn.disabled = true;
    try {
      var r = await CPS.cloud.call('trade_accept', { p_listing: listingId, p_offer: offerId });
      ctx.closeModal();
      ctx.toast('Trade complete!', 'good');
      ctx.audio.reveal('legendary');
      if (typeof r.game_tokens === 'number') ctx.S.gameTokens = r.game_tokens;
      if (typeof r.spins === 'number') ctx.S.spins = r.spins;
      await ctx.refreshCloud();
    } catch (e) { btn.disabled = false; ctx.cloudError(e); }
  }

  function openCancelModal(id) {
    var l = findListing(id); if (!l || !l.mine) return;
    ctx.openModal(
      '<button class="modal-x" data-close aria-label="Close">×</button>' +
      '<h3>Cancel listing</h3>' +
      '<p>Take down your listing for <b>' + esc(l.card_name || l.card_id) + '</b>? Your card comes back and every offer is refunded.</p>' +
      '<div class="row wrap"><button class="btn danger" id="tradeCancelGo">Cancel listing</button>' +
      '<button class="btn" data-close>Keep it</button></div>',
      function (box) {
        box.querySelectorAll('[data-close]').forEach(function (x) {
          x.addEventListener('click', function () { ctx.closeModal(); });
        });
        ctx.$('#tradeCancelGo', box).addEventListener('click', async function () {
          var btn = this; btn.disabled = true;
          try {
            await CPS.cloud.call('trade_cancel', { p_listing: id });
            ctx.closeModal();
            ctx.toast('Listing cancelled — card returned.', 'good');
            await ctx.refreshCloud();
          } catch (e) { btn.disabled = false; ctx.cloudError(e); }
        });
      });
  }

  /* ------------------------------------------------------------ post a listing */
  function ownedSets() {
    var out = [];
    window.CardSets.all().forEach(function (s) {
      if (s.id === 'jumbled') return;
      var st = ctx.ps({ id: s.id });
      var any = s.cards.some(function (c) { var e = st.cards[c.id]; return e && e.n > 0; });
      if (any) out.push(s);
    });
    return sortByName(out);
  }

  /* Phase 1 helpers: remembered sets (module-local storage, shared with
     bounties.js's keys — app.js's own last-set pref isn't exposed). */
  function lsGet(k) { try { return window.localStorage.getItem(k) || ''; } catch (e) { return ''; } }
  function lsSet(k, v) { try { window.localStorage.setItem(k, v); } catch (e) { /* storage unavailable */ } }
  function countLine(total, shown, searching) {
    if (searching) return total + (total === 1 ? ' match' : ' matches') + (shown < total ? ' · showing ' + shown : '');
    if (shown < total) return total + ' cards · showing the ' + shown + ' rarest — type to search';
    return total + (total === 1 ? ' card' : ' cards');
  }

  /* ------------------------------------------------------------ composer host
     The list-a-card and make-an-offer forms live in js/composer.js
     (CPS.composer) since Phase 2 — shared with the Bounty Board's
     post form. This module keeps the board, detail and cancel, and
     lends the composer its face renderer via this adapter. */
  var COMPOSER_HOST = {
    listingFace: listingFace,
    bindCardClicks: bindCardClicks,
    myOpen: function () { return T ? (T.my_open || 0) : null; },
    ownedSets: function () { return ownedSets(); },
    onListed: function () { ctx.closeModal(); },
    onOffered: function () { ctx.closeModal(); }
  };

  /* Opens the shared composer. prefill (optional, §2.2):
     { setId, cardId, copy: {holo:true} | {tier, serial}, fromCard }.
     Board buttons pass the click event — the composer ignores it. */
  async function openPostModal(prefill) {
    try { await ctx.ensureVariants(); } catch (e) { /* variants optional */ }
    CPS.composer.openListing(COMPOSER_HOST, prefill);
  }

  async function openOfferModal(listingId, prefill) {
    var l = findListing(listingId); if (!l || l.mine) return;
    try { await ctx.ensureVariants(); } catch (e) { /* variants optional */ }
    CPS.composer.openOffer(COMPOSER_HOST, l, prefill);
  }

  CPS.trading = { render: render, refresh: load, updateBadge: updateBadge, navBadge: navBadge, openListing: openPostModal, openOffer: openOfferModal,
    /* Phase 3 (§3.6): the card screen's listed-ghost tiles read my
       already-loaded listings from here — best-effort, never a fetch. */
    myListings: function () { return T ? T.listings.filter(function (l) { return l.mine; }) : null; } };
})(window.CPS);

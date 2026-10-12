/* Trading Post: list a card, field escrowed offers, accept the best one.
   The lister's card and every offer are escrowed server-side at submit
   time; acceptance swaps them atomically. Numbered-variant serials are
   allowed on both sides, picked explicitly.
   Consumes CPS.appCtx. Loads after js/app.js. Registers as CPS.trading. */
(function (CPS) {
  var ctx = CPS.appCtx;
  var T = null;              // {listings:[], my_open} from cps_trading_post
  var F = { set: '' };       // board filters
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
      '<div class="panel trade-filters"><label>Set <select id="tradeSetFilter"><option value="">All sets</option></select></label></div>' +
      '<div id="tradingList"><p class="muted small">Loading…</p></div>';
    ctx.$('#tradePostBtn').addEventListener('click', openPostModal);
    ctx.$('#tradeSetFilter').addEventListener('change', function (e) { F.set = e.target.value; renderList(); });
    await load();
  }

  async function load() {
    var host = ctx.$('#tradingList');
    try {
      T = await CPS.cloud.call('trading_post', {});
      if (!T || !Array.isArray(T.listings)) throw new Error('Bad response from server (got ' + JSON.stringify(T).slice(0, 80) + ')');
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
    var list = T.listings.filter(function (l) { return !F.set || l.set_id === F.set; });
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
    box.querySelectorAll('.trade-card-click').forEach(function (el) {
      el.addEventListener('click', function (e) {
        e.stopPropagation();
        var vt = el.getAttribute('data-variant-tier');
        var variant = vt ? { tier: vt, serial: parseInt(el.getAttribute('data-variant-serial'), 10) } : null;
        ctx.openCardModal(el.getAttribute('data-set'), el.getAttribute('data-card'),
          el.getAttribute('data-holo') === '1', variant);
      });
    });
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
    var myOffer = (l.offers || []).filter(function (o) { return o.mine; })[0];
    var offersHtml = (l.offers || []).map(function (o) {
      return '<div class="panel trade-offerbox">' +
        '<div class="trade-offerhead"><b>' + esc(o.offerer) + '</b>' +
        '<span class="muted small">' + new Date(o.created_at).toLocaleString() + '</span></div>' +
        '<div class="trade-offerbody">' + offerLines(o) + '</div>' +
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
        box.querySelectorAll('[data-accept]').forEach(function (btn) {
          btn.addEventListener('click', function () { acceptOffer(l.id, btn.getAttribute('data-accept'), btn); });
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

  async function openPostModal() {
    try { await ctx.ensureVariants(); } catch (e) { /* variants optional */ }
    var sets = ownedSets();
    PL = { sets: sets, set: sets[0] ? sets[0].id : '', card: null, q: '', holo: false, copy: 'regular', note: '' };
    ctx.openModal(
      '<button class="modal-x" data-close aria-label="Close">×</button>' +
      '<h3>List a card</h3>' +
      '<div class="trade-form">' +
      '<div class="row wrap"><label>Set <select id="tpSet"></select></label>' +
      '<label>Search <input id="tpSearch" placeholder="card name or #" size="18"></label></div>' +
      '<div id="tpCardGrid" class="tp-pick-grid"></div>' +
      '<div id="tpCardSel" class="muted small"></div>' +
      '<div class="row wrap"><label class="inline"><input type="checkbox" id="tpHolo"> list as holo</label>' +
      '<label>Which copy <select id="tpCopy"></select></label></div>' +
      '<div class="row wrap"><label>What are you looking for? (optional) <input id="tpNote" placeholder="e.g. Detroit Tigers cards" size="30" maxlength="140"></label></div>' +
      '<div class="row wrap"><button class="btn primary big" id="tpGo">List it</button>' +
      '<button class="btn" data-close>Cancel</button></div>' +
      '<p class="muted small">Your card is escrowed until the listing is accepted, cancelled, or expires (7 days).</p>' +
      '</div>',
      bindPostModal);
  }

  function bindPostModal(box) {
    box.querySelectorAll('[data-close]').forEach(function (x) {
      x.addEventListener('click', function () { ctx.closeModal(); });
    });
    var setSel = box.querySelector('#tpSet');
    setSel.innerHTML = PL.sets.map(function (s) {
      return '<option value="' + esc(s.id) + '">' + esc(s.name) + '</option>';
    }).join('');
    setSel.value = PL.set;
    setSel.addEventListener('change', function () {
      PL.set = setSel.value; PL.card = null; PL.q = '';
      box.querySelector('#tpSearch').value = '';
      plRenderGrid(box); plRenderSel(box);
    });
    box.querySelector('#tpSearch').addEventListener('input', function (e) {
      PL.q = e.target.value; plRenderGrid(box);
    });
    box.querySelector('#tpHolo').addEventListener('change', function (e) { PL.holo = e.target.checked; });
    box.querySelector('#tpCopy').addEventListener('change', function (e) { PL.copy = e.target.value; plRenderSel(box); });
    box.querySelector('#tpGo').addEventListener('click', function () { plSubmit(box, this); });
    plRenderGrid(box); plRenderSel(box);
  }

  function plRenderGrid(box) {
    var s = setObj(PL.set), grid = box.querySelector('#tpCardGrid');
    if (!s) { grid.innerHTML = ''; return; }
    var q = PL.q.trim().toLowerCase(), st = ctx.ps({ id: s.id }), list = [];
    s.cards.forEach(function (c) {
      var e = st.cards[c.id];
      if (!e || e.n - (e.v || 0) <= 0) return;
      if (q) {
        var hay = ('#' + c.num + ' ' + c.num + ' ' + c.name + ' ' + (c.subtitle || '')).toLowerCase();
        if (hay.indexOf(q) < 0) return;
      }
      list.push({ card: c, left: e.n - (e.v || 0) });
    });
    list.sort(function (x, y) { return sortByRarity(x.card, y.card); });
    list = list.slice(0, 40);
    grid.innerHTML = list.map(function (o) {
      var sel = PL.card && PL.card.set === s.id && PL.card.id === o.card.id;
      return '<button class="tp-pick' + (sel ? ' selected' : '') + '" data-card="' + esc(o.card.id) + '">' +
        '<span class="tp-pick-name">' + esc(o.card.name) + '</span>' +
        '<span><span class="pill r-' + o.card.rarity + '">' + esc(o.card.rarity) + '</span>' +
        ' <span class="muted small">×' + o.left + '</span></span></button>';
    }).join('') || '<div class="muted small">No matches.</div>';
    grid.querySelectorAll('[data-card]').forEach(function (btn) {
      btn.addEventListener('click', function () {
        var card = s.byId.get(btn.getAttribute('data-card'));
        PL.card = { set: s.id, id: card.id };
        PL.copy = 'regular';
        plRenderGrid(box); plRenderSel(box);
      });
    });
  }

  function plCopies() {
    // which physical copies of the picked card I can list
    if (!PL.card) return [];
    var st = ctx.ps({ id: PL.card.set }), e = st.cards[PL.card.id] || { n: 0, h: 0 };
    var out = [];
    var vmap = {};
    myVariants().forEach(function (v) {
      if (v.set_id === PL.card.set && v.card_id === PL.card.id) {
        vmap[v.tier + ':' + v.serial] = v;
        out.push({ key: v.tier + ':' + v.serial, label: variantLabel(v.tier, v.serial), tier: v.tier, serial: v.serial });
      }
    });
    var vcount = Object.keys(vmap).length;
    if (e.n - (e.v || 0) - vcount > 0) out.unshift({ key: 'regular', label: 'Regular copy (×' + (e.n - (e.v || 0) - vcount) + ')', tier: null, serial: null });
    return out;
  }

  function plRenderSel(box) {
    var t = box.querySelector('#tpCardSel'), cp = box.querySelector('#tpCopy');
    if (!PL.card) { t.innerHTML = 'No card selected yet.'; cp.innerHTML = ''; return; }
    var card = cardObj(PL.card.set, PL.card.id);
    var copies = plCopies();
    cp.innerHTML = copies.map(function (c) {
      return '<option value="' + esc(c.key) + '"' + (PL.copy === c.key ? ' selected' : '') + '>' + esc(c.label) + '</option>';
    }).join('');
    if (!copies.some(function (c) { return c.key === PL.copy; })) PL.copy = copies[0] ? copies[0].key : 'regular';
    cp.value = PL.copy;
    var c0 = copies.filter(function (c) { return c.key === PL.copy; })[0];
    t.innerHTML = 'Listing: <b>' + esc(card ? card.name : PL.card.id) + '</b>' +
      (c0 && c0.tier ? ' (' + esc(variantLabel(c0.tier, c0.serial)) + ')' : '') +
      (PL.holo ? ' ✦ holo' : '');
  }

  async function plSubmit(box, btn) {
    if (!PL.card) { ctx.toast('Pick a card to list first.', 'warn'); return; }
    var copies = plCopies();
    var c0 = copies.filter(function (c) { return c.key === PL.copy; })[0] || { tier: null, serial: null };
    btn.disabled = true;
    try {
      await CPS.cloud.call('trade_post', {
        p_card: { set: PL.card.set, card: PL.card.id, holo: PL.holo,
                  tier: c0.tier || null, serial: c0.serial || null },
        p_note: (box.querySelector('#tpNote').value || '').trim()
      });
      ctx.closeModal();
      ctx.toast('Card listed!', 'good');
      ctx.audio.coin();
      await ctx.refreshCloud();
    } catch (e) { btn.disabled = false; ctx.cloudError(e); }
  }

  /* ------------------------------------------------------------ make an offer */
  function ofOwnedSets() {
    var out = [];
    window.CardSets.all().forEach(function (s) {
      if (s.id === 'jumbled') return;
      var st = ctx.ps({ id: s.id });
      var any = s.cards.some(function (c) { var e = st.cards[c.id]; return e && e.n > 0; });
      if (any) out.push(s);
    });
    return sortByName(out);
  }

  async function openOfferModal(listingId) {
    var l = findListing(listingId); if (!l || l.mine) return;
    try { await ctx.ensureVariants(); } catch (e) { /* variants optional */ }
    var sets = ofOwnedSets();
    OF = {
      listing: l, sets: sets, set: sets[0] ? sets[0].id : '', q: '',
      tokens: 0, tickets: 0, packSet: '', packs: 0,
      cards: []   // {set, card, holo, tier, serial, label}
    };
    ctx.openModal(
      '<button class="modal-x" data-close aria-label="Close">×</button>' +
      '<h3>Make an offer</h3>' +
      '<p class="muted small">For <b>' + esc(l.card_name || l.card_id) + '</b>' +
      (l.variant_tier ? ' (' + esc(variantLabel(l.variant_tier, l.variant_serial)) + ')' : '') +
      ' — everything you offer is escrowed until the listing closes.</p>' +
      '<div class="trade-form">' +
      '<div class="row wrap"><label>🪙 Tokens <input id="ofTokens" type="number" min="0" max="' + (ctx.S.gameTokens || 0) +
        '" value="0" style="width:80px"></label><span class="muted small">you have ' + (ctx.S.gameTokens || 0) + '</span>' +
      '<label>🎟️ Tickets <input id="ofTickets" type="number" min="0" max="' + (ctx.S.spins || 0) +
        '" value="0" style="width:80px"></label><span class="muted small">you have ' + (ctx.S.spins || 0) + '</span></div>' +
      '<div class="row wrap"><label>🎁 Packs <select id="ofPackSet"></select></label>' +
      '<input id="ofPacks" type="number" min="0" value="0" style="width:70px"><span class="muted small" id="ofPacksHave"></span></div>' +
      '<div class="row wrap"><label>🃏 Card <select id="ofCardSet"></select></label>' +
      '<label>Search <input id="ofCardSearch" placeholder="card name or #" size="18"></label></div>' +
      '<div id="ofCardGrid" class="tp-pick-grid"></div>' +
      '<div class="row wrap"><label class="inline"><input type="checkbox" id="ofCardHolo"> add as holo</label>' +
      '<span class="muted small">tap a card to add it (up to 5 — numbered serials listed separately)</span></div>' +
      '<div id="ofCards" class="trade-offer-chips"></div>' +
      '<div class="row wrap"><button class="btn primary big" id="ofGo">Submit offer</button>' +
      '<button class="btn" data-close>Cancel</button></div>' +
      '</div>',
      bindOfferModal);
  }

  function bindOfferModal(box) {
    box.querySelectorAll('[data-close]').forEach(function (x) {
      x.addEventListener('click', function () { ctx.closeModal(); });
    });
    // pack picker
    var packSet = box.querySelector('#ofPackSet'), packsHave = box.querySelector('#ofPacksHave');
    var invSets = OF.sets.filter(function (s) { return (ctx.ps({ id: s.id }).packs || 0) > 0; });
    packSet.innerHTML = '<option value="">—</option>' + invSets.map(function (s) {
      return '<option value="' + esc(s.id) + '">' + esc(s.name) + ' (' + ctx.ps({ id: s.id }).packs + ')</option>';
    }).join('');
    function syncPacks() {
      var sid = packSet.value, n = sid ? (ctx.ps({ id: sid }).packs || 0) : 0;
      packsHave.textContent = sid ? 'you have ' + n : '';
      box.querySelector('#ofPacks').max = n;
    }
    packSet.addEventListener('change', syncPacks); syncPacks();

    // card picker
    var oSetSel = box.querySelector('#ofCardSet');
    oSetSel.innerHTML = OF.sets.map(function (s) {
      return '<option value="' + esc(s.id) + '">' + esc(s.name) + '</option>';
    }).join('');
    oSetSel.value = OF.set;
    oSetSel.addEventListener('change', function () {
      OF.set = oSetSel.value; OF.q = '';
      box.querySelector('#ofCardSearch').value = '';
      ofRenderGrid(box);
    });
    box.querySelector('#ofCardSearch').addEventListener('input', function (e) {
      OF.q = e.target.value; ofRenderGrid(box);
    });
    ofRenderGrid(box); ofRenderCards(box);
    box.querySelector('#ofGo').addEventListener('click', function () { ofSubmit(box, this); });
  }

  function ofGridRows() {
    // pickable rows: one per non-variant availability + one per owned serial
    var s = setObj(OF.set); if (!s) return [];
    var q = OF.q.trim().toLowerCase(), st = ctx.ps({ id: s.id }), rows = [];
    var vmap = {};
    myVariants().forEach(function (v) {
      if (v.set_id !== s.id) return;
      (vmap[v.card_id] = vmap[v.card_id] || []).push(v);
    });
    s.cards.forEach(function (c) {
      var e = st.cards[c.id];
      if (!e || e.n - (e.v || 0) <= 0) return;
      if (q) {
        var hay = ('#' + c.num + ' ' + c.num + ' ' + c.name + ' ' + (c.subtitle || '')).toLowerCase();
        if (hay.indexOf(q) < 0) return;
      }
      var vs = vmap[c.id] || [];
      var plainLeft = e.n - (e.v || 0) - vs.length;
      // used counts
      var usedPlain = OF.cards.filter(function (o) { return o.set === s.id && o.card === c.id && !o.tier; }).length;
      if (plainLeft - usedPlain > 0) {
        rows.push({ set: s.id, card: c, kind: 'plain', left: plainLeft - usedPlain,
                    holo: (e.h || 0) - (e.vh || 0) > 0, label: c.name, tier: null, serial: null });
      }
      vs.forEach(function (v) {
        var usedV = OF.cards.some(function (o) { return o.set === s.id && o.card === c.id && o.tier === v.tier && o.serial === v.serial; });
        if (!usedV) {
          rows.push({ set: s.id, card: c, kind: 'variant', left: 1,
                      holo: (e.h || 0) - (e.vh || 0) > 0, label: c.name + ' — ' + variantLabel(v.tier, v.serial),
                      tier: v.tier, serial: v.serial });
        }
      });
    });
    rows.sort(function (x, y) { return sortByRarity(x.card, y.card); });
    return rows.slice(0, 40);
  }

  function ofRenderGrid(box) {
    var grid = box.querySelector('#ofCardGrid');
    var rows = ofGridRows();
    grid.innerHTML = rows.map(function (r, i) {
      return '<button class="tp-pick" data-row="' + i + '">' +
        '<span class="tp-pick-name">' + esc(r.label) + (r.kind === 'plain' && r.holo ? ' ✦' : '') + '</span>' +
        '<span><span class="pill r-' + r.card.rarity + '">' + esc(r.card.rarity) + '</span>' +
        (r.kind === 'plain' ? ' <span class="muted small">×' + r.left + '</span>' : '') + '</span></button>';
    }).join('') || '<div class="muted small">No matches.</div>';
    grid.querySelectorAll('[data-row]').forEach(function (btn) {
      btn.addEventListener('click', function () { ofAdd(box, rows[+btn.getAttribute('data-row')]); });
    });
  }

  function ofAdd(box, r) {
    if (!r) return;
    if (OF.cards.length >= 5) { ctx.toast('At most 5 cards per offer.', 'warn'); return; }
    var wantHolo = box.querySelector('#ofCardHolo').checked;
    OF.cards.push({ set: r.set, card: r.card.id, holo: wantHolo && r.holo,
                    tier: r.tier, serial: r.serial, label: r.label });
    ofRenderCards(box); ofRenderGrid(box);
  }

  function ofRenderCards(box) {
    var t = box.querySelector('#ofCards');
    t.innerHTML = OF.cards.map(function (o, i) {
      return '<span class="trade-chip"><b>' + esc(o.label) + '</b>' +
        (o.holo ? ' ✦' : '') +
        '<button class="chip-x" data-rm="' + i + '" title="Remove">×</button></span>';
    }).join('') || '<span class="muted small">No cards offered yet.</span>';
    t.querySelectorAll('[data-rm]').forEach(function (x) {
      x.addEventListener('click', function () {
        OF.cards.splice(+x.getAttribute('data-rm'), 1);
        ofRenderCards(box); ofRenderGrid(box);
      });
    });
  }

  async function ofSubmit(box, btn) {
    var tokens = Math.max(0, parseInt(box.querySelector('#ofTokens').value, 10) || 0);
    var tickets = Math.max(0, parseInt(box.querySelector('#ofTickets').value, 10) || 0);
    var packSet = box.querySelector('#ofPackSet').value || null;
    var packs = Math.max(0, parseInt(box.querySelector('#ofPacks').value, 10) || 0);
    if (packSet && !packs) { ctx.toast('Set the pack count for your pack offer.', 'warn'); return; }
    if (!packSet) packs = 0;
    if (!tokens && !tickets && !packs && !OF.cards.length) {
      ctx.toast('Your offer needs tokens, tickets, packs, or cards.', 'warn'); return;
    }
    btn.disabled = true;
    try {
      await CPS.cloud.call('trade_offer', {
        p_listing: OF.listing.id,
        p_offer: { tokens: tokens, tickets: tickets, pack_set: packSet, packs: packs,
                   cards: OF.cards.map(function (o) { return { set: o.set, card: o.card, holo: o.holo, tier: o.tier, serial: o.serial }; }) }
      });
      ctx.closeModal();
      ctx.toast('Offer submitted — escrowed until the listing closes.', 'good');
      ctx.audio.coin();
      await ctx.refreshCloud();
    } catch (e) { btn.disabled = false; ctx.cloudError(e); }
  }

  CPS.trading = { render: render, refresh: load, updateBadge: updateBadge };
})(window.CPS);

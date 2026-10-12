/* Bounty Board: public standing offers for wanted cards.
   A player posts a bounty naming one wanted card (optional holo requirement
   or numbered-variant serial) plus an offer of game tokens, spin tickets,
   packs, and/or up to 5 cards. The offer is escrowed server-side at post
   time; the first claimer holding the wanted card wins it atomically.
   Consumes CPS.appCtx (S, $, esc, toast, isCloud, openModal, ...). Loads
   after js/app.js. Registers as CPS.bounties. */
(function (CPS) {
  var ctx = CPS.appCtx;
  var B = null;                          // {bounties:[], my_open} from cps_list_bounties
  var F = { set: '', fillable: false };  // board filters
  var PB = null;                         // post-bounty form state

  function el() { return ctx.$('#bountyPanel'); }
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
    // highest rarity first, then alphabetical
    var ra = (ctx.R.INDEX[a.rarity] || 0), rb = (ctx.R.INDEX[b.rarity] || 0);
    if (rb !== ra) return rb - ra;
    var n = (a.name || '').toLowerCase(), m = (b.name || '').toLowerCase();
    return n < m ? -1 : (n > m ? 1 : 0);
  }

  /* ------------------------------------------------------------ board */
  async function render() {
    var box = el(); if (!box) return;
    if (!ctx.isCloud()) {
      box.innerHTML = '<div class="panel"><h2>Bounty Board</h2>' +
        '<p class="muted">Bounties need online play — log in to post and claim.</p></div>';
      return;
    }
    box.innerHTML =
      '<div class="panel bounty-head"><h2>Bounty Board</h2>' +
      '<p class="muted small">Want a card? Post a bounty with an offer of tokens, spin tickets, packs, or cards. ' +
      'Your offer is held in escrow until someone claims it — cancel anytime for a full refund. Bounties expire after 7 days.</p>' +
      '<div class="row wrap"><button class="btn primary" id="bountyPostBtn">Post a bounty</button>' +
      '<span class="muted small" id="bountyMyOpen"></span></div></div>' +
      '<div class="panel bounty-filters"><label>Set <select id="bountySetFilter"><option value="">All sets</option></select></label>' +
      '<label class="inline"><input type="checkbox" id="bountyFillFilter"> Bounties I can fill</label></div>' +
      '<div id="bountyList"><p class="muted small">Loading…</p></div>';
    ctx.$('#bountyPostBtn').addEventListener('click', openPostModal);
    ctx.$('#bountyFillFilter').addEventListener('change', function (e) { F.fillable = e.target.checked; renderList(); });
    ctx.$('#bountySetFilter').addEventListener('change', function (e) { F.set = e.target.value; renderList(); });
    await load();
  }

  async function load() {
    try {
      B = await CPS.cloud.call('list_bounties', {});
      fillSetFilter();
      updateBadge();
      renderList();
      var mo = ctx.$('#bountyMyOpen');
      if (mo) mo.textContent = 'You have ' + (B.my_open || 0) + ' of 5 open bounties.';
    } catch (e) {
      ctx.cloudError(e);
      var box = ctx.$('#bountyList');
      if (box) box.innerHTML = '<div class="empty">Couldn\'t load bounties. <button class="btn small" id="bountyRetry">Retry</button></div>';
      var rb = ctx.$('#bountyRetry');
      if (rb) rb.addEventListener('click', load);
    }
  }

  function fillSetFilter() {
    var sel = ctx.$('#bountySetFilter'); if (!sel || !B) return;
    var seen = {}, list = [];
    B.bounties.forEach(function (b) {
      if (seen[b.want_set] || !setObj(b.want_set)) return;
      seen[b.want_set] = true;
      list.push({ id: b.want_set, name: b.set_name || b.want_set });
    });
    list = sortByName(list);
    sel.innerHTML = '<option value="">All sets</option>' + list.map(function (o) {
      return '<option value="' + esc(o.id) + '">' + esc(o.name) + '</option>';
    }).join('');
    sel.value = F.set;
  }

  function updateBadge() {
    var b = ctx.$('#bountyBadge'); if (!b) return;
    var n = B ? B.bounties.filter(function (x) { return x.can_claim; }).length : 0;
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

  function offerLines(b) {
    var out = [];
    if (b.offer_tokens > 0) out.push('<span class="bounty-offer-line">🪙 <b>' + b.offer_tokens + '</b> game token' + (b.offer_tokens === 1 ? '' : 's') + '</span>');
    if (b.offer_tickets > 0) out.push('<span class="bounty-offer-line">🎟️ <b>' + b.offer_tickets + '</b> spin ticket' + (b.offer_tickets === 1 ? '' : 's') + '</span>');
    if (b.offer_packs > 0) {
      var s = setObj(b.offer_pack_set);
      out.push('<span class="bounty-offer-line">🎁 <b>' + b.offer_packs + '</b> ' + esc(s ? s.name : b.offer_pack_set) + ' pack' + (b.offer_packs === 1 ? '' : 's') + '</span>');
    }
    (b.offer_cards || []).forEach(function (c) {
      var s = setObj(c.set_id), card = s && s.byId.get(c.card_id);
      var rar = c.rarity || (card && card.rarity);
      out.push('<span class="bounty-offer-line">🃏 <b>' + esc(c.card_name || (card && card.name) || c.card_id) + '</b>' +
        (c.holo ? ' ✦ holo' : '') + ' <span class="muted">(' + esc(c.set_name || (s && s.name) || c.set_id) +
        (rar ? ' · ' + esc(rar) : '') + ')</span></span>');
    });
    return out.join('');
  }

  function wantFace(b) {
    var s = setObj(b.want_set), card = s && s.byId.get(b.want_card);
    if (!s || !card) {
      return '<div class="bounty-want-missing"><b>' + esc(b.card_name || b.want_card) + '</b><span class="muted small">' +
        esc(b.set_name || b.want_set) + '</span></div>';
    }
    var opts = { holo: b.want_holo === 'holo' };
    if (b.want_serial) opts.variant = { tier: b.want_tier, serial: b.want_serial };
    var variantAttr = b.want_serial ? ' data-variant-tier="' + esc(b.want_tier) + '" data-variant-serial="' + esc(b.want_serial) + '"' : '';
    return '<div class="bounty-card-click" data-set="' + esc(b.want_set) + '" data-card="' + esc(b.want_card) + '"' +
      ' data-holo="' + (b.want_holo === 'holo' ? '1' : '0') + '"' + variantAttr +
      ' style="cursor:pointer;" title="View card">' + CPS.cards.render(s, card, opts) + '</div>';
  }

  function wantReq(b) {
    if (b.want_serial) {
      var v = CPS.cards.VARIANTS[b.want_tier];
      return 'Needs ' + (v ? v.name : b.want_tier) + ' #' + b.want_serial + '/' + (v ? v.run : '?');
    }
    return b.want_holo === 'holo' ? 'Needs a holo copy' : 'Any copy';
  }

  function renderList() {
    var box = ctx.$('#bountyList'); if (!box || !B) return;
    var list = B.bounties.filter(function (b) {
      if (F.set && b.want_set !== F.set) return false;
      if (F.fillable && !b.can_claim) return false;
      return true;
    });
    if (!list.length) {
      box.innerHTML = '<div class="panel"><p class="muted">' +
        (B.bounties.length ? 'No bounties match your filters.' : 'No open bounties — post the first one!') + '</p></div>';
      return;
    }
    box.innerHTML = '<div class="bounty-list">' + list.map(function (b) {
      var claimTitle = b.mine ? 'This is your bounty' : (b.can_claim ? 'Claim this bounty' : 'You don\'t hold the wanted card');
      return '<div class="panel bounty-card" data-bounty="' + esc(b.id) + '">' +
        '<div class="bounty-want">' + wantFace(b) + '</div>' +
        '<div class="bounty-mid">' +
          '<div class="bounty-want-label">WANTED</div>' +
          '<div class="bounty-cardname">' + esc(b.card_name || b.want_card) + '</div>' +
          '<div class="muted small">' + esc(b.set_name || b.want_set) + ' · ' + esc(b.rarity || '') + '</div>' +
          '<div class="bounty-req">' + esc(wantReq(b)) + '</div>' +
          '<div class="muted small">posted by <b>' + esc(b.poster) + '</b> · expires in ' + esc(expiresIn(b.expires_at)) + '</div>' +
        '</div>' +
        '<div class="bounty-offer"><div class="bounty-want-label">OFFER</div>' + offerLines(b) +
          '<div class="bounty-actions">' +
          (b.mine
            ? '<button class="btn small danger" data-cancel="' + esc(b.id) + '">Cancel bounty</button>'
            : '<button class="btn small primary" data-claim="' + esc(b.id) + '"' + (b.can_claim ? '' : ' disabled') +
              ' title="' + esc(claimTitle) + '">Claim bounty</button>') +
          '</div></div></div>';
    }).join('') + '</div>';
    box.querySelectorAll('[data-claim]').forEach(function (btn) {
      btn.addEventListener('click', function () { openClaimModal(btn.getAttribute('data-claim')); });
    });
    box.querySelectorAll('[data-cancel]').forEach(function (btn) {
      btn.addEventListener('click', function () { openCancelModal(btn.getAttribute('data-cancel')); });
    });
    // Make bounty want cards clickable -> open card modal
    box.querySelectorAll('.bounty-card-click').forEach(function (el) {
      el.addEventListener('click', function (e) {
        e.stopPropagation();
        var vt = el.getAttribute('data-variant-tier');
        var variant = vt ? { tier: vt, serial: parseInt(el.getAttribute('data-variant-serial'), 10) } : null;
        ctx.openCardModal(el.getAttribute('data-set'), el.getAttribute('data-card'),
          el.getAttribute('data-holo') === '1', variant);
      });
    });
  }

  /* ------------------------------------------------------------ claim */
  function findBounty(id) {
    return B && B.bounties.filter(function (b) { return b.id === id; })[0];
  }

  function openClaimModal(id) {
    var b = findBounty(id); if (!b || !b.can_claim) return;
    var cardName = b.card_name || b.want_card;
    ctx.openModal(
      '<button class="modal-x" data-close aria-label="Close">×</button>' +
      '<h3>Claim bounty</h3>' +
      '<p>Are you sure you want to trade:</p>' +
      '<div class="bounty-tradebox"><div><span class="bounty-want-label">YOU GIVE</span><b>' + esc(cardName) + '</b>' +
        '<div class="muted small">' + esc(wantReq(b)) + '</div></div>' +
      '<div class="bounty-trade-arrow">⇄</div>' +
      '<div><span class="bounty-want-label">YOU GET</span><div>' + offerLines(b) + '</div></div></div>' +
      '<div class="row wrap"><button class="btn primary" id="bountyClaimGo">Claim bounty</button>' +
      '<button class="btn" data-close>Never mind</button></div>',
      function (box) {
        box.querySelectorAll('[data-close]').forEach(function (x) {
          x.addEventListener('click', function () { ctx.closeModal(); });
        });
        ctx.$('#bountyClaimGo', box).addEventListener('click', async function () {
          var btn = this; btn.disabled = true;
          try {
            await CPS.cloud.call('claim_bounty', { p_bounty_id: id });
            ctx.closeModal();
            ctx.toast('Bounty claimed!', 'good');
            ctx.audio.reveal('epic');
            await load(); await ctx.refreshCloud();
          } catch (e) { btn.disabled = false; ctx.cloudError(e); }
        });
      });
  }

  function openCancelModal(id) {
    var b = findBounty(id); if (!b || !b.mine) return;
    ctx.openModal(
      '<button class="modal-x" data-close aria-label="Close">×</button>' +
      '<h3>Cancel bounty</h3>' +
      '<p>Cancel your bounty for <b>' + esc(b.card_name || b.want_card) + '</b>? Your full offer will be refunded.</p>' +
      '<div class="row wrap"><button class="btn danger" id="bountyCancelGo">Cancel bounty</button>' +
      '<button class="btn" data-close>Keep it</button></div>',
      function (box) {
        box.querySelectorAll('[data-close]').forEach(function (x) {
          x.addEventListener('click', function () { ctx.closeModal(); });
        });
        ctx.$('#bountyCancelGo', box).addEventListener('click', async function () {
          var btn = this; btn.disabled = true;
          try {
            await CPS.cloud.call('cancel_bounty', { p_bounty_id: id });
            ctx.closeModal();
            ctx.toast('Bounty cancelled — offer refunded.', 'good');
            await load(); await ctx.refreshCloud();
          } catch (e) { btn.disabled = false; ctx.cloudError(e); }
        });
      });
  }

  /* ------------------------------------------------------------ post */
  function ownedSets() {
    // sets where I own at least one non-variant copy (for the offer card picker)
    var out = [];
    window.CardSets.all().forEach(function (s) {
      if (s.id === 'jumbled') return;
      var st = ctx.ps({ id: s.id });
      var vmap = variantCountMap();
      var any = s.cards.some(function (c) {
        var e = st.cards[c.id];
        return e && (e.n - (e.v || 0) - (vmap[s.id + ':' + c.id] || 0)) > 0;
      });
      if (any) out.push(s);
    });
    return sortByName(out);
  }

  function variantCountMap() {
    // app.js owns this (counts my numbered-variant copies per card); fall back
    // to a local tally if it ever disappears from appCtx.
    if (ctx.variantCountMap) return ctx.variantCountMap();
    var m = {};
    (ctx.S.myVariants || []).forEach(function (v) {
      var k = v.set_id + ':' + v.card_id;
      m[k] = (m[k] || 0) + 1;
    });
    return m;
  }

  async function openPostModal() {
    try { await ctx.ensureVariants(); } catch (e) { /* variants optional for posting */ }
    var sets = sortByName(window.CardSets.all().filter(function (s) { return s.id !== 'jumbled'; }));
    PB = {
      sets: sets, wantSet: sets[0] ? sets[0].id : '', wantCard: null, q: '',
      offerSet: '', offerQ: '',
      holo: 'any', tier: '', serial: '',
      tokens: 0, tickets: 0, packSet: '', packs: 0,
      offerCards: []   // {set, card, holo}
    };
    ctx.openModal(
      '<button class="modal-x" data-close aria-label="Close">×</button>' +
      '<h3>Post a bounty</h3>' +
      '<div class="bounty-form">' +
      '<h4>You want</h4>' +
      '<div class="row wrap"><label>Set <select id="pbSet"></select></label>' +
      '<label>Search <input id="pbSearch" placeholder="card name or #" size="18"></label></div>' +
      '<div id="pbCardResults" class="bounty-pick-grid"></div>' +
      '<div id="pbWantSel" class="muted small"></div>' +
      '<div class="row wrap"><span class="muted small">Copy needed:</span>' +
      '<label class="inline"><input type="radio" name="pbHolo" value="any" checked> Any copy</label>' +
      '<label class="inline"><input type="radio" name="pbHolo" value="holo"> Holo only</label></div>' +
      '<div class="row wrap"><span class="muted small">Numbered serial (optional):</span>' +
      '<select id="pbTier"><option value="">—</option><option value="rainbow">Rainbow /50</option>' +
      '<option value="prism">Prism /10</option><option value="obsidian">Obsidian /5</option>' +
      '<option value="oneofone">One-of-One</option></select>' +
      '<input id="pbSerial" type="number" min="1" placeholder="#" style="width:64px;flex:none"></div>' +
      '<h4>You offer</h4>' +
      '<div class="row wrap"><label>🪙 Tokens <input id="pbTokens" type="number" min="0" max="' + (ctx.S.gameTokens || 0) +
        '" value="0" style="width:80px"></label><span class="muted small">you have ' + (ctx.S.gameTokens || 0) + '</span>' +
      '<label>🎟️ Tickets <input id="pbTickets" type="number" min="0" max="' + (ctx.S.spins || 0) +
        '" value="0" style="width:80px"></label><span class="muted small">you have ' + (ctx.S.spins || 0) + '</span></div>' +
      '<div class="row wrap"><label>🎁 Packs <select id="pbPackSet"></select></label>' +
      '<input id="pbPacks" type="number" min="0" value="0" style="width:70px"><span class="muted small" id="pbPacksHave"></span></div>' +
      '<div class="row wrap"><label>🃏 Card <select id="pbCardSet"></select></label>' +
      '<label>Search <input id="pbCardSearch" placeholder="card name or #" size="18"></label></div>' +
      '<div id="pbOfferGrid" class="bounty-pick-grid"></div>' +
      '<div class="row wrap"><label class="inline"><input type="checkbox" id="pbCardHolo"> add as holo</label>' +
      '<span class="muted small">tap a card to add it to your offer (up to 5)</span></div>' +
      '<div id="pbOfferCards" class="bounty-offer-chips"></div>' +
      '<div class="row wrap"><button class="btn primary big" id="pbGo">Post bounty</button>' +
      '<button class="btn" data-close>Cancel</button></div>' +
      '<p class="muted small">Your offer is held in escrow until the bounty is claimed, cancelled, or expires (7 days).</p>' +
      '</div>',
      bindPostModal);
  }

  function bindPostModal(box) {
    box.querySelectorAll('[data-close]').forEach(function (x) {
      x.addEventListener('click', function () { ctx.closeModal(); });
    });
    var setSel = box.querySelector('#pbSet');
    setSel.innerHTML = PB.sets.map(function (s) {
      return '<option value="' + esc(s.id) + '">' + esc(s.name) + '</option>';
    }).join('');
    setSel.value = PB.wantSet;
    setSel.addEventListener('change', function () { PB.wantSet = setSel.value; PB.q = ''; box.querySelector('#pbSearch').value = ''; pbRenderResults(box); });

    var q = box.querySelector('#pbSearch');
    q.addEventListener('input', function () { PB.q = q.value; pbRenderResults(box); });

    box.querySelectorAll('input[name="pbHolo"]').forEach(function (r) {
      r.addEventListener('change', function () { PB.holo = r.value; pbRenderWantSel(box); });
    });
    box.querySelector('#pbTier').addEventListener('change', function (e) { PB.tier = e.target.value; pbRenderWantSel(box); });
    box.querySelector('#pbSerial').addEventListener('input', function (e) { PB.serial = e.target.value; pbRenderWantSel(box); });

    // pack offer
    var packSet = box.querySelector('#pbPackSet'), packsHave = box.querySelector('#pbPacksHave');
    var invSets = PB.sets.filter(function (s) { return (ctx.ps({ id: s.id }).packs || 0) > 0; });
    packSet.innerHTML = '<option value="">—</option>' + invSets.map(function (s) {
      return '<option value="' + esc(s.id) + '">' + esc(s.name) + ' (' + ctx.ps({ id: s.id }).packs + ')</option>';
    }).join('');
    function syncPacks() {
      var sid = packSet.value, n = ctx.ps({ id: sid }).packs || 0;
      packsHave.textContent = sid ? 'you have ' + n : '';
      box.querySelector('#pbPacks').max = n;
    }
    packSet.addEventListener('change', syncPacks); syncPacks();

    // offer-card picker (same pick-grid pattern as "You want": tap a card to add it)
    var oSets = ownedSets();
    PB.offerSet = oSets[0] ? oSets[0].id : '';
    PB.offerQ = '';
    var oSetSel = box.querySelector('#pbCardSet');
    oSetSel.innerHTML = oSets.map(function (s) {
      return '<option value="' + esc(s.id) + '">' + esc(s.name) + '</option>';
    }).join('');
    oSetSel.value = PB.offerSet;
    oSetSel.addEventListener('change', function () {
      PB.offerSet = oSetSel.value; PB.offerQ = '';
      box.querySelector('#pbCardSearch').value = '';
      pbRenderOfferGrid(box);
    });
    box.querySelector('#pbCardSearch').addEventListener('input', function (e) {
      PB.offerQ = e.target.value; pbRenderOfferGrid(box);
    });
    pbRenderOfferGrid(box);

    box.querySelector('#pbGo').addEventListener('click', function () { pbSubmit(box, this); });
    pbRenderResults(box);
    pbRenderOfferCards(box);
  }

  function pbRenderResults(box) {
    var s = setObj(PB.wantSet), grid = box.querySelector('#pbCardResults');
    if (!s) { grid.innerHTML = ''; return; }
    var q = PB.q.trim().toLowerCase(), list = [];
    s.cards.forEach(function (c) {
      if (q) {
        var hay = ('#' + c.num + ' ' + c.num + ' ' + c.name + ' ' + (c.subtitle || '')).toLowerCase();
        if (hay.indexOf(q) < 0) return;
      }
      list.push(c);
    });
    list.sort(sortByRarity);
    list = list.slice(0, 40);
    grid.innerHTML = list.map(function (c) {
      var sel = PB.wantCard && PB.wantCard.set === s.id && PB.wantCard.id === c.id;
      return '<button class="bounty-pick' + (sel ? ' selected' : '') + '" data-card="' + esc(c.id) + '">' +
        '<span class="bounty-pick-name">' + esc(c.name) + '</span>' +
        '<span class="pill r-' + c.rarity + '">' + esc(c.rarity) + '</span></button>';
    }).join('') || '<div class="muted small">No matches.</div>';
    grid.querySelectorAll('[data-card]').forEach(function (btn) {
      btn.addEventListener('click', function () {
        var card = s.byId.get(btn.getAttribute('data-card'));
        PB.wantCard = { set: s.id, id: card.id };
        pbRenderResults(box); pbRenderWantSel(box);
      });
    });
    pbRenderWantSel(box);
  }

  function pbRenderWantSel(box) {
    var t = box.querySelector('#pbWantSel');
    if (!PB.wantCard) { t.innerHTML = 'No card selected yet.'; return; }
    var card = cardObj(PB.wantCard.set, PB.wantCard.id);
    var extra = '';
    var v = PB.tier && CPS.cards.VARIANTS[PB.tier];
    if (PB.tier && PB.serial) extra = ' · ' + esc(v ? v.name + ' #' + PB.serial + '/' + v.run : PB.tier + ' #' + PB.serial);
    else if (PB.tier || PB.serial) extra = ' · <span class="warn">serial needs both tier and number</span>';
    t.innerHTML = 'Wanting: <b>' + esc(card ? card.name : PB.wantCard.id) + '</b> (' +
      (PB.holo === 'holo' ? 'holo only' : 'any copy') + ')' + extra;
  }

  function pbRenderOfferCards(box) {
    var t = box.querySelector('#pbOfferCards');
    t.innerHTML = PB.offerCards.map(function (o, i) {
      var card = cardObj(o.set, o.card);
      return '<span class="trade-chip"><b>' + esc(card ? card.name : o.card) + '</b>' +
        (o.holo ? ' ✦' : '') +
        '<button class="chip-x" data-rm="' + i + '" title="Remove">×</button></span>';
    }).join('') || '<span class="muted small">No cards offered yet.</span>';
    t.querySelectorAll('[data-rm]').forEach(function (x) {
      x.addEventListener('click', function () {
        PB.offerCards.splice(+x.getAttribute('data-rm'), 1);
        pbRenderOfferCards(box);
      });
    });
  }

  function pbRenderOfferGrid(box) {
    var s = setObj(PB.offerSet), grid = box.querySelector('#pbOfferGrid');
    if (!s) { grid.innerHTML = '<div class="muted small">No cards to offer.</div>'; return; }
    var q = (PB.offerQ || '').trim().toLowerCase();
    var vmap = variantCountMap(), st = ctx.ps({ id: s.id }), list = [];
    s.cards.forEach(function (c) {
      var e = st.cards[c.id];
      var avail = e ? e.n - (e.v || 0) - (vmap[s.id + ':' + c.id] || 0) : 0;
      if (avail <= 0) return;
      var used = PB.offerCards.filter(function (o) { return o.set === s.id && o.card === c.id; }).length;
      if (avail - used <= 0) return;
      if (q) {
        var hay = ('#' + c.num + ' ' + c.num + ' ' + c.name + ' ' + (c.subtitle || '')).toLowerCase();
        if (hay.indexOf(q) < 0) return;
      }
      list.push({ card: c, left: avail - used, holo: (e.h || 0) - (e.vh || 0) > 0 });
    });
    list.sort(function (x, y) { return sortByRarity(x.card, y.card); });
    list = list.slice(0, 40);
    grid.innerHTML = list.map(function (o) {
      return '<button class="bounty-pick" data-card="' + esc(o.card.id) + '">' +
        '<span class="bounty-pick-name">' + esc(o.card.name) + (o.holo ? ' ✦' : '') + '</span>' +
        '<span><span class="pill r-' + o.card.rarity + '">' + esc(o.card.rarity) + '</span>' +
        ' <span class="muted small">×' + o.left + '</span></span></button>';
    }).join('') || '<div class="muted small">No matches.</div>';
    grid.querySelectorAll('[data-card]').forEach(function (btn) {
      btn.addEventListener('click', function () { pbOfferAdd(box, s.id, btn.getAttribute('data-card')); });
    });
  }

  function pbOfferAdd(box, sid, cid) {
    if (PB.offerCards.length >= 5) { ctx.toast('At most 5 cards per bounty.', 'warn'); return; }
    var st = ctx.ps({ id: sid }), e = st.cards[cid] || { n: 0, h: 0 };
    var vmap = variantCountMap();
    var avail = e.n - (e.v || 0) - (vmap[sid + ':' + cid] || 0);
    var used = PB.offerCards.filter(function (o) { return o.set === sid && o.card === cid; }).length;
    if (used >= avail) { ctx.toast('No more copies to offer.', 'warn'); return; }
    var wantHolo = box.querySelector('#pbCardHolo').checked;
    var holoUsed = PB.offerCards.filter(function (o) { return o.set === sid && o.card === cid && o.holo; }).length;
    if (wantHolo && holoUsed >= (e.h || 0) - (e.vh || 0)) { ctx.toast('You don\'t have another holo copy on hand.', 'warn'); return; }
    PB.offerCards.push({ set: sid, card: cid, holo: wantHolo && (e.h || 0) - (e.vh || 0) > 0 });
    pbRenderOfferCards(box);
    pbRenderOfferGrid(box);
  }

  async function pbSubmit(box, btn) {
    if (!PB.wantCard) { ctx.toast('Pick the card you want first.', 'warn'); return; }
    var tokens = Math.max(0, parseInt(box.querySelector('#pbTokens').value, 10) || 0);
    var tickets = Math.max(0, parseInt(box.querySelector('#pbTickets').value, 10) || 0);
    var packSet = box.querySelector('#pbPackSet').value || null;
    var packs = Math.max(0, parseInt(box.querySelector('#pbPacks').value, 10) || 0);
    if (packSet && !packs) { ctx.toast('Set the pack count for your pack offer.', 'warn'); return; }
    if (!packSet) packs = 0;
    if (!tokens && !tickets && !packs && !PB.offerCards.length) {
      ctx.toast('Your bounty needs an offer — tokens, tickets, packs, or cards.', 'warn'); return;
    }
    var serial = (box.querySelector('#pbSerial').value || '').trim();
    if ((PB.tier && !serial) || (!PB.tier && serial)) {
      ctx.toast('A numbered serial needs both a tier and a number.', 'warn'); return;
    }
    btn.disabled = true;
    try {
      await CPS.cloud.call('post_bounty', {
        p_want: { set: PB.wantCard.set, card: PB.wantCard.id, holo: PB.holo,
                  tier: PB.tier || null, serial: serial || null },
        p_offer: { tokens: tokens, tickets: tickets, pack_set: packSet, packs: packs,
                   cards: PB.offerCards.map(function (o) { return { set: o.set, card: o.card, holo: o.holo }; }) }
      });
      ctx.closeModal();
      ctx.toast('Bounty posted!', 'good');
      ctx.audio.coin();
      await load(); await ctx.refreshCloud();
    } catch (e) { btn.disabled = false; ctx.cloudError(e); }
  }

  CPS.bounties = { render: render, refresh: load, updateBadge: updateBadge };
})(window.CPS);

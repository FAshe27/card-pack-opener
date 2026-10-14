/* Bounty Board: public standing offers for wanted cards.
   A player posts a bounty naming one wanted card (optional holo requirement
   or a numbered variant — one specific serial, or any number of a tier)
   plus an offer of game tokens, spin tickets,
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
    CPS._bountyNav = n; paintMarketNav();
  }

  /* --- Market nav badge: claimable bounties (this module's half) plus
     my listings with offers (trading.js's half, CPS._tradeNav), painted
     into #marketBadge by paintMarketNav. app.js's applyPrefsUI calls
     navBadge() on every state load — the games-badge pattern — so the
     count stays fresh app-wide, not just inside the Market view. A 20s
     cache keeps state-load bursts from re-fetching the board. */
  var navAt = 0, navBusy = false;
  function paintMarketNav() {
    var b = ctx.$('#marketBadge'); if (!b) return;
    var n = (CPS._bountyNav || 0) + (CPS._tradeNav || 0);
    b.textContent = n;
    b.classList.toggle('hidden', !(n > 0));
  }
  async function navBadge() {
    if (CPS.trading && CPS.trading.navBadge) CPS.trading.navBadge();
    if (!ctx.isCloud()) { CPS._bountyNav = 0; paintMarketNav(); return; }
    if (navBusy || Date.now() - navAt < 20000) { paintMarketNav(); return; }
    navBusy = true;
    try {
      var r = await CPS.cloud.call('list_bounties', {});
      navAt = Date.now();
      CPS._bountyNav = (r.bounties || []).filter(function (x) { return x.can_claim; }).length;
      paintMarketNav();
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

  /* Clickable card face for an offered card (same wrapper as wantFace,
     so bindCardClicks picks it up). '' when unresolvable — the caller
     falls back to the text line. */
  function offerCardFace(c) {
    var s = setObj(c.set_id), card = s && s.byId.get(c.card_id);
    if (!s || !card) return '';
    var tier = c.tier || c.variant_tier, serial = c.serial != null ? c.serial : c.variant_serial;
    var opts = { holo: !!c.holo };
    if (tier) opts.variant = { tier: tier, serial: serial };
    var variantAttr = tier ? ' data-variant-tier="' + esc(tier) + '" data-variant-serial="' + esc(serial) + '"' : '';
    return '<div class="bounty-card-click" data-set="' + esc(c.set_id) + '" data-card="' + esc(c.card_id) + '"' +
      ' data-holo="' + (c.holo ? '1' : '0') + '"' + variantAttr +
      ' style="cursor:pointer;" title="View card">' + CPS.cards.render(s, card, opts) + '</div>';
  }

  /* Offer body with faces: currency stays text lines, cards become
     clickable faces. */
  function offerBodyHtml(b) {
    var lines = [], faces = [];
    if (b.offer_tokens > 0) lines.push('<span class="bounty-offer-line">🪙 <b>' + b.offer_tokens + '</b> game token' + (b.offer_tokens === 1 ? '' : 's') + '</span>');
    if (b.offer_tickets > 0) lines.push('<span class="bounty-offer-line">🎟️ <b>' + b.offer_tickets + '</b> spin ticket' + (b.offer_tickets === 1 ? '' : 's') + '</span>');
    if (b.offer_packs > 0) {
      var ps = setObj(b.offer_pack_set);
      lines.push('<span class="bounty-offer-line">🎁 <b>' + b.offer_packs + '</b> ' + esc(ps ? ps.name : b.offer_pack_set) + ' pack' + (b.offer_packs === 1 ? '' : 's') + '</span>');
    }
    (b.offer_cards || []).forEach(function (c) {
      var f = offerCardFace(c);
      if (f) faces.push('<div class="bounty-want">' + f + '</div>');
      else {
        var s = setObj(c.set_id), card = s && s.byId.get(c.card_id);
        var rar = c.rarity || (card && card.rarity);
        lines.push('<span class="bounty-offer-line">🃏 <b>' + esc(c.card_name || (card && card.name) || c.card_id) + '</b>' +
          (c.holo ? ' ✦ holo' : '') + ' <span class="muted">(' + esc(c.set_name || (s && s.name) || c.set_id) +
          (rar ? ' · ' + esc(rar) : '') + ')</span></span>');
      }
    });
    var html = lines.join('');
    if (faces.length) html += '<div class="bounty-offerfaces">' + faces.join('') + '</div>';
    return html;
  }

  function bindCardClicks(scope) {
    if (!scope) return;
    scope.querySelectorAll('.bounty-card-click').forEach(function (el) {
      el.addEventListener('click', function (e) {
        e.stopPropagation();
        var vt = el.getAttribute('data-variant-tier');
        var variant = vt ? { tier: vt, serial: parseInt(el.getAttribute('data-variant-serial'), 10) } : null;
        ctx.openCardModal(el.getAttribute('data-set'), el.getAttribute('data-card'),
          el.getAttribute('data-holo') === '1', variant);
      });
    });
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
    if (b.want_tier) {
      // tier-only want (migration 141): any number of the variant
      var vt = CPS.cards.VARIANTS[b.want_tier];
      return 'Needs ' + (vt ? vt.name : b.want_tier) + ' — any number';
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
        '<div class="bounty-offer"><div class="bounty-want-label">OFFER</div>' + offerBodyHtml(b) +
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
    // Make bounty want + offer cards clickable -> open card modal
    bindCardClicks(box);
  }

  /* ------------------------------------------------------------ claim */
  function findBounty(id) {
    return B && B.bounties.filter(function (b) { return b.id === id; })[0];
  }

  function openClaimModal(id) {
    var b = findBounty(id); if (!b || !b.can_claim) return;
    var cardName = b.card_name || b.want_card;
    /* Tier-any want (migration 141): the claimer hands over one of their
       own held, unvaulted instances of the tier — picked here when they
       hold more than one, automatic (p_serial null) when exactly one. */
    var tierAny = !!(b.want_tier && !b.want_serial);
    var held = [];
    if (tierAny) {
      held = (ctx.S.myVariants || []).filter(function (v) {
        return v.set_id === b.want_set && v.card_id === b.want_card &&
          v.tier === b.want_tier && !v.vaulted;
      }).sort(function (x, y) { return x.serial - y.serial; });
    }
    var vInfo = tierAny ? CPS.cards.VARIANTS[b.want_tier] : null;
    var tierName = vInfo ? vInfo.name : b.want_tier;
    var chooserHtml = '';
    if (tierAny && held.length >= 2) {
      chooserHtml = '<div class="claim-serial-pick"><span class="muted small">You\'ll hand over:</span>' +
        held.map(function (v, i) {
          return '<label class="inline"><input type="radio" name="claimSerial" value="' + v.serial + '"' +
            (i === 0 ? ' checked' : '') + '> ' + esc(tierName) + ' #' + v.serial + '/' + (vInfo ? vInfo.run : '?') + '</label>';
        }).join('') + '</div>';
    }
    var noCopy = tierAny && held.length === 0;
    ctx.openModal(
      '<button class="modal-x" data-close aria-label="Close">×</button>' +
      '<h3>Claim bounty</h3>' +
      (noCopy
        ? '<p>You don\'t have an unvaulted ' + esc(tierName) + ' copy of <b>' + esc(cardName) +
          '</b> on hand to hand over — if yours is in the Vault, release it first.</p>' +
          '<div class="row wrap"><button class="btn" data-close>Never mind</button></div>'
        : '<p>Are you sure you want to trade:</p>' +
          '<div class="bounty-tradebox"><div><span class="bounty-want-label">YOU GIVE</span><b>' + esc(cardName) + '</b>' +
            '<div class="muted small">' + esc(wantReq(b)) + '</div></div>' +
          '<div class="bounty-trade-arrow">⇄</div>' +
          '<div><span class="bounty-want-label">YOU GET</span><div>' + offerBodyHtml(b) + '</div></div></div>' +
          chooserHtml +
          '<div class="row wrap"><button class="btn primary" id="bountyClaimGo">Claim bounty</button>' +
          '<button class="btn" data-close>Never mind</button></div>'),
      function (box) {
        box.querySelectorAll('[data-close]').forEach(function (x) {
          x.addEventListener('click', function () { ctx.closeModal(); });
        });
        bindCardClicks(box);
        var go = ctx.$('#bountyClaimGo', box);
        if (!go) return;
        go.addEventListener('click', async function () {
          var btn = this; btn.disabled = true;
          try {
            var args = { p_bounty_id: id };
            if (tierAny) {
              // Only tier-any claims carry p_serial; every other claim
              // keeps the exact pre-141 call shape.
              var sel = box.querySelector('input[name="claimSerial"]:checked');
              args.p_serial = sel ? parseInt(sel.value, 10) : null;
            }
            await CPS.cloud.call('claim_bounty', args);
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

  /* Phase 1 helpers: remembered sets (module-local storage; app.js's own
     last-set pref isn't exposed to modules). */
  function lsGet(k) { try { return window.localStorage.getItem(k) || ''; } catch (e) { return ''; } }
  function lsSet(k, v) { try { window.localStorage.setItem(k, v); } catch (e) { /* storage unavailable */ } }
  function countLine(total, shown, searching) {
    if (searching) return total + (total === 1 ? ' match' : ' matches') + (shown < total ? ' · showing ' + shown : '');
    if (shown < total) return total + ' cards · showing the ' + shown + ' rarest — type to search';
    return total + (total === 1 ? ' card' : ' cards');
  }

  async function openPostModal() {
    try { await ctx.ensureVariants(); } catch (e) { /* variants optional for posting */ }
    var sets = sortByName(window.CardSets.all().filter(function (s) { return s.id !== 'jumbled'; }));
    if (!PB) {
      // fresh form, seeded from the remembered sets (Phase 1 §1.6)
      PB = {
        sets: sets, wantSet: '', wantCard: null, q: '',
        offerSet: '', offerQ: '',
        holo: 'any', tier: '', serial: '', anyMode: false,
        tokens: 0, tickets: 0, packSet: '', packs: 0,
        offerCards: []   // {set, card, holo}
      };
      var rw = lsGet('cps.composerSet.want');
      PB.wantSet = sets.some(function (s) { return s.id === rw; }) ? rw : (sets[0] ? sets[0].id : '');
      var ro = lsGet('cps.composerSet.offer'), oSets = ownedSets();
      PB.offerSet = oSets.some(function (s) { return s.id === ro; }) ? ro : (oSets[0] ? oSets[0].id : '');
    }
    PB.sets = sets;
    if (!sets.some(function (s) { return s.id === PB.wantSet; })) PB.wantSet = sets[0] ? sets[0].id : '';
    pbShowForm();
  }

  function pbShowForm() {
    ctx.openModal(
      '<button class="modal-x" data-close aria-label="Close">×</button>' +
      '<h3>Post a bounty</h3>' +
      (B ? '<div class="muted small">Open bounties: ' + (B.my_open || 0) + ' of 5</div>' : '') +
      '<div class="bounty-form">' +
      '<h4>You want</h4>' +
      '<div class="row wrap"><label>Set <select id="pbSet"></select></label>' +
      '<label>Search <input id="pbSearch" placeholder="card name or #" size="18"></label></div>' +
      '<div id="pbWantSel" class="pb-pin"></div>' +
      '<div id="pbCardCount" class="muted small picker-count"></div>' +
      '<div id="pbCardResults" class="bounty-pick-grid"></div>' +
      '<div class="row wrap"><span class="muted small">Copy needed:</span>' +
      '<label class="inline"><input type="radio" name="pbHolo" value="any" checked> Any copy</label>' +
      '<label class="inline"><input type="radio" name="pbHolo" value="holo"> Holo only</label></div>' +
      '<div class="row wrap"><span class="muted small">Numbered serial (optional):</span>' +
      '<select id="pbTier"><option value="">—</option><option value="rainbow">Rainbow /50</option>' +
      '<option value="prism">Prism /10</option><option value="obsidian">Obsidian /5</option>' +
      '<option value="oneofone">One-of-One</option></select>' +
      '<input id="pbSerial" type="number" min="1" placeholder="#" style="width:64px;flex:none">' +
      '<label class="inline"><input type="checkbox" id="pbAnyNum"> Any number</label>' +
      '<span class="muted small" id="pbTierHint"></span></div>' +
      '<h4>You offer</h4>' +
      '<div class="row wrap"><label>🪙 Tokens <input id="pbTokens" type="number" min="0" max="' + (ctx.S.gameTokens || 0) +
        '" value="0" style="width:80px"></label><span class="muted small" id="pbTokensHave"></span>' +
      '<label>🎟️ Tickets <input id="pbTickets" type="number" min="0" max="' + (ctx.S.spins || 0) +
        '" value="0" style="width:80px"></label><span class="muted small" id="pbTicketsHave"></span></div>' +
      '<div class="row wrap"><label>🎁 Packs <select id="pbPackSet"></select></label>' +
      '<input id="pbPacks" type="number" min="0" value="0" style="width:70px"><span class="muted small" id="pbPacksHave"></span></div>' +
      '<div class="row wrap"><label>🃏 Card <select id="pbCardSet"></select></label>' +
      '<label>Search <input id="pbCardSearch" placeholder="card name or #" size="18"></label></div>' +
      '<div id="pbOfferCount" class="muted small picker-count"></div>' +
      '<div id="pbOfferGrid" class="bounty-pick-grid"></div>' +
      '<div class="row wrap"><label class="inline"><input type="checkbox" id="pbCardHolo"> add as holo</label>' +
      '<span class="muted small">tap a card to add it to your offer (up to 5)</span></div>' +
      '<div id="pbOfferCards" class="bounty-offer-chips"></div>' +
      '<p class="muted small">Your offer is held in escrow until the bounty is claimed, cancelled, or expires (7 days).</p>' +
      '<div class="bounty-footer"><span class="bounty-recap" id="pbRecap"></span>' +
      '<button class="btn primary big" id="pbGo">Review bounty →</button>' +
      '<button class="btn" data-close>Cancel</button>' +
      '<button class="btn small" id="pbStartOver">Start over</button></div>' +
      '</div>',
      bindPostModal);
  }

  /* Collect every DOM field into PB (the review screen replaces the form,
     so the submit path reads state, never the DOM). */
  function pbCollect(box) {
    PB.tokens = Math.max(0, parseInt(box.querySelector('#pbTokens').value, 10) || 0);
    PB.tickets = Math.max(0, parseInt(box.querySelector('#pbTickets').value, 10) || 0);
    PB.packSet = box.querySelector('#pbPackSet').value || '';
    PB.packs = Math.max(0, parseInt(box.querySelector('#pbPacks').value, 10) || 0);
    PB.serial = box.querySelector('#pbSerial').value || '';
    PB.anyMode = !!box.querySelector('#pbAnyNum').checked;
    pbClampSerial(box);
  }

  /* The same checks, in the same order, with the same messages as the old
     direct submit. */
  function pbValidate() {
    if (!PB.wantCard) { ctx.toast('Pick the card you want first.', 'warn'); return false; }
    if (PB.packSet && !PB.packs) { ctx.toast('Set the pack count for your pack offer.', 'warn'); return false; }
    var packs = PB.packSet ? PB.packs : 0;
    if (!PB.tokens && !PB.tickets && !packs && !PB.offerCards.length) {
      ctx.toast('Your bounty needs an offer — tokens, tickets, packs, or cards.', 'warn'); return false;
    }
    var serial = (PB.serial || '').trim();
    // Any number (migration 141) satisfies a tier on its own; a serial
    // still needs a tier, and a tier alone still needs one or the other.
    if ((!PB.tier && serial) || (PB.tier && !serial && !PB.anyMode)) {
      ctx.toast('A numbered serial needs both a tier and a number.', 'warn'); return false;
    }
    return true;
  }

  function pbReview(box) {
    pbCollect(box);
    if (!pbValidate()) return;
    var serial = (PB.serial || '').trim();
    var offer = {
      offer_tokens: PB.tokens, offer_tickets: PB.tickets,
      offer_packs: PB.packSet ? PB.packs : 0, offer_pack_set: PB.packSet || null,
      offer_cards: PB.offerCards.map(function (o) { return { set_id: o.set, card_id: o.card, holo: o.holo }; })
    };
    var want = {
      want_set: PB.wantCard.set, want_card: PB.wantCard.id, want_holo: PB.holo,
      want_tier: PB.tier || null, want_serial: PB.anyMode ? null : (serial || null)
    };
    ctx.openModal(
      '<button class="modal-x" data-close aria-label="Close">×</button>' +
      '<h3>Review your bounty</h3>' +
      '<div class="bounty-tradebox"><div><span class="bounty-want-label">YOU GIVE</span><div>' + offerBodyHtml(offer) + '</div></div>' +
      '<div class="bounty-trade-arrow">⇄</div>' +
      '<div><span class="bounty-want-label">YOU GET</span><div class="bounty-want">' + wantFace(want) + '</div>' +
      '<div class="bounty-req">' + esc(wantReq(want)) + '</div></div></div>' +
      '<p class="muted small">Your offer is held in escrow until the bounty is claimed, cancelled, or expires (7 days).</p>' +
      '<div class="row wrap"><button class="btn" id="pbBack">← Back</button>' +
      '<button class="btn primary big" id="pbConfirm">Post bounty — escrow my offer</button></div>',
      function (rbox) {
        rbox.querySelectorAll('[data-close]').forEach(function (x) {
          x.addEventListener('click', function () { ctx.closeModal(); });
        });
        bindCardClicks(rbox);
        rbox.querySelector('#pbBack').addEventListener('click', function () { pbShowForm(); });
        rbox.querySelector('#pbConfirm').addEventListener('click', function () { pbDoSubmit(this); });
      });
  }

  /* The old pbSubmit body, reading PB instead of the DOM. The RPC params
     are byte-identical to the pre-review-step submit (pinned by the
     golden-params harness). */
  async function pbDoSubmit(btn) {
    var serial = (PB.serial || '').trim();
    btn.disabled = true;
    try {
      await CPS.cloud.call('post_bounty', {
        p_want: { set: PB.wantCard.set, card: PB.wantCard.id, holo: PB.holo,
                  tier: PB.tier || null, serial: PB.anyMode ? null : (serial || null) },
        p_offer: { tokens: PB.tokens, tickets: PB.tickets, pack_set: PB.packSet || null,
                   packs: PB.packSet ? PB.packs : 0,
                   cards: PB.offerCards.map(function (o) { return { set: o.set, card: o.card, holo: o.holo }; }) }
      });
      PB = null;   // posted — the next open starts fresh
      ctx.closeModal();
      ctx.toast('Bounty posted!', 'good');
      ctx.audio.coin();
      await load(); await ctx.refreshCloud();
    } catch (e) { btn.disabled = false; ctx.cloudError(e); }
  }

  function pbRecap(box) {
    var t = box.querySelector('#pbRecap'); if (!t) return;
    var want = 'Nothing wanted yet';
    if (PB.wantCard) {
      var c = cardObj(PB.wantCard.set, PB.wantCard.id);
      want = 'Wanting ' + (c ? c.name : PB.wantCard.id);
    }
    var bits = [];
    if (PB.tokens > 0) bits.push('🪙 ' + PB.tokens + ' token' + (PB.tokens === 1 ? '' : 's'));
    if (PB.tickets > 0) bits.push('🎟️ ' + PB.tickets + ' ticket' + (PB.tickets === 1 ? '' : 's'));
    if (PB.packSet && PB.packs > 0) {
      var ps = setObj(PB.packSet);
      bits.push('🎁 ' + PB.packs + ' ' + (ps ? ps.name : PB.packSet) + ' pack' + (PB.packs === 1 ? '' : 's'));
    }
    PB.offerCards.forEach(function (o) {
      var oc = cardObj(o.set, o.card);
      bits.push('🃏 ' + (oc ? oc.name : o.card) + (o.holo ? ' ✦' : ''));
    });
    t.textContent = want + ' · Offering ' + (bits.length ? bits.join(' + ') : 'nothing yet');
  }

  function pbRenderMoneyHints(box) {
    var th = box.querySelector('#pbTokensHave'), kh = box.querySelector('#pbTicketsHave');
    if (th) th.textContent = 'You have ' + (ctx.S.gameTokens || 0) + ' · ' + Math.max(0, (ctx.S.gameTokens || 0) - PB.tokens) + ' left after';
    if (kh) kh.textContent = 'You have ' + (ctx.S.spins || 0) + ' · ' + Math.max(0, (ctx.S.spins || 0) - PB.tickets) + ' left after';
  }

  /* Numbered-serial sanity (Phase 1 §1.5): tiers only exist on Rare+
     cards, and the serial can't exceed the tier's run. Any number
     (migration 141) lets a tier go without a serial — ticking it
     disables the serial input, and it only exists alongside a tier. */
  function pbSyncTier(box) {
    var tierSel = box.querySelector('#pbTier'), serialInp = box.querySelector('#pbSerial');
    var anyChk = box.querySelector('#pbAnyNum');
    var hint = box.querySelector('#pbTierHint');
    if (!tierSel || !serialInp) return;
    var card = PB.wantCard ? cardObj(PB.wantCard.set, PB.wantCard.id) : null;
    var rarePlus = !!card && (ctx.R.INDEX[card.rarity] || 0) >= (ctx.R.INDEX.rare || 2);
    if (!rarePlus && PB.tier) {
      PB.tier = ''; PB.serial = '';
      tierSel.value = ''; serialInp.value = '';
      pbRenderWantSel(box);
    }
    if (!PB.tier) PB.anyMode = false;
    if (anyChk) { anyChk.checked = !!PB.anyMode; anyChk.disabled = !rarePlus || !PB.tier; }
    tierSel.disabled = !rarePlus;
    serialInp.disabled = !rarePlus || !PB.tier || PB.anyMode;
    if (hint) hint.textContent = card && !rarePlus ? 'Numbered serials need a Rare or better card.' : '';
    pbClampSerial(box);
  }

  function pbClampSerial(box) {
    if (!PB.tier) return;
    var v = CPS.cards.VARIANTS[PB.tier]; if (!v) return;
    var n = parseInt(PB.serial, 10);
    if (isNaN(n)) return;
    var c = Math.max(1, Math.min(v.run, n));
    if (String(c) !== String(PB.serial).trim()) {
      PB.serial = String(c);
      var inp = box.querySelector('#pbSerial'); if (inp) inp.value = PB.serial;
      pbRenderWantSel(box);
    }
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
    setSel.addEventListener('change', function () {
      PB.wantSet = setSel.value; lsSet('cps.composerSet.want', PB.wantSet);
      PB.q = ''; box.querySelector('#pbSearch').value = ''; pbRenderResults(box);
    });

    var q = box.querySelector('#pbSearch');
    q.value = PB.q;
    q.addEventListener('input', function () { PB.q = q.value; pbRenderResults(box); });

    box.querySelectorAll('input[name="pbHolo"]').forEach(function (r) {
      r.checked = (PB.holo === r.value);
      r.addEventListener('change', function () { PB.holo = r.value; pbRenderWantSel(box); });
    });
    var tierSel = box.querySelector('#pbTier');
    tierSel.value = PB.tier;
    tierSel.addEventListener('change', function (e) { PB.tier = e.target.value; pbSyncTier(box); pbRenderWantSel(box); });
    var serialInp = box.querySelector('#pbSerial');
    serialInp.value = PB.serial;
    serialInp.addEventListener('input', function (e) { PB.serial = e.target.value; pbRenderWantSel(box); });
    serialInp.addEventListener('change', function () { pbClampSerial(box); });
    var anyChk = box.querySelector('#pbAnyNum');
    anyChk.checked = !!PB.anyMode;
    anyChk.addEventListener('change', function () {
      PB.anyMode = anyChk.checked;
      pbSyncTier(box);
      pbRenderWantSel(box);
    });

    // currency: keep PB in sync as you type; clamp to balance on change
    function bindMoney(inputSel, key, balance) {
      var inp = box.querySelector(inputSel);
      inp.value = PB[key];
      inp.addEventListener('input', function () {
        PB[key] = Math.max(0, parseInt(inp.value, 10) || 0);
        pbRenderMoneyHints(box); pbRecap(box);
      });
      inp.addEventListener('change', function () {
        var v = Math.max(0, Math.min(balance, parseInt(inp.value, 10) || 0));
        inp.value = v; PB[key] = v;
        pbRenderMoneyHints(box); pbRecap(box);
      });
    }
    bindMoney('#pbTokens', 'tokens', ctx.S.gameTokens || 0);
    bindMoney('#pbTickets', 'tickets', ctx.S.spins || 0);

    // pack offer: count disabled until a set is chosen, clamped to holdings
    var packSet = box.querySelector('#pbPackSet'), packsHave = box.querySelector('#pbPacksHave');
    var packsInp = box.querySelector('#pbPacks');
    var invSets = PB.sets.filter(function (s) { return (ctx.ps({ id: s.id }).packs || 0) > 0; });
    packSet.innerHTML = '<option value="">—</option>' + invSets.map(function (s) {
      return '<option value="' + esc(s.id) + '">' + esc(s.name) + ' (' + ctx.ps({ id: s.id }).packs + ')</option>';
    }).join('');
    packSet.value = PB.packSet;
    function syncPacks() {
      PB.packSet = packSet.value;
      var n = PB.packSet ? (ctx.ps({ id: PB.packSet }).packs || 0) : 0;
      packsHave.textContent = PB.packSet ? 'you have ' + n : '';
      packsInp.disabled = !PB.packSet;
      packsInp.max = n;
      PB.packs = Math.max(0, Math.min(n, PB.packs || 0));
      packsInp.value = PB.packs;
      pbRecap(box);
    }
    packSet.addEventListener('change', syncPacks);
    packsInp.addEventListener('input', function () {
      PB.packs = Math.max(0, parseInt(packsInp.value, 10) || 0);
      pbRecap(box);
    });
    packsInp.addEventListener('change', syncPacks);
    syncPacks();

    // offer-card picker (same pick-grid pattern as "You want": tap a card to add it)
    var oSets = ownedSets();
    if (!oSets.some(function (s) { return s.id === PB.offerSet; })) PB.offerSet = oSets[0] ? oSets[0].id : '';
    var oSetSel = box.querySelector('#pbCardSet');
    oSetSel.innerHTML = oSets.map(function (s) {
      return '<option value="' + esc(s.id) + '">' + esc(s.name) + '</option>';
    }).join('');
    oSetSel.value = PB.offerSet;
    oSetSel.addEventListener('change', function () {
      PB.offerSet = oSetSel.value; lsSet('cps.composerSet.offer', PB.offerSet);
      PB.offerQ = '';
      box.querySelector('#pbCardSearch').value = '';
      pbRenderOfferGrid(box);
    });
    var oSearch = box.querySelector('#pbCardSearch');
    oSearch.value = PB.offerQ;
    oSearch.addEventListener('input', function (e) {
      PB.offerQ = e.target.value; pbRenderOfferGrid(box);
    });
    pbRenderOfferGrid(box);

    box.querySelector('#pbGo').addEventListener('click', function () { pbReview(box); });
    box.querySelector('#pbStartOver').addEventListener('click', function () { PB = null; openPostModal(); });
    pbRenderResults(box);
    pbRenderOfferCards(box);
    pbRenderMoneyHints(box);
    pbSyncTier(box);
    pbRecap(box);
    q.focus();
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
    var matched = list.length;
    list = list.slice(0, 40);
    var cl = box.querySelector('#pbCardCount');
    if (cl) cl.textContent = countLine(matched, list.length, !!q);
    grid.innerHTML = list.map(function (c) {
      var sel = PB.wantCard && PB.wantCard.set === s.id && PB.wantCard.id === c.id;
      return '<button class="bounty-pick' + (sel ? ' selected' : '') + '" data-card="' + esc(c.id) + '">' +
        '<span class="bounty-pick-name">' + esc(c.name) + '</span>' +
        '<span><span class="muted small">#' + c.num + '</span> ' +
        '<span class="pill r-' + c.rarity + '">' + esc(c.rarity) + '</span></span></button>';
    }).join('') || '<div class="muted small">No matches.</div>';
    grid.querySelectorAll('[data-card]').forEach(function (btn) {
      btn.addEventListener('click', function () {
        var card = s.byId.get(btn.getAttribute('data-card'));
        PB.wantCard = { set: s.id, id: card.id };
        pbRenderResults(box); pbRenderWantSel(box); pbSyncTier(box);
      });
    });
    pbRenderWantSel(box);
  }

  function pbRenderWantSel(box) {
    var t = box.querySelector('#pbWantSel');
    if (!PB.wantCard) { t.innerHTML = '<span class="muted small">No card selected yet.</span>'; pbRecap(box); return; }
    var card = cardObj(PB.wantCard.set, PB.wantCard.id);
    var extra = '';
    var v = PB.tier && CPS.cards.VARIANTS[PB.tier];
    if (PB.tier && PB.anyMode) extra = ' · ' + esc(v ? v.name : PB.tier) + ' — any number';
    else if (PB.tier && PB.serial) extra = ' · ' + esc(v ? v.name + ' #' + PB.serial + '/' + v.run : PB.tier + ' #' + PB.serial);
    else if (PB.tier || PB.serial) extra = ' · <span class="warn">serial needs both tier and number</span>';
    var shaped = {
      want_set: PB.wantCard.set, want_card: PB.wantCard.id, want_holo: PB.holo,
      want_tier: PB.tier || null, want_serial: PB.anyMode ? null : (PB.serial || null)
    };
    t.innerHTML = '<div class="bounty-want">' + wantFace(shaped) + '</div>' +
      '<div class="pb-pin-text"><b>' + esc(card ? card.name : PB.wantCard.id) + '</b>' +
      (card ? ' <span class="pill r-' + card.rarity + '">' + esc(card.rarity) + '</span>' : '') +
      '<div class="muted small">Wanting (' + (PB.holo === 'holo' ? 'holo only' : 'any copy') + ')' + extra + '</div></div>';
    bindCardClicks(t);
    pbRecap(box);
  }

  function pbRenderOfferCards(box) {
    var t = box.querySelector('#pbOfferCards');
    t.innerHTML = PB.offerCards.map(function (o, i) {
      var card = cardObj(o.set, o.card), s = setObj(o.set);
      return '<span class="trade-chip"><b>' + esc(card ? card.name : o.card) + '</b>' +
        (o.holo ? ' ✦' : '') +
        ' <span class="muted small">(' + esc(s ? s.name : o.set) + ')</span>' +
        '<button class="chip-x" data-rm="' + i + '" title="Remove">×</button></span>';
    }).join('') || '<span class="muted small">No cards offered yet.</span>';
    t.querySelectorAll('[data-rm]').forEach(function (x) {
      x.addEventListener('click', function () {
        PB.offerCards.splice(+x.getAttribute('data-rm'), 1);
        pbRenderOfferCards(box);
        pbRenderOfferGrid(box);
      });
    });
    pbRecap(box);
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
    var matched = list.length;
    list = list.slice(0, 40);
    var cl = box.querySelector('#pbOfferCount');
    if (cl) cl.textContent = countLine(matched, list.length, !!q);
    grid.innerHTML = list.map(function (o) {
      return '<button class="bounty-pick" data-card="' + esc(o.card.id) + '">' +
        '<span class="bounty-pick-name">' + esc(o.card.name) + (o.holo ? ' ✦' : '') + '</span>' +
        '<span><span class="muted small">#' + o.card.num + '</span> ' +
        '<span class="pill r-' + o.card.rarity + '">' + esc(o.card.rarity) + '</span>' +
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
    if (!wantHolo) {
      // Mirror of the holo check above: a plain add needs a plain copy on
      // hand — (n - h) - (v - vh). This is the client half of the
      // migration-139 incident: offering the plain copy of a holo-only
      // card used to sail through and die on the server.
      var plainOn = (e.n - (e.h || 0)) - ((e.v || 0) - (e.vh || 0));
      var plainUsed = PB.offerCards.filter(function (o) { return o.set === sid && o.card === cid && !o.holo; }).length;
      if (plainUsed >= plainOn) { ctx.toast('You don\'t have another plain copy on hand.', 'warn'); return; }
    }
    PB.offerCards.push({ set: sid, card: cid, holo: wantHolo && (e.h || 0) - (e.vh || 0) > 0 });
    pbRenderOfferCards(box);
    pbRenderOfferGrid(box);
  }

  CPS.bounties = { render: render, refresh: load, updateBadge: updateBadge, navBadge: navBadge, paintMarketNav: paintMarketNav };
  CPS.paintMarketNav = paintMarketNav;
})(window.CPS);

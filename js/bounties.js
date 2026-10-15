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

  function variantTag(c) {
    if (!c.tier) return '';
    var v = CPS.cards.VARIANTS[c.tier];
    return ' ' + (v ? v.emoji : '') + ' #' + c.serial + '/' + (v ? v.run : '');
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
        (c.holo ? ' ✦ holo' : '') + variantTag(c) + ' <span class="muted">(' + esc(c.set_name || (s && s.name) || c.set_id) +
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
          (c.holo ? ' ✦ holo' : '') + variantTag(c) + ' <span class="muted">(' + esc(c.set_name || (s && s.name) || c.set_id) +
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

  /* ------------------------------------------------------------ composer host
     The post-bounty form lives in js/composer.js (CPS.composer) since
     Phase 2 — shared with the Trading Post's listing + offer forms.
     This module keeps the board, claim and cancel, and lends the
     composer its board renderers via this adapter. */
  var COMPOSER_HOST = {
    wantFace: wantFace,
    wantReq: wantReq,
    offerBodyHtml: offerBodyHtml,
    bindCardClicks: bindCardClicks,
    myOpen: function () { return B ? (B.my_open || 0) : null; },
    offerSets: function () { return ownedSets(); },
    onPosted: function () { ctx.closeModal(); load(); }
  };

  /* Opens the shared composer. prefill (optional, §2.2):
     { setId, cardId, copy: {holo:true} | {tier, serial}, fromCard }.
     Board buttons pass the click event — the composer ignores it. */
  async function openPostModal(prefill) {
    try { await ctx.ensureVariants(); } catch (e) { /* variants optional for posting */ }
    CPS.composer.openBounty(COMPOSER_HOST, prefill);
  }

  CPS.bounties = { render: render, refresh: load, updateBadge: updateBadge, navBadge: navBadge, paintMarketNav: paintMarketNav, openPost: openPostModal,
    /* Phase 3 (§3.6): my open bounties from the already-loaded board —
       best-effort, never a fetch. (The composer host's myOpen() is a
       count for form headers; this one returns the bounty rows.) */
    myOpen: function () { return B ? B.bounties.filter(function (b) { return b.mine; }) : null; } };
  CPS.paintMarketNav = paintMarketNav;
})(window.CPS);

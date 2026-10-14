/* js/popfill.js — card modal extras, filled after app.js renders the
   modal: (1) population numbers ("Times pulled" / "Currently existing")
   from public.cps_card_population, and (2) since Phase 3 of the Market
   composer package, the "Your copies" panel — a Steam-style grid of the
   viewer's own copies of the card with a per-copy action bar (List /
   Vault / Gift / Place a bounty) that opens the Phase 2 composers
   pre-filled. Both live here because app.js is at its push-size
   ceiling (the kernel counts UTF-8 bytes, and app.js is full of
   emoji). app.js's openCardModal calls CPS.popfill(box, set, card)
   next to fillCensus. "pulled" counts pack openings by real players
   only (migration 137) — the same population "total" is counted over,
   so the two subtract cleanly. */
(function () {
  window.CPS = window.CPS || {};

  /* ------------------------------------------------ population */
  async function fillPopulation(box, set, card) {
    var el = box.querySelector('#cardPop'), p2 = box.querySelector('#cardPulled');
    if (!el) return;
    var S = CPS.appCtx && CPS.appCtx.S;
    if (!S || S.mode !== 'cloud') { el.textContent = '—'; if (p2) p2.textContent = '—'; return; }
    try {
      var pop = await CPS.cloud.call('card_population', { p_set: set.id, p_card: card.id });
      if (el.isConnected) {
        el.textContent = pop.total + ' cop' + (pop.total === 1 ? 'y' : 'ies') +
          (pop.holos ? ' (' + pop.holos + ' holo)' : '');
        if (p2) p2.textContent = pop.pulled ?? '—';
      }
    } catch (e) {
      if (el.isConnected) { el.textContent = '—'; if (p2) p2.textContent = '—'; }
    }
  }

  /* ------------------------------------------------ Your copies (Phase 3)
     Viewer-relative by construction: every count below comes from
     CPS.appCtx state (ps / S.myVariants), which is always the
     signed-in viewer's — even when this modal was opened from another
     player's profile or vault. Copy math mirrors js/composer.js (the
     shipped "gifting-style" convention): a numbered variant's base
     slot is inside e.n but is neither plain nor holo, so the regular
     pools subtract the instance count (vn) before splitting:
       plainOn = (n − vn − v) − (h − vh)   holoOn = h − vh
       plainV  = v − vh                    holoV  = vh              */
  var STACK_MAX = 8;   // plain on-hand tiles collapse above this (§3.4)

  function variantLabel(tier, serial) {
    var V = CPS.cards.VARIANTS[tier];
    return V ? V.name + ' #' + serial + '/' + V.run : tier + ' #' + serial;
  }
  function variantStrip(tier, serial) {
    var V = CPS.cards.VARIANTS[tier];
    return V ? V.emoji + ' ' + V.name + ' #' + serial + '/' + V.run : tier + ' #' + serial;
  }
  function copyCounts(e, vn) {
    e = e || { n: 0, h: 0, v: 0, vh: 0 };
    var v = e.v || 0, vh = e.vh || 0;
    var holoOn = Math.max(0, (e.h || 0) - vh);
    return {
      holoOn: holoOn,
      plainOn: Math.max(0, (e.n - vn - v) - holoOn),
      plainV: Math.max(0, v - vh),
      holoV: Math.max(0, vh)
    };
  }
  function myInstances(S, set, card) {
    return (S.myVariants || []).filter(function (x) {
      return x.set_id === set.id && x.card_id === card.id;
    }).sort(function (a, b) {
      if (a.serial !== b.serial) return a.serial - b.serial;
      return a.tier < b.tier ? -1 : (a.tier > b.tier ? 1 : 0);
    });
  }
  function myGhosts(set, card) {
    if (!CPS.trading || !CPS.trading.myListings) return [];
    var mine = CPS.trading.myListings();
    if (!mine) return [];
    return mine.filter(function (l) { return l.set_id === set.id && l.card_id === card.id; });
  }
  function hasOpenBounty(set, card) {
    if (!CPS.bounties || !CPS.bounties.myOpen) return false;
    var mine = CPS.bounties.myOpen();
    if (!mine) return false;
    return mine.some(function (b) { return b.want_set === set.id && b.want_card === card.id; });
  }
  /* The card this modal was opened on, recovered from the rendered
     modal itself (popfill only receives box/set/card): the Variant
     row in the info list names tier + serial, and a holo face carries
     the .holo class. Used as fromCard for the composers (§2.3) and to
     re-open this modal after a vault action, exactly as the modal's
     own Vault box does with its original (forceHolo, variant). */
  function modalFromCard(box, set, card) {
    var variant = null, holo = false;
    var face = box.querySelector('.zoom-card .card');
    if (face) holo = face.classList.contains('holo');
    var dts = box.querySelectorAll('.zoom-info dt');
    for (var i = 0; i < dts.length; i++) {
      if (dts[i].textContent.trim() !== 'Variant') continue;
      var dd = dts[i].nextElementSibling, txt = dd ? dd.textContent : '';
      var V = CPS.cards.VARIANTS;
      for (var t in V) {
        if (txt.indexOf(V[t].name) === 0) {
          var m = txt.match(/#(\d+)\//);
          if (m) variant = { tier: t, serial: parseInt(m[1], 10) };
          break;
        }
      }
    }
    return { setId: set.id, cardId: card.id, holo: holo, variant: variant };
  }

  function renderCopies(box, set, card) {
    var ctx = CPS.appCtx, S = ctx && ctx.S;
    if (!ctx || !S) return;
    var info = box.querySelector('.zoom-info');
    if (!info) return;
    var old = info.querySelector('.copies-panel');
    if (old) old.remove();
    var panel = box.ownerDocument.createElement('div');
    panel.className = 'copies-panel';
    info.appendChild(panel);
    var view = {
      box: box, set: set, card: card, panel: panel,
      expanded: false, touched: false, selKey: undefined, tiles: [], sel: null,
      fromCard: modalFromCard(box, set, card)
    };
    panel.addEventListener('click', function (ev) {
      var tb = ev.target.closest('[data-tile]');
      if (tb && panel.contains(tb)) { tileClick(view, tb.getAttribute('data-tile')); return; }
      var ab = ev.target.closest('[data-act]');
      if (ab && panel.contains(ab) && !ab.disabled) actClick(view, ab.getAttribute('data-act'), ab);
    });
    paintPanel(view);
    /* Stage 2 (§3.1): variant instances may still be loading. When
       they land, repaint the whole panel from fresh state — guarded
       so a stale panel from a replaced modal never repaints. */
    if (ctx.ensureVariants) {
      var pr = null;
      try { pr = ctx.ensureVariants(); } catch (e) { pr = null; }
      if (pr && pr.then) pr.then(function () {
        if (!panel.isConnected || box.querySelector('.copies-panel') !== panel) return;
        paintPanel(view);
      }, function () { /* stage-1 render stands */ });
    }
  }

  function buildTiles(view, e, insts, ghosts) {
    var c = copyCounts(e, insts.length);
    var tiles = [];
    insts.forEach(function (inst) {
      tiles.push({ kind: 'variant', key: 'variant:' + inst.id, inst: inst, vaulted: !!inst.vaulted });
    });
    /* Keys are unique PER POSITION within a kind: fungible copies share
       a kind, and a bare-kind key made the selection resolver's
       first-match land on tile #1 no matter which copy was clicked —
       the clicked tile appeared to jump to the front (Franklin,
       2026-10-14). Enumeration order is deterministic, so a positional
       key is a stable identity across repaints. */
    for (var i = 0; i < c.holoOn; i++) tiles.push({ kind: 'holo', key: 'holo:' + i, vaulted: false });
    if (c.plainOn > STACK_MAX && !view.expanded) {
      tiles.push({ kind: 'stack', key: 'stack', count: c.plainOn, vaulted: false });
    } else {
      for (var j = 0; j < c.plainOn; j++) tiles.push({ kind: 'plain', key: 'plain:' + j, vaulted: false });
      if (c.plainOn > STACK_MAX) tiles.push({ kind: 'collapse', key: 'collapse', vaulted: false });
    }
    for (var k = 0; k < c.holoV; k++) tiles.push({ kind: 'holoVault', key: 'holoVault:' + k, vaulted: true });
    for (var m = 0; m < c.plainV; m++) tiles.push({ kind: 'plainVault', key: 'plainVault:' + m, vaulted: true });
    ghosts.forEach(function (l, gi) { tiles.push({ kind: 'ghost', key: 'ghost:' + gi, listing: l, vaulted: false }); });
    return tiles;
  }
  function selectable(t) { return t.kind !== 'ghost' && t.kind !== 'stack' && t.kind !== 'collapse'; }

  function tileFace(view, t) {
    if (t.kind === 'variant') return CPS.cards.render(view.set, view.card, { variant: { tier: t.inst.tier, serial: t.inst.serial } });
    if (t.kind === 'holo' || t.kind === 'holoVault') return CPS.cards.render(view.set, view.card, { holo: true });
    if (t.kind === 'ghost') {
      var l = t.listing, opts = { holo: !!l.holo };
      if (l.variant_tier) opts.variant = { tier: l.variant_tier, serial: l.variant_serial };
      return CPS.cards.render(view.set, view.card, opts);
    }
    return CPS.cards.render(view.set, view.card, {});
  }
  function tileStrip(view, t) {
    var esc = CPS.appCtx.esc;
    if (t.kind === 'variant') {
      var s = variantStrip(t.inst.tier, t.inst.serial);
      if (view.card.rarity === 'common' || view.card.rarity === 'uncommon') {
        s += ' <span class="copies-misprint">MISPRINT</span>';
      }
      return s;
    }
    if (t.kind === 'holo') return '✦ Holo';
    if (t.kind === 'holoVault') return '✦ Holo · Vault';
    if (t.kind === 'plain') return 'Plain';
    if (t.kind === 'plainVault') return 'Plain · Vault';
    if (t.kind === 'stack') return 'tap to expand';
    if (t.kind === 'ghost') {
      var l = t.listing;
      if (l.variant_tier) return esc(variantStrip(l.variant_tier, l.variant_serial)) + ' · Listed';
      return (l.holo ? '✦ Holo · Listed' : 'Listed');
    }
    return '';
  }
  function tileBadge(t) {
    if (t.kind === 'stack') return '×' + t.count;
    if (t.vaulted) return '🔒';
    if (t.kind === 'holo' || t.kind === 'holoVault') return '✦';
    return '';
  }
  function actingLabel(t) {
    if (!t) return '';
    if (t.kind === 'variant') return variantLabel(t.inst.tier, t.inst.serial) + (t.vaulted ? ' (vaulted)' : '');
    if (t.kind === 'holo' || t.kind === 'holoVault') return 'a holo copy' + (t.vaulted ? ' (vaulted)' : '');
    return 'a plain copy' + (t.vaulted ? ' (vaulted)' : '');
  }

  function paintPanel(view) {
    var ctx = CPS.appCtx, S = ctx.S, esc = ctx.esc;
    var set = view.set, card = view.card;
    var e = ctx.ps(set).cards[card.id];
    var insts = myInstances(S, set, card);
    var ghosts = myGhosts(set, card);
    var bountyLine = hasOpenBounty(set, card) ?
      '<div class="copies-bountyline muted small">You have an open bounty wanting this card.</div>' : '';

    /* --- slim panel: no copies at all (§3.8). A listed copy is
       escrowed out of e's counts, so ghosts keep the full panel's
       skeleton instead — the slim "don't own" text would be a lie
       about a card that is merely listed. --- */
    if ((!e || !(e.n > 0)) && !insts.length && !ghosts.length) {
      var turned = !!(ctx.isTurned && ctx.isTurned(set.id, card.id));
      view.tiles = []; view.sel = null;
      view.panel.innerHTML =
        '<div class="copies-head">Your copies</div>' +
        '<p class="muted copies-none">' + (turned ?
          '✓ Turned in — permanently collected. You don\'t currently own a copy.' :
          'You don\'t own this card yet.') + '</p>' +
        '<div class="copies-actions"><button type="button" class="btn small primary" data-act="bounty">Place a bounty</button></div>' +
        bountyLine;
      return;
    }

    /* --- full panel --- */
    var tiles = buildTiles(view, e, insts, ghosts);
    view.tiles = tiles;
    var sel = null;
    if (view.selKey) {
      for (var i = 0; i < tiles.length; i++) {
        if (tiles[i].key === view.selKey && selectable(tiles[i])) { sel = tiles[i]; break; }
      }
    }
    if (!sel && !view.touched) {
      for (var j = 0; j < tiles.length; j++) {
        if (selectable(tiles[j])) { sel = tiles[j]; break; }
      }
      if (sel) view.selKey = sel.key;
    }
    view.sel = sel;

    var c = copyCounts(e, insts.length);
    var parts = [];
    if (c.plainOn > 0) parts.push(c.plainOn + ' plain');
    if (c.holoOn > 0) parts.push(c.holoOn + ' holo');
    insts.forEach(function (inst) { parts.push(variantLabel(inst.tier, inst.serial)); });
    var vaultedTotal = (e.v || 0) + insts.filter(function (x) { return x.vaulted; }).length;
    if (vaultedTotal > 0) parts.push(vaultedTotal + ' in Vault');
    if (ctx.isTurned && ctx.isTurned(set.id, card.id)) parts.push('✓ turned in');
    var head = 'Your copies' + (parts.length ?
      ' <span class="copies-counts">— ' + esc(parts.join(' · ')) + '</span>' : '');

    var grid = tiles.map(function (t, idx) {
      var cls = 'copies-tile ' + t.kind + (t.vaulted ? ' vaulted' : '') +
        (sel === t ? ' sel' : '');
      var badge = tileBadge(t);
      var inner = (t.kind === 'collapse') ?
        '<span class="copies-collapse-label">Collapse ▴</span>' :
        '<span class="copies-face">' + tileFace(view, t) + '</span>' +
        (badge ? '<span class="copies-badge">' + esc(badge) + '</span>' : '') +
        '<span class="copies-strip">' + tileStrip(view, t) + '</span>';
      if (t.kind === 'ghost') return '<div class="' + cls + '">' + inner + '</div>';
      return '<button type="button" class="' + cls + '" data-tile="' + idx + '">' + inner + '</button>';
    }).join('');

    /* --- action bar (§3.5, ONE merged bar) --- */
    var hasReal = tiles.some(function (t) { return t.kind !== 'ghost'; });
    var listable = c.plainOn + c.holoOn +
      insts.filter(function (x) { return !x.vaulted; }).length > 0;
    var bar = '';
    if (sel && !sel.vaulted) {
      bar += '<button type="button" class="btn small primary" data-act="list">List this copy</button>';
    } else if (sel && sel.vaulted && listable) {
      /* a vaulted copy can't be listed; List hides (Release is right here) */
    } else if (listable) {
      bar += '<button type="button" class="btn small primary" data-act="list">List for sale</button>';
    } else if (hasReal) {
      bar += '<button type="button" class="btn small primary" data-act="list" disabled>List for sale</button>';
    }
    if (sel) {
      var vlabel = sel.kind === 'variant' ?
        (sel.vaulted ? 'Release this numbered copy' : 'Vault this numbered copy') :
        (sel.kind === 'holo' || sel.kind === 'holoVault') ?
          (sel.vaulted ? 'Release a holo copy' : 'Vault a holo copy') :
          (sel.vaulted ? 'Release a plain copy' : 'Vault a plain copy');
      bar += '<button type="button" class="btn small" data-act="vault">' + vlabel + '</button>';
      if (!sel.vaulted && sel.kind !== 'variant') {
        bar += '<button type="button" class="btn small" data-act="gift">🎁 Gift</button>';
      }
    }
    bar += '<button type="button" class="btn small" data-act="bounty">Place a bounty</button>';

    var reason = '';
    if (hasReal && !listable) {
      reason = '<div class="copies-reason muted small">All ' + (e ? e.n : 0) +
        ' copies are in the Vault — release one to list it</div>';
    }

    view.panel.innerHTML =
      '<div class="copies-head">' + head + '</div>' +
      '<div class="copies-grid">' + grid + '</div>' +
      (sel ? '<div class="copies-acting">Acting on: <b>' + esc(actingLabel(sel)) + '</b></div>' : '') +
      '<div class="copies-actions">' + bar + '</div>' +
      reason + bountyLine;
  }

  function tileClick(view, idx) {
    var t = view.tiles[+idx];
    if (!t) return;
    if (t.kind === 'stack') { view.expanded = true; paintPanel(view); return; }
    if (t.kind === 'collapse') { view.expanded = false; paintPanel(view); return; }
    if (!selectable(t)) return;
    view.touched = true;
    if (view.sel === t) { view.selKey = null; view.sel = null; paintPanel(view); return; }
    view.selKey = t.key;
    paintPanel(view);
  }

  function listCopy(sel) {
    if (!sel) return null;
    if (sel.kind === 'variant') return { tier: sel.inst.tier, serial: sel.inst.serial };
    if (sel.kind === 'holo') return { holo: true };
    return null;
  }
  function bountyCopy(sel) {
    if (!sel) return null;
    if (sel.kind === 'variant') return { tier: sel.inst.tier, serial: null };
    if (sel.kind === 'holo' || sel.kind === 'holoVault') return { holo: true };
    return null;
  }

  function actClick(view, act, btn) {
    var ctx = CPS.appCtx, set = view.set, card = view.card, sel = view.sel;
    if (act === 'list') {
      if (CPS.trading && CPS.trading.openListing) {
        CPS.trading.openListing({ setId: set.id, cardId: card.id, copy: listCopy(sel), fromCard: view.fromCard });
      }
      return;
    }
    if (act === 'bounty') {
      if (CPS.bounties && CPS.bounties.openPost) {
        CPS.bounties.openPost({ setId: set.id, cardId: card.id, copy: bountyCopy(sel), fromCard: view.fromCard });
      }
      return;
    }
    if (act === 'gift') {
      if (sel && CPS.gift && CPS.gift.open) CPS.gift.open(set.id, card.id);
      return;
    }
    if (act === 'vault' && sel) vaultAction(view, sel, btn);
  }

  /* Same calls, toasts and re-open flow as the modal's own Vault box. */
  async function vaultAction(view, sel, btn) {
    var ctx = CPS.appCtx, set = view.set, card = view.card;
    btn.disabled = true;
    try {
      if (sel.kind === 'variant') {
        await CPS.cloud.call('vault_variant', { p_variant_id: sel.inst.id, p_on: !sel.vaulted });
        ctx.S.myVariants = null;
        await ctx.refreshCloud();
        ctx.toast(sel.vaulted ? 'Numbered copy released.' : 'Numbered copy vaulted 🔒', 'good');
      } else {
        var holo = sel.kind === 'holo' || sel.kind === 'holoVault';
        await CPS.cloud.call('vault_copy', { p_set: set.id, p_card: card.id, p_holo: holo, p_on: !sel.vaulted });
        await ctx.refreshCloud();
        ctx.toast(sel.vaulted ? 'Copy released from the Vault.' : 'Copy vaulted 🔒', 'good');
      }
      ctx.openCardModal(view.fromCard.setId, view.fromCard.cardId, view.fromCard.holo, view.fromCard.variant);
    } catch (e) { ctx.cloudError(e); btn.disabled = false; }
  }

  CPS.popfill = async function (box, set, card) {
    var S = CPS.appCtx && CPS.appCtx.S;
    if (S && S.mode === 'cloud') {
      try { renderCopies(box, set, card); } catch (e) { /* the panel is additive — never block the modal */ }
    }
    await fillPopulation(box, set, card);
  };
})();

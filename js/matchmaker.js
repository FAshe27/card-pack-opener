/* js/matchmaker.js — Wantlist + Trade Matchmaker (migrations 167+168).
   Franklin approved the spec as-is 2026-10-21; built STAGED.
   168 (Franklin, 2026-10-21, minutes after the 167 ship): "Add
   Missing" is based on TURNED-IN cards, not owned cards — completion
   means turned in only. Bulk add adds every not-yet-turned-in card;
   the modal toggle and grid star are offered for any card that isn't
   turned in (owned or not); a want clears when you turn the card in.
   Registers as CPS.matchmaker; consumes CPS.appCtx like the other
   split-out modules (market.js / giftpop.js). Loads after app.js.

   What it does:
     * Market > Matches segment (third toggle, wired in market.js):
       - "Matches for you": my wants joined to other players' true
         spares (server-side, migration 167 — last copies, vaulted
         copies and numbered copies are never spares; admins are
         invisible to non-admin callers).
       - Actions are DRAFTS ONLY: Propose Trade opens the existing
         trade builder (ctx.openTradeBuilder) with the recipient set
         and — via the small app.js hook — the matched card
         pre-picked on their side at step 2; Post Bounty opens the
         existing bounty composer (CPS.bounties.openPost) pre-filled
         with the wanted card. Nothing is sent, escrowed or reserved
         by Matchmaker itself.
       - "Your spares others want": the reverse view.
       - "Your wantlist": manager with per-want remove + bulk add
         (all not-turned-in from a set / Rare+ only, per ctx.isTurned),
         previewed with a confirm before a single add loop over
         cps_wantlist_add.
     * Want/Unwant toggle in the card modal, via the guarded app.js
       hook `if (CPS.matchmaker) CPS.matchmaker.cardHook(...)`.
     * A ☆ star on not-turned-in tiles in the collection grid (167
       showed it on on-hand-0 tiles only; 168 widens it to any tile
       whose .coll-item isn't flagged 'turned' — owned tiles included),
       injected by DOM (MutationObserver on #collGrid — the grid is
       paged in chunks, so decoration re-runs per chunk). Clicks are
       captured before the grid's own click-to-modal handler.
     * Market tab badge support: refreshes #mmBadge (distinct wanted
       cards with a match) on the bell's 60s cadence; market.js sums
       it into #marketBadge like the bounty/trade badges.

   Failure is quiet by design: logged out, offline, or migration 167
   not live yet (PGRST202) just leaves the panel/badges empty. */
(function (CPS) {
  'use strict';
  var ctx = CPS.appCtx;
  if (!ctx) return;

  var M = { wants: null, matches: [], wanted: [], badge: 0, loading: false, wantSet: {} };

  function esc(s) { return ctx.esc(s); }
  function setObj(id) { return window.CardSets && window.CardSets.get(id); }
  function cardObj(sid, cid) { var s = setObj(sid); return s && s.byId && s.byId.get(cid); }
  function $(s) { return ctx.$(s); }

  function rebuildWantSet() {
    M.wantSet = {};
    (M.wants || []).forEach(function (w) { M.wantSet[w.set_id + ':' + w.card_id] = w; });
  }
  function wantOf(sid, cid) { return M.wantSet[sid + ':' + cid] || null; }

  /* ------------------------------------------------------------ data */
  async function loadWants(silent) {
    if (!ctx.isCloud()) { M.wants = []; rebuildWantSet(); return; }
    try {
      var r = await CPS.cloud.call('wantlist_list', {});
      M.wants = r.wants || [];
    } catch (e) {
      if (!silent) ctx.cloudError(e);
      if (M.wants == null) M.wants = [];
    }
    rebuildWantSet();
    decorateGrid();
  }

  async function loadMatches() {
    if (!ctx.isCloud()) return;
    try {
      var r = await CPS.cloud.call('matchmaker_matches', {});
      M.matches = r.matches || [];
      M.badge = r.badge || 0;
    } catch (e) { M.matches = []; M.badge = 0; }
    paintBadge();
    try {
      var r2 = await CPS.cloud.call('matchmaker_wanted_mine', {});
      M.wanted = r2.wanted || [];
    } catch (e) { M.wanted = []; }
  }

  function paintBadge() {
    var b = document.getElementById('mmBadge');
    if (b) {
      b.textContent = M.badge;
      b.classList.toggle('hidden', !(M.badge > 0));
    }
    if (CPS.market && CPS.market.updateBadge) CPS.market.updateBadge();
  }

  async function refreshBadge() {
    if (!ctx.isCloud() || !CPS.cloud.hasToken()) return;
    try {
      var r = await CPS.cloud.call('matchmaker_matches', {});
      M.matches = r.matches || [];
      M.badge = r.badge || 0;
      paintBadge();
    } catch (e) { /* not live yet / offline: stay quiet */ }
  }

  /* ------------------------------------------------------- want ops */
  async function addWant(sid, cid, pref) {
    var r = await CPS.cloud.call('wantlist_add', { p_set_id: sid, p_card_id: cid, p_holo_pref: pref || 'any' });
    await loadWants(true);
    return r;
  }
  async function removeWant(sid, cid) {
    var r = await CPS.cloud.call('wantlist_remove', { p_set_id: sid, p_card_id: cid });
    await loadWants(true);
    return r;
  }

  /* ------------------------------------------------- draft actions */
  function proposeTrade(ownerId, sid, cid, holoPref, spareHolo) {
    var wantHolo = holoPref === 'holo';
    ctx.openTradeBuilder(ownerId, { setId: sid, cardId: cid, holo: wantHolo });
    if (wantHolo && !spareHolo) ctx.toast('Heads up: the holo spare may have moved — check step 2.', 'warn');
  }
  function proposeTradeToWanter(wanterId, sid, cid, cardName) {
    ctx.openTradeBuilder(wanterId);
    ctx.toast('Pick your ' + (cardName || 'spare card') + ' at step 1 — they want it!', 'good', 5000);
  }
  function postBounty(sid, cid, holoPref) {
    if (!CPS.bounties || !CPS.bounties.openPost) { ctx.toast('Bounty Board is not available right now.', 'warn'); return; }
    var prefill = { setId: sid, cardId: cid };
    if (holoPref === 'holo') prefill.copy = { holo: true };
    CPS.bounties.openPost(prefill);
  }

  /* --------------------------------------------------------- render */
  function faceHtml(sid, cid, holo) {
    var s = setObj(sid), c = cardObj(sid, cid);
    if (!s || !c) return '';
    return '<div class="trade-face mm-face" data-mm-view="' + esc(cid) + '" data-mm-set="' + esc(sid) + '" title="View card">' +
      CPS.cards.render(s, c, { holo: !!holo }) + '</div>';
  }
  function bindFaces(scope) {
    scope.querySelectorAll('[data-mm-view]').forEach(function (el) {
      el.addEventListener('click', function () {
        ctx.openCardModal(el.getAttribute('data-mm-set'), el.getAttribute('data-mm-view'));
      });
    });
  }

  function matchRow(m) {
    var spareTxt = m.spare + ' spare' + (m.spare === 1 ? '' : 's') +
      (m.spare_holo > 0 ? ' · ✦ ' + m.spare_holo + ' holo' : '');
    return '<div class="mm-row">' + faceHtml(m.set_id, m.card_id, m.spare_holo > 0) +
      '<div class="mm-row-main"><b>' + esc(m.card_name) + '</b> ' +
      '<span class="pill r-' + esc(m.rarity) + '">' + esc(m.rarity) + '</span><br>' +
      '<span class="muted small">' + esc(m.set_name) + (m.pct != null ? ' · you\'re ' + m.pct + '% there' : '') + '</span><br>' +
      '<span class="small"><b>' + esc(m.owner_name) + '</b> has ' + spareTxt +
      (m.holo_pref === 'holo' ? ' · you want ✦ holo only' : '') + '</span></div>' +
      '<div class="mm-row-actions">' +
      '<button class="btn small primary" data-mm-trade="' + esc(m.owner_id) + '" data-s="' + esc(m.set_id) + '" data-c="' + esc(m.card_id) + '" data-pref="' + esc(m.holo_pref) + '" data-sh="' + (m.spare_holo || 0) + '">Propose Trade</button>' +
      '<button class="btn small" data-mm-bounty="' + esc(m.card_id) + '" data-s="' + esc(m.set_id) + '" data-pref="' + esc(m.holo_pref) + '">Post Bounty</button>' +
      '</div></div>';
  }

  function wantedRow(w) {
    return '<div class="mm-row">' + faceHtml(w.set_id, w.card_id, w.my_spare_holo > 0) +
      '<div class="mm-row-main"><b>' + esc(w.card_name) + '</b> ' +
      '<span class="pill r-' + esc(w.rarity) + '">' + esc(w.rarity) + '</span><br>' +
      '<span class="muted small">' + esc(w.set_name) + '</span><br>' +
      '<span class="small"><b>' + esc(w.wanter_name) + '</b> wants this — you have ' +
      w.my_spare + ' spare' + (w.my_spare === 1 ? '' : 's') +
      (w.my_spare_holo > 0 ? ' (✦ ' + w.my_spare_holo + ' holo)' : '') +
      (w.holo_pref === 'holo' ? ' · they want ✦ holo only' : '') + '</span></div>' +
      '<div class="mm-row-actions">' +
      '<button class="btn small primary" data-mm-offer="' + esc(w.wanter_id) + '" data-s="' + esc(w.set_id) + '" data-c="' + esc(w.card_id) + '" data-name="' + esc(w.card_name) + '">Propose Trade</button>' +
      '</div></div>';
  }

  function wantRow(w) {
    var has = M.matches.some(function (m) { return m.set_id === w.set_id && m.card_id === w.card_id; });
    return '<div class="mm-want-row"><span><b>' + esc(w.card_name) + '</b> ' +
      '<span class="pill r-' + esc(w.rarity) + '">' + esc(w.rarity) + '</span> ' +
      '<span class="muted small">' + esc(w.set_name) + (w.holo_pref === 'holo' ? ' · ✦ holo only' : '') + '</span>' +
      (has ? ' <span class="mm-match-dot" title="A spare exists!">●</span>' : '') + '</span>' +
      '<button class="btn small" data-mm-unwant="' + esc(w.card_id) + '" data-s="' + esc(w.set_id) + '">Remove</button></div>';
  }

  async function render() {
    var host = $('#matchmakerPanel');
    if (!host) return;
    if (!ctx.isCloud()) {
      host.innerHTML = '<div class="panel"><h2>🎯 Matchmaker</h2><p class="muted">Matchmaker needs online play — log in to build a wantlist.</p></div>';
      return;
    }
    if (M.loading) return;
    M.loading = true;
    host.innerHTML = '<div class="panel"><h2>🎯 Matchmaker</h2><p class="muted small">Loading your wants and matches…</p></div>';
    try {
      if (M.wants == null) await loadWants(true);
      await loadMatches();
      if (M.wants == null) await loadWants(true);
    } finally { M.loading = false; }

    var sets = (window.CardSets ? window.CardSets.all() : [])
      .filter(function (s) { return s.id !== 'jumbled'; })
      .sort(function (a, b) { return a.name < b.name ? -1 : 1; });

    host.innerHTML =
      '<div class="panel"><h2>🎯 Matches for you</h2>' +
      '<p class="muted small">Cards on your wantlist that another player has a true spare of — ' +
      'never a last copy, never a vaulted or numbered copy. Trades and bounties start as drafts; nothing is reserved.</p>' +
      (M.matches.length
        ? '<div class="mm-list">' + M.matches.map(matchRow).join('') + '</div>'
        : '<div class="empty">No matches right now. Add wants below — matches appear the moment a spare exists.</div>') +
      '</div>' +
      '<div class="panel"><h2>🙋 Your spares others want</h2>' +
      (M.wanted.length
        ? '<div class="mm-list">' + M.wanted.map(wantedRow).join('') + '</div>'
        : '<div class="empty">Nobody wants your spares right now.</div>') +
      '</div>' +
      '<div class="panel"><h2>☆ Your wantlist <span class="muted small">(' + (M.wants ? M.wants.length : 0) + ' / 100)</span></h2>' +
      ((M.wants && M.wants.length)
        ? '<div class="mm-wants">' + M.wants.map(wantRow).join('') + '</div>'
        : '<div class="empty">Your wantlist is empty. Star any card you haven\'t turned in yet, open a card and tap ☆ Want, or bulk-add below.</div>') +
      '<div class="mm-bulk"><label>Bulk add from <select id="mmBulkSet">' +
      sets.map(function (s) { return '<option value="' + esc(s.id) + '">' + esc(s.name) + '</option>'; }).join('') +
      '</select></label> ' +
      '<button class="btn small" id="mmBulkAll">Add all missing</button> ' +
      '<button class="btn small" id="mmBulkRare">Add Rare+ missing</button> ' +
      '<button class="btn small" id="mmRefresh">↻ Refresh matches</button></div>' +
      '<p class="muted small">Bulk add is based on turned-in cards: it skips cards you\'ve already turned in (and any you already want), previews first, and stops at the 100-want cap. ' +
      'A want removes itself when you turn the card in — owning a copy no longer clears it.</p></div>';

    bindFaces(host);
    host.querySelectorAll('[data-mm-trade]').forEach(function (b) {
      b.addEventListener('click', function () {
        proposeTrade(b.getAttribute('data-mm-trade'), b.getAttribute('data-s'), b.getAttribute('data-c'),
          b.getAttribute('data-pref'), +(b.getAttribute('data-sh') || 0));
      });
    });
    host.querySelectorAll('[data-mm-bounty]').forEach(function (b) {
      b.addEventListener('click', function () { postBounty(b.getAttribute('data-s'), b.getAttribute('data-mm-bounty'), b.getAttribute('data-pref')); });
    });
    host.querySelectorAll('[data-mm-offer]').forEach(function (b) {
      b.addEventListener('click', function () {
        proposeTradeToWanter(b.getAttribute('data-mm-offer'), b.getAttribute('data-s'), b.getAttribute('data-c'), b.getAttribute('data-name'));
      });
    });
    host.querySelectorAll('[data-mm-unwant]').forEach(function (b) {
      b.addEventListener('click', async function () {
        b.disabled = true;
        try { await removeWant(b.getAttribute('data-s'), b.getAttribute('data-mm-unwant')); render(); }
        catch (e) { ctx.cloudError(e); b.disabled = false; }
      });
    });
    var rf = host.querySelector('#mmRefresh');
    if (rf) rf.addEventListener('click', function () { render(); });
    var ba = host.querySelector('#mmBulkAll');
    if (ba) ba.addEventListener('click', function () { bulkAdd(false); });
    var br = host.querySelector('#mmBulkRare');
    if (br) br.addEventListener('click', function () { bulkAdd(true); });
  }

  /* ------------------------------------------------------- bulk add */
  async function bulkAdd(rarePlus) {
    var sel = document.getElementById('mmBulkSet');
    if (!sel) return;
    var sid = sel.value;
    var set = setObj(sid);
    if (!set) return;
    if (set.stub && window.CardSets.load) { set = await window.CardSets.load(sid); if (!set) return; }
    var RARE = { rare: 1, epic: 1, legendary: 1, chase: 1 };
    /* 168: "missing" = not yet TURNED IN (the completion basis), not
       "not owned" — a card you own one copy of still wants another
       for the turn-in. ctx.isTurned mirrors cps.turn_ins. */
    var missing = set.cards.filter(function (c) {
      if (ctx.isTurned && ctx.isTurned(sid, c.id)) return false;
      if (wantOf(sid, c.id)) return false;
      if (rarePlus && !RARE[c.rarity]) return false;
      return true;
    });
    if (!missing.length) { ctx.toast('Nothing new to add from ' + set.name + ' — every card there is turned in or already wanted.', 'good'); return; }
    var room = 100 - (M.wants ? M.wants.length : 0);
    if (room <= 0) { ctx.toast('Your wantlist is full (100 max).', 'warn'); return; }
    var take = missing.slice(0, room);
    var ok = await ctx.confirmDialog('Add ' + take.length + ' wants?',
      '<p>Add ' + take.length + ' not-turned-in card' + (take.length === 1 ? '' : 's') + ' from <b>' + esc(set.name) + '</b>' +
      (rarePlus ? ' (Rare and up)' : '') + ' to your wantlist?' +
      (missing.length > take.length ? '</p><p class="muted">Only the first ' + take.length + ' fit under the 100-want cap.</p>' : '</p>'),
      'Add wants');
    if (!ok) return;
    var added = 0, skipped = 0, failed = null;
    for (var i = 0; i < take.length; i++) {
      try {
        var r = await CPS.cloud.call('wantlist_add', { p_set_id: sid, p_card_id: take[i].id, p_holo_pref: 'any' });
        if (r && r.added) added++; else skipped++;
      } catch (e) { failed = e; break; }
    }
    await loadWants(true);
    await loadMatches();
    if (failed) ctx.cloudError(failed);
    else ctx.toast('Added ' + added + ' want' + (added === 1 ? '' : 's') + (skipped ? ' (' + skipped + ' skipped)' : '') + '!', 'good');
    render();
  }

  /* -------------------------------------- pack-summary nudge (1.5) */
  /* Called from app.js finish(o) via a guarded one-liner. A pulled
     card that (a) is on someone else's wantlist and (b) is now a
     spare for me (on-hand count >= 2 after this pull — the pull
     itself may be the spare) earns ONE line in #stageSummary, which
     updateSummary() has just emptied. Never a popup, never a bell
     notification. Slips and numbered-variant pulls are skipped
     (numbered copies are never matchmaker spares). Jumbled pulls are
     skipped too: pull objects carry no home set id, and guessing one
     would risk naming the wrong wanter. */
  async function packFinish(o) {
    try {
      if (!o || !ctx.isCloud() || !CPS.cloud.hasToken()) return;
      var set = ctx.S && ctx.S.set;
      if (!set || set.id === 'jumbled') return;
      var r = await CPS.cloud.call('matchmaker_wanted_mine', {});
      M.wanted = r.wanted || [];
      var st = (ctx.ps(set) || {}).cards || {};
      var seen = {}, lines = [];
      (o.pulls || []).forEach(function (p) {
        if (!p || !p.card || p.variant) return;
        var cid = p.card.id;
        if (seen[cid]) return;
        var e = st[cid];
        var onHand = e ? Math.max(0, e.n - (e.v || 0)) : 0;
        if (onHand < 2) return;
        var w = M.wanted.filter(function (x) { return x.set_id === set.id && x.card_id === cid; })[0];
        if (!w) return;
        seen[cid] = 1;
        lines.push('<b>' + esc(w.wanter_name) + '</b> wants <b>' + esc(p.card.name) + '</b> — you have ' + onHand + '.');
      });
      if (!lines.length) return;
      if (!ctx.S.opening || ctx.S.opening !== o || !o.finished) return;
      var el = document.getElementById('stageSummary');
      if (el) el.innerHTML = '🎯 ' + lines.slice(0, 3).join(' ') + (lines.length > 3 ? ' +' + (lines.length - 3) + ' more in Market › Matches.' : '');
    } catch (e) { /* the nudge is optional garnish — never break a reveal */ }
  }

  /* ------------------------------------------------ card modal hook */
  function cardHook(box, set, card) {
    if (!ctx.isCloud() || !box || !set || !card) return;
    var info = box.querySelector('.zoom-info');
    if (!info || info.querySelector('.mm-modal')) return;
    var st = (ctx.ps(set) || {}).cards || {};
    var e = st[card.id];
    if (ctx.isTurned && ctx.isTurned(set.id, card.id)) return; // turned in: card is complete, no want (168)
    if (set.id === 'jumbled') return;
    var div = document.createElement('div');
    div.className = 'mm-modal';
    div._mmOwned = !!(e && e.n > 0);
    info.appendChild(div);
    paintModalToggle(div, set, card);
    if (M.wants == null) loadWants(true).then(function () { paintModalToggle(div, set, card); decorateGrid(); });
  }

  function paintModalToggle(div, set, card) {
    var w = wantOf(set.id, card.id);
    div.innerHTML =
      '<div class="mm-modal-row">' +
      (w
        ? '<button class="btn small mm-on" data-mm-act="remove">★ Wanted</button>'
        : '<button class="btn small" data-mm-act="add">☆ Want this card</button>') +
      (w ? '<span class="mm-seg"><button class="btn small' + (w.holo_pref === 'any' ? ' primary' : '') + '" data-mm-pref="any">Any copy</button>' +
            '<button class="btn small' + (w.holo_pref === 'holo' ? ' primary' : '') + '" data-mm-pref="holo">✦ Holo only</button></span>' : '') +
      '</div>' +
      (w ? '<div class="muted small">On your wantlist — Matchmaker checks other players\' spares for it.</div>'
         : (div._mmOwned ? '<div class="muted small">You own a copy but haven\'t turned this in yet — a want can still land the copy you\'ll turn in.</div>' : ''));
    var act = div.querySelector('[data-mm-act]');
    if (act) act.addEventListener('click', async function () {
      act.disabled = true;
      try {
        if (w) { await removeWant(set.id, card.id); ctx.toast('Removed from your wantlist.'); }
        else {
          var ar = await addWant(set.id, card.id, 'any');
          ctx.toast(ar && ar.added === false && ar.reason === 'turned_in'
            ? 'Already turned in — no want needed.' : '☆ Added to your wantlist!', 'good');
        }
        paintModalToggle(div, set, card);
        decorateGrid();
        refreshBadge();
      } catch (e) { ctx.cloudError(e); act.disabled = false; }
    });
    div.querySelectorAll('[data-mm-pref]').forEach(function (b) {
      b.addEventListener('click', async function () {
        try { await addWant(set.id, card.id, b.getAttribute('data-mm-pref')); paintModalToggle(div, set, card); }
        catch (e) { ctx.cloudError(e); }
      });
    });
  }

  /* ------------------------------------------- collection grid star */
  function decorateGrid() {
    var grid = document.getElementById('collGrid');
    if (!grid || !ctx.isCloud()) return;
    grid.querySelectorAll('.coll-card').forEach(function (wrap) {
      var cardEl = wrap.querySelector('.card');
      if (!cardEl) return;
      /* 168 basis: the star belongs on every NOT-turned-in tile,
         owned or not. cardface.collected flags turned-in cells with
         a 'turned' class on the .coll-item wrapper (and a ✓ badge);
         those are the only tiles skipped. */
      var item = wrap.parentElement;
      if (item && item.classList.contains('turned')) return;
      if (wrap.querySelector('.mm-star')) return;
      var sid = cardEl.getAttribute('data-set'), cid = cardEl.getAttribute('data-card');
      if (!sid || !cid || sid === 'jumbled') return;
      var b = document.createElement('button');
      b.className = 'mm-star';
      b.type = 'button';
      b.setAttribute('data-mm-star', cid);
      b.setAttribute('data-mm-set', sid);
      paintStar(b);
      wrap.appendChild(b);
    });
  }
  function paintStar(b) {
    var w = wantOf(b.getAttribute('data-mm-set'), b.getAttribute('data-mm-star'));
    b.textContent = w ? '★' : '☆';
    b.classList.toggle('on', !!w);
    b.title = w ? 'On your wantlist — tap to remove' : 'Add to your wantlist';
  }
  function paintAllStars() {
    document.querySelectorAll('.mm-star').forEach(paintStar);
  }

  function init() {
    // Capture-phase: a star tap must never reach the grid's own
    // click-to-open-modal handler underneath it.
    document.addEventListener('click', async function (e) {
      var b = e.target && e.target.closest ? e.target.closest('.mm-star') : null;
      if (!b) return;
      e.stopPropagation();
      e.preventDefault();
      var sid = b.getAttribute('data-mm-set'), cid = b.getAttribute('data-mm-star');
      b.disabled = true;
      try {
        if (wantOf(sid, cid)) { await removeWant(sid, cid); ctx.toast('Removed from your wantlist.'); }
        else {
          var sr = await addWant(sid, cid, 'any');
          ctx.toast(sr && sr.added === false && sr.reason === 'turned_in'
            ? 'Already turned in — no want needed.' : '☆ Added to your wantlist!', 'good');
        }
        paintAllStars();
        refreshBadge();
      } catch (err) { ctx.cloudError(err); }
      b.disabled = false;
    }, true);

    var grid = document.getElementById('collGrid');
    if (grid && window.MutationObserver) {
      new MutationObserver(function () { decorateGrid(); }).observe(grid, { childList: true });
    }
    loadWants(true);
    refreshBadge();
    setInterval(refreshBadge, 60000);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();

  CPS.matchmaker = {
    render: render, init: init, cardHook: cardHook, packFinish: packFinish,
    refreshBadge: refreshBadge, loadWants: loadWants, decorateGrid: decorateGrid
  };
})(window.CPS);

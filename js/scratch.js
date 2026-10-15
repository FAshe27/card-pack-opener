/* Scratchoffs arcade game — PUBLIC, REAL ECONOMY (graduated 2026-10-14).
   Real game tokens in, real packs out, via migration 129's RPCs
   (scratch_state / scratch_buy / scratch_claim); migration 146 removed
   the Sandbox-phase admin gate, so any signed-in player can play. The
   server decides the ticket at
   purchase time and stores it (scratching is reveal-only — a refresh
   resumes the same open ticket, never a re-roll), and pays the prize
   exactly once on claim when the ticket is fully scratched. Which spots
   have been scratched is remembered locally (per ticket) so a refresh
   mid-ticket keeps your scratch progress too.

   Prize/cost tables below are DISPLAY copies of cps.scratch_cost /
   cps.scratch_prize in supabase/migrations/129_scratchoffs.sql — the
   server is authoritative; change both together when tweaking.
   Consumes CPS.appCtx + CPS.cloud.call like js/slots.js.
   Mount: CPS.scratch.render(el) / .mount(el); teardown() clears state. */
(function (CPS) {
  'use strict';
  var ctx = CPS.appCtx;

  /* ================= CONFIG — tweak with migration 129 ================= */
  var SYMBOLS = ['common', 'uncommon', 'rare', 'epic', 'legendary', 'chase'];
  var LABEL = { common: 'Common', uncommon: 'Uncommon', rare: 'Rare',
                epic: 'Epic', legendary: 'Legendary', chase: 'Chase' };
  // Outcome odds per 1000 (display/tuning only; server rolls its own copy).
  var OUTCOME_WEIGHTS = { none: 600, common: 220, uncommon: 90, rare: 50,
                          epic: 25, legendary: 11, chase: 4 };
  var CONFIG = {
    tiers: [
      { id: 'jumbled', name: 'Jumbled Scratch', cost: 2, prizes: {
        common:    { pr: 0, pj: 1 }, uncommon: { pr: 0, pj: 2 },
        rare:      { pr: 1, pj: 2 }, epic:     { pr: 2, pj: 2 },
        legendary: { pr: 3, pj: 3 }, chase:    { pr: 5, pj: 5 } } },
      { id: 'lucky', name: 'Lucky Scratch', cost: 5, prizes: {
        common:    { pr: 1, pj: 1 }, uncommon: { pr: 2, pj: 2 },
        rare:      { pr: 4, pj: 4 }, epic:     { pr: 6, pj: 6 },
        legendary: { pr: 10, pj: 10 }, chase:  { pr: 20, pj: 20 } } },
      { id: 'chase', name: 'Chase Scratch', cost: 10, prizes: {
        common:    { pr: 2, pj: 2 }, uncommon: { pr: 4, pj: 4 },
        rare:      { pr: 8, pj: 8 }, epic:     { pr: 12, pj: 12 },
        legendary: { pr: 25, pj: 25 }, chase:  { pr: 50, pj: 25 } } }
    ]
  };
  /* ===================================================================== */

  var busy = false;
  var tokensNow = 0;
  var current = null; // { ticket_id, tier, cells, revealed:[9], settled }
  var lastSettled = null; // settled ticket snapshot: stays on screen (grid +
                          // result) until the player buys the next ticket
  var root = null;

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function q(sel) { return root ? root.querySelector(sel) : null; }
  function qa(sel) { return root ? Array.prototype.slice.call(root.querySelectorAll(sel)) : []; }
  /* Scratch progress lives client-side (revealing is cosmetic — the server
     stored the ticket at purchase), so persist it per ticket to survive a
     page refresh. Best-effort: storage may be unavailable (privacy mode). */
  function lsKey(tid) { return 'cps_scratch_revealed_' + tid; }
  function lsLoad(tid) {
    try {
      var v = JSON.parse(localStorage.getItem(lsKey(tid)) || 'null');
      return (v && v.length === 9) ? v.map(Boolean) : null;
    } catch (e) { return null; }
  }
  function lsSave() {
    if (!current) return;
    try { localStorage.setItem(lsKey(current.ticket_id), JSON.stringify(current.revealed)); } catch (e) { /* ignore */ }
  }
  function lsClear(tid) {
    try { localStorage.removeItem(lsKey(tid)); } catch (e) { /* ignore */ }
  }
  function tierById(id) {
    for (var i = 0; i < CONFIG.tiers.length; i++) if (CONFIG.tiers[i].id === id) return CONFIG.tiers[i];
    return null;
  }
  function prizeText(p) {
    var parts = [];
    if (p.pr) parts.push(p.pr + ' random pack' + (p.pr === 1 ? '' : 's'));
    if (p.pj) parts.push(p.pj + ' Jumbled Mess');
    return parts.length ? parts.join(' + ') : 'Nothing';
  }
  function expectedPacksPerTicket(tier) {
    var total = 0, k, ev = 0;
    for (k in OUTCOME_WEIGHTS) total += OUTCOME_WEIGHTS[k];
    SYMBOLS.forEach(function (s) {
      var p = tier.prizes[s];
      ev += (OUTCOME_WEIGHTS[s] / total) * (p.pr + p.pj);
    });
    return ev;
  }

  function render(el) {
    if (!el) return;
    root = el;
    current = null;
    busy = false;
    if (!ctx || !ctx.isCloud || !ctx.isCloud()) {
      el.innerHTML = '<div class="panel"><h2>🎟️ Scratchoffs</h2>' +
        '<p class="muted">Scratchoffs play for real tokens and packs — log in online to play.</p></div>';
      return;
    }
    tokensNow = (ctx.S && ctx.S.gameTokens) || 0;
    var tierCards = CONFIG.tiers.map(function (t) {
      return '<div class="panel scr-tier">' +
        '<h3>' + esc(t.name) + '</h3>' +
        '<p class="muted small">' + t.cost + ' tokens · Top prize: ' + esc(prizeText(t.prizes.chase)) + '</p>' +
        '<button class="btn primary scr-buy" data-tier="' + t.id + '" type="button">Buy ticket — ' + t.cost + ' 🪙</button>' +
      '</div>';
    }).join('');
    el.innerHTML =
      '<div class="panel scr-wrap">' +
        '<div class="scr-backrow"><button class="btn ghost" id="scrBack" type="button">← Back to Arcade</button></div>' +
        '<h2>🎟️ Scratchoffs</h2>' +
        '<p class="muted small">Buy a ticket, scratch the 9 foil spots, match 3 of a rarity to win its prize. ' +
        'The server decides the ticket when you buy it — scratching only reveals it, and an unfinished ' +
        'ticket is still here when you come back.</p>' +
        '<div class="scr-balance" id="scrBalance"></div>' +
        '<div class="scr-tiers">' + tierCards + '</div>' +
        '<div class="scr-stage" id="scrStage"></div>' +
        '<div class="scr-result" id="scrResult"><span class="muted small">Loading…</span></div>' +
      '</div>';
    qa('.scr-buy').forEach(function (b) {
      b.addEventListener('click', function () { buyTicket(b.getAttribute('data-tier')); });
    });
    var bk = q('#scrBack');
    if (bk) bk.addEventListener('click', function () {
      if (typeof CPS !== 'undefined' && CPS.app) CPS.app.showView('arcade');
    });
    updateHud();
    loadState();
  }

  async function loadState() {
    try {
      var r = await CPS.cloud.call('scratch_state', {});
      tokensNow = r.tokens_now;
      if (r.ticket) { lastSettled = null; adoptTicket(r.ticket, true); }
      else if (lastSettled) {
        current = lastSettled;
        renderStage();
        setResult(lastSettled.resultHtml);
      }
      else setResult('<span class="muted small">Pick a tier to buy a ticket.</span>');
    } catch (e) {
      try { ctx.cloudError(e); } catch (e2) { /* fall through */ }
      setResult('<span class="muted small">Could not load scratchoffs — has migration 129 been run?</span>');
    }
    updateHud();
  }

  function adoptTicket(t, resumed) {
    var tier = tierById(t.tier);
    if (!tier) return;
    var saved = lsLoad(t.ticket_id);
    current = { ticket_id: t.ticket_id, tier: tier, cells: t.cells.slice(),
                revealed: saved || t.cells.map(function () { return false; }), settled: false };
    if (resumed) setResult('<span class="muted small">You have an unfinished ' + esc(tier.name) +
      ' ticket — scratch it!</span>');
    renderStage();
    // Fully scratched before a refresh but never settled: settle now
    // (the server pays exactly once, so this is safe).
    if (current.revealed.every(function (r) { return r; })) settleIfDone();
  }

  function setResult(html) { var r = q('#scrResult'); if (r) r.innerHTML = html; }
  // Pull the account's fresh pack inventory and apply it the same way
  // cloud entry does, then re-render just the packs side — the top-bar
  // Open Packs count catches up with a claimed win immediately, with no
  // view remount (mirrors js/plinko.js).
  async function refreshPackCounts() {
    if (!ctx.S || !ctx.S.player || !ctx.S.player.sets) return;
    var st = await CPS.cloud.call('get_state', {});
    var inv = st && st.inventory;
    var sets = ctx.S.player.sets;
    if (!sets || !inv) return;
    Object.keys(sets).forEach(function (k) { if (!(k in inv)) sets[k].packs = 0; });
    Object.keys(inv).forEach(function (k) {
      if (sets[k]) sets[k].packs = inv[k];
      else sets[k] = { packs: inv[k], cards: {}, recent: [],
        stats: { opened: 0, pulled: 0, holos: 0, byRarity: {}, best: null } };
    });
    if (ctx.renderPacksSide) ctx.renderPacksSide();
    else if (CPS.packsBadge && CPS.packsBadge.update) CPS.packsBadge.update();
  }
  function syncBadges() {
    try {
      if (ctx.S) ctx.S.gameTokens = tokensNow; // freshest server value we have
      if (CPS.games && CPS.games.setTokens) CPS.games.setTokens(tokensNow);
      if (CPS.packsBadge && CPS.packsBadge.update) CPS.packsBadge.update();
    } catch (e) { /* non-fatal */ }
  }
  function updateHud() {
    var bal = q('#scrBalance');
    if (bal) bal.innerHTML = '🪙 <b>' + tokensNow + ' token' + (tokensNow === 1 ? '' : 's') + '</b>';
    qa('.scr-buy').forEach(function (b) {
      var t = tierById(b.getAttribute('data-tier'));
      b.disabled = busy || !!(current && !current.settled) || tokensNow < (t ? t.cost : 0);
    });
  }

  async function buyTicket(tierId) {
    var tier = tierById(tierId);
    if (!tier || busy || (current && !current.settled)) return;
    busy = true; updateHud();
    try {
      var r = await CPS.cloud.call('scratch_buy', { p_tier: tierId });
      tokensNow = r.tokens_now;
      lastSettled = null;
      adoptTicket(r.ticket, r.resumed);
      if (!r.resumed) setResult('<span class="muted small">' + esc(tier.name) + ' — scratch the foil spots!</span>');
      if (ctx.toast) ctx.toast(r.resumed ? 'Ticket resumed' : '🎟️ Ticket bought');
    } catch (e) {
      try { ctx.cloudError(e); } catch (e2) { /* fall through */ }
      setResult('<span class="muted small">Could not buy that ticket.</span>');
    }
    busy = false;
    syncBadges();
    updateHud();
    renderStage();
  }

  function renderStage() {
    var stage = q('#scrStage');
    if (!stage) return;
    if (!current) {
      stage.innerHTML = '<p class="muted small">No ticket yet — pick a tier above.</p>';
      return;
    }
    var cells = current.cells.map(function (sym, i) {
      var open = current.revealed[i];
      return '<button type="button" class="scr-cell' + (open ? ' scr-cell-open' : '') + '" data-cell="' + i + '"' +
        (open ? ' disabled' : '') + '>' +
        (open ? '<span class="scr-sym scr-sym-' + sym + '">' + LABEL[sym] + '</span>'
              : '<span class="scr-foil">?</span>') +
        '</button>';
    }).join('');
    stage.innerHTML =
      '<h3 class="scr-ticket-title">' + esc(current.tier.name) + '</h3>' +
      '<div class="scr-grid">' + cells + '</div>' +
      '<div class="scr-stage-btns">' +
        '<button class="btn" id="scrAll" type="button"' + (current.settled ? ' disabled' : '') + '>Scratch all</button>' +
        '<span class="muted small">' + current.revealed.filter(Boolean).length + ' / 9 scratched</span>' +
      '</div>';
    qa('.scr-cell').forEach(function (cell) {
      var idx = parseInt(cell.getAttribute('data-cell'), 10);
      cell.addEventListener('pointerdown', function () { reveal(idx); });
      cell.addEventListener('pointerenter', function (e) { if (e.buttons > 0) reveal(idx); });
      cell.addEventListener('click', function () { reveal(idx); });
    });
    var all = q('#scrAll');
    if (all) all.addEventListener('click', function () {
      current.revealed = current.revealed.map(function () { return true; });
      lsSave();
      renderStage(); settleIfDone();
    });
  }

  function reveal(i) {
    if (!current || current.settled || current.revealed[i]) return;
    current.revealed[i] = true;
    lsSave();
    renderStage();
    settleIfDone();
  }

  async function settleIfDone() {
    if (!current || current.settled || busy) return;
    if (current.revealed.some(function (r) { return !r; })) return;
    current.settled = true;
    busy = true; updateHud(); renderStage();
    try {
      var r = await CPS.cloud.call('scratch_claim', { p_ticket: current.ticket_id });
      tokensNow = r.tokens_now;
      var resultHtml;
      if (r.win) {
        resultHtml = '<span class="scr-win">MATCH 3 ' + esc(LABEL[r.outcome].toUpperCase()) +
          '! +' + esc(prizeText({ pr: r.packs_random, pj: r.packs_jumbled })) + '</span>';
        if (ctx.toast) ctx.toast('🎟️ Scratchoff win!');
      } else {
        resultHtml = '<span class="muted">No match this time — better luck on the next ticket.</span>';
      }
      setResult(resultHtml);
      lsClear(current.ticket_id);
      // Keep the finished ticket on screen — grid and result stay visible
      // until the player buys the next ticket (Franklin, 2026-10-14). The
      // snapshot also survives any later remount (e.g. leave-and-return) and any
      // leave-and-return, because loadState restores it when the server
      // has no open ticket.
      lastSettled = { ticket_id: current.ticket_id, tier: current.tier,
                      cells: current.cells.slice(), revealed: current.revealed.slice(),
                      settled: true, resultHtml: resultHtml };
      current = lastSettled;
      // Refresh the top-bar pack counts WITHOUT remounting this view: the
      // old full refreshCloud() rebuilt the panel mid-settle, so the
      // finished ticket flashed away ("Loading… / No ticket yet") before
      // the restore painted (Franklin, 2026-10-14). Targeted instead:
      // pull fresh pack inventory and re-render just the packs side, the
      // same approach Plinko uses. The finished grid + result never leave
      // the screen, and tokens already came back with the claim.
      try { await refreshPackCounts(); } catch (e) { /* non-fatal */ }
    } catch (e) {
      try { ctx.cloudError(e); } catch (e2) { /* fall through */ }
      setResult('<span class="muted small">Claim failed — reopen Scratchoffs and your ticket will resume.</span>');
      current.settled = false; // server pays once; a retry is safe
    }
    busy = false;
    syncBadges();
    updateHud();
    renderStage();
  }

  function teardown() { root = null; current = null; busy = false; }

  CPS.scratch = {
    render: render,
    mount: render,
    teardown: teardown,
    _test: { CONFIG: CONFIG, OUTCOME_WEIGHTS: OUTCOME_WEIGHTS, SYMBOLS: SYMBOLS,
             expectedPacksPerTicket: expectedPacksPerTicket,
             current: function () { return current; } }
  };
})(window.CPS = window.CPS || {});

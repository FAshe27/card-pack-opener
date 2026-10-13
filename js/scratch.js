/* Scratchoffs arcade game — SANDBOX PROTOTYPE (Franklin, 2026-10-12).
   Admin-only Sandbox 'testing' item. NO real economy: fake test-token
   balance held in this module, no server RPCs, no real packs or tokens.
   All odds and prizes are PLACEHOLDERS for Franklin to tweak.

   How a ticket works: the outcome is decided the moment the ticket is
   bought (exactly how the live, server-authoritative version will work —
   scratching is only the reveal, so a refresh can never re-roll it).
   A winning ticket hides exactly 3 matching rarity symbols among 6 filler
   symbols that never form a triple of their own; a losing ticket has no
   triple at all. Match 3 = win that symbol's prize for the ticket tier.

   Three tiers share one outcome table, so every tier returns roughly the
   same value per token (~0.38 test packs/token at placeholder numbers) —
   higher tiers just swing bigger. Mount: CPS.scratch.render(el). */
(function (CPS) {
  'use strict';

  /* ================= PLACEHOLDER CONFIG — tweak freely ================= */
  var SYMBOLS = ['common', 'uncommon', 'rare', 'epic', 'legendary', 'chase'];
  var LABEL = { common: 'Common', uncommon: 'Uncommon', rare: 'Rare',
                epic: 'Epic', legendary: 'Legendary', chase: 'Chase' };
  // Outcome roll, out of 1000: which symbol (if any) the ticket matches.
  var OUTCOME_WEIGHTS = { none: 600, common: 220, uncommon: 90, rare: 50,
                          epic: 25, legendary: 11, chase: 4 };
  var CONFIG = {
    startTokens: 100,
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

  var state = { tokens: CONFIG.startTokens, tickets: 0, spent: 0,
                wonRandom: 0, wonJumbled: 0, wins: 0 };
  var current = null; // { tier, cells: [sym x9], revealed: [bool x9], settled: bool }
  var root = null;

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function q(sel) { return root ? root.querySelector(sel) : null; }
  function qa(sel) { return root ? Array.prototype.slice.call(root.querySelectorAll(sel)) : []; }
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
  function outcomeTotal() {
    var t = 0, k; for (k in OUTCOME_WEIGHTS) t += OUTCOME_WEIGHTS[k]; return t;
  }
  function rollOutcome() {
    var roll = Math.random() * outcomeTotal(), acc = 0, k;
    var order = ['none'].concat(SYMBOLS);
    for (var i = 0; i < order.length; i++) {
      acc += OUTCOME_WEIGHTS[order[i]];
      if (roll < acc) return order[i];
    }
    return 'none';
  }

  /* Build a 9-cell ticket for a decided outcome. Invariant (unit-tested):
     winner appears exactly 3x, every other symbol at most 2x; a losing
     ticket has every symbol at most 2x. */
  function makeTicket(outcome) {
    var cells = [], counts = {}, i, s;
    SYMBOLS.forEach(function (x) { counts[x] = 0; });
    if (outcome !== 'none') {
      for (i = 0; i < 3; i++) { cells.push(outcome); counts[outcome]++; }
    }
    while (cells.length < 9) {
      // filler: never the winning symbol (already at exactly 3), and never
      // a third copy of anything else — so no accidental second triple.
      var options = SYMBOLS.filter(function (x) { return x !== outcome && counts[x] < 2; });
      s = options[(Math.random() * options.length) | 0];
      cells.push(s); counts[s]++;
    }
    // shuffle
    for (i = cells.length - 1; i > 0; i--) {
      var j = (Math.random() * (i + 1)) | 0;
      var tmp = cells[i]; cells[i] = cells[j]; cells[j] = tmp;
    }
    return cells;
  }

  function expectedPacksPerTicket(tier) {
    var total = outcomeTotal(), ev = 0;
    SYMBOLS.forEach(function (s) {
      var p = tier.prizes[s];
      ev += (OUTCOME_WEIGHTS[s] / total) * (p.pr + p.pj);
    });
    return ev;
  }

  function render(el) {
    if (!el) return;
    root = el;
    var tierCards = CONFIG.tiers.map(function (t) {
      var top = t.prizes.chase;
      return '<div class="panel scr-tier">' +
        '<h3>' + esc(t.name) + '</h3>' +
        '<p class="muted small">' + t.cost + ' test tokens · Top prize: ' + esc(prizeText(top)) + '</p>' +
        '<button class="btn primary scr-buy" data-tier="' + t.id + '" type="button">Buy ticket — ' + t.cost + ' 🪙</button>' +
      '</div>';
    }).join('');
    el.innerHTML =
      '<div class="panel scr-wrap">' +
        '<h2>🎟️ Scratchoffs <span class="scr-badge">SANDBOX TEST</span></h2>' +
        '<p class="muted small">Buy a ticket, scratch the 9 foil spots, match 3 of a rarity to win its prize. ' +
        'The ticket is decided when you buy it — scratching only reveals it. ' +
        '<b>Test tokens only — nothing here is real yet.</b></p>' +
        '<div class="scr-balance" id="scrBalance"></div>' +
        '<div class="scr-tiers">' + tierCards + '</div>' +
        '<div class="scr-stage" id="scrStage"></div>' +
        '<div class="scr-result" id="scrResult"></div>' +
        '<button class="btn" id="scrReset" type="button">Reset test balance</button>' +
        '<details class="scr-tuning"><summary>Tuning tools (placeholder odds &amp; prizes)</summary>' +
          '<div id="scrTuning"></div>' +
          '<button class="btn" id="scrSim" type="button">Simulate 1,000 tickets per tier (free)</button>' +
          '<div class="scr-sim muted small" id="scrSimOut"></div>' +
        '</details>' +
      '</div>';
    qa('.scr-buy').forEach(function (b) {
      b.addEventListener('click', function () { buyTicket(b.getAttribute('data-tier')); });
    });
    q('#scrReset').addEventListener('click', function () {
      state = { tokens: CONFIG.startTokens, tickets: 0, spent: 0, wonRandom: 0, wonJumbled: 0, wins: 0 };
      current = null;
      renderStage(); setResult('<span class="muted small">Test balance reset.</span>'); updateHud();
    });
    q('#scrSim').addEventListener('click', simulate);
    renderTuning();
    renderStage();
    updateHud();
  }

  function renderTuning() {
    var total = outcomeTotal();
    var odds = SYMBOLS.map(function (s) {
      return s + ' ' + (OUTCOME_WEIGHTS[s] / total * 100).toFixed(1) + '%';
    }).join(' · ');
    var evs = CONFIG.tiers.map(function (t) {
      var ev = expectedPacksPerTicket(t);
      return esc(t.name) + ': ' + ev.toFixed(2) + ' packs/ticket (' + (ev / t.cost).toFixed(3) + '/token)';
    }).join('<br>');
    var t2 = q('#scrTuning');
    if (t2) t2.innerHTML = '<p>Match odds (any tier): no match ' +
      (OUTCOME_WEIGHTS.none / total * 100).toFixed(1) + '% · ' + esc(odds) + '</p><p>' + evs + '</p>' +
      '<p class="muted">Slots today: ~0.23 packs per token.</p>';
  }

  function simulate() {
    var lines = CONFIG.tiers.map(function (t) {
      var wins = {}, packs = 0, i;
      SYMBOLS.forEach(function (s) { wins[s] = 0; });
      for (i = 0; i < 1000; i++) {
        var o = rollOutcome();
        if (o !== 'none') { wins[o]++; packs += t.prizes[o].pr + t.prizes[o].pj; }
      }
      var won = SYMBOLS.reduce(function (a, s) { return a + wins[s]; }, 0);
      return esc(t.name) + ': ' + won + '/1000 tickets won, ' + packs + ' packs paid (' +
        (packs / 1000).toFixed(2) + '/ticket)';
    });
    var out = q('#scrSimOut');
    if (out) out.innerHTML = lines.join('<br>');
  }

  function setResult(html) { var r = q('#scrResult'); if (r) r.innerHTML = html; }
  function updateHud() {
    var bal = q('#scrBalance');
    if (bal) bal.innerHTML = '🪙 <b>' + state.tokens + ' test tokens</b>' +
      ' &nbsp;·&nbsp; 🎁 <b>' + (state.wonRandom + state.wonJumbled) + ' test packs won</b>' +
      ' &nbsp;·&nbsp; 🎟️ ' + state.tickets + ' tickets · ' + state.wins + ' winners';
    qa('.scr-buy').forEach(function (b) {
      var t = tierById(b.getAttribute('data-tier'));
      b.disabled = !!current && !current.settled || state.tokens < (t ? t.cost : 0);
    });
  }

  function buyTicket(tierId) {
    var tier = tierById(tierId);
    if (!tier || (current && !current.settled)) return;
    if (state.tokens < tier.cost) { setResult('<span class="muted small">Not enough test tokens — reset the balance.</span>'); return; }
    state.tokens -= tier.cost; state.spent += tier.cost; state.tickets++;
    var outcome = rollOutcome();
    current = { tier: tier, outcome: outcome, cells: makeTicket(outcome),
                revealed: [false, false, false, false, false, false, false, false, false],
                settled: false };
    setResult('<span class="muted small">' + esc(tier.name) + ' — scratch the foil spots!</span>');
    renderStage();
    updateHud();
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
      renderStage(); settleIfDone();
    });
  }

  function reveal(i) {
    if (!current || current.settled || current.revealed[i]) return;
    current.revealed[i] = true;
    renderStage();
    settleIfDone();
  }

  function settleIfDone() {
    if (!current || current.settled) return;
    if (current.revealed.some(function (r) { return !r; })) { updateHud(); return; }
    current.settled = true;
    if (current.outcome !== 'none') {
      var p = current.tier.prizes[current.outcome];
      state.wonRandom += p.pr; state.wonJumbled += p.pj; state.wins++;
      setResult('<span class="scr-win">MATCH 3 ' + esc(LABEL[current.outcome].toUpperCase()) +
        '! +' + esc(prizeText(p)) + '</span>');
    } else {
      setResult('<span class="muted">No match this time — better luck on the next ticket.</span>');
    }
    renderStage();
    updateHud();
  }

  function teardown() { root = null; }

  CPS.scratch = {
    render: render,
    mount: render,
    teardown: teardown,
    _test: { CONFIG: CONFIG, OUTCOME_WEIGHTS: OUTCOME_WEIGHTS, SYMBOLS: SYMBOLS,
             state: function () { return state; }, current: function () { return current; },
             rollOutcome: rollOutcome, makeTicket: makeTicket,
             expectedPacksPerTicket: expectedPacksPerTicket }
  };
})(window.CPS = window.CPS || {});

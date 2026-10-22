/* Vault Breaker — SANDBOX PROTOTYPE, FAKE TOKENS ONLY.
   Approved spec (Franklin, 2026-10-21): 5x5 vault grid, pick 3 / 5 / 8
   hidden alarms, crack safe tiles to grow the pot, cash out whenever —
   trip an alarm and the pot is gone.

   PROTOTYPE RULES: no server, no RPCs, no real tokens or packs. The fake
   balance (starts at 100) and any active run live in localStorage only
   (key vaultbreaker_proto_v1), exactly like the Plinko/Scratchoff Sandbox
   prototypes did before they graduated. The board is dealt client-side
   here; the real build will deal it server-side (see the package README
   for the graduation notes: vault_start / vault_pick / vault_cashout).

   Registered into the Sandbox as status 'testing' — admin accounts only,
   no Arcade tile, no top-bar tab. Flip nothing here to release it: the
   real-token graduation is a separate build, on Franklin's word.

   All odds/prizes live in CONFIG at the top for tuning. */
(function (CPS) {
  'use strict';

  /* ================= CONFIG — tweak freely ================= */
  var CONFIG = {
    cost: 3,                 // fake tokens per run, all modes (Franklin, 2026-10-21: raised from 2)
    startBalance: 100,       // fake balance a fresh / reset prototype holds
    tiles: 25,               // 5x5 grid
    // tiers: cash-out prize by safe tiles cracked (highest tier reached
    // wins). tokens = fake tokens back, pr = random packs, pj = Jumbled
    // packs — all FAKE tallies in the prototype.
    modes: {
      3: { name: 'Day Job', alarms: 3, tiers: [
        { tiles: 4,  tokens: 3, pr: 0,  pj: 0  },
        { tiles: 6,  tokens: 0, pr: 0,  pj: 3  },
        { tiles: 8,  tokens: 0, pr: 3,  pj: 3  },
        { tiles: 10, tokens: 0, pr: 5,  pj: 5  },
        { tiles: 12, tokens: 0, pr: 10, pj: 10 },
        { tiles: 15, tokens: 0, pr: 20, pj: 20 },
        { tiles: 18, tokens: 0, pr: 50, pj: 25 }
      ] },
      // V2 tables (2026-10-21, Franklin: "prizes need to scale for 5 and 8
      // alarm"): the harder vaults now pay BIGGER prizes, not just the same
      // prizes sooner — optimal-stop EV ≈ 1.54x (5 alarms) the 3-alarm
      // baseline. See TABLES-V2.md in the package. (The 8-alarm table was
      // replaced by Franklin's own in V3 — see the note above it.)
      5: { name: 'Heist', alarms: 5, tiers: [
        { tiles: 3,  tokens: 3, pr: 0,   pj: 0  },
        { tiles: 5,  tokens: 0, pr: 3,   pj: 3  },
        { tiles: 7,  tokens: 0, pr: 5,   pj: 5  },
        { tiles: 9,  tokens: 0, pr: 25,  pj: 20 },
        { tiles: 11, tokens: 0, pr: 30,  pj: 20 },
        { tiles: 14, tokens: 0, pr: 40,  pj: 25 },
        { tiles: 17, tokens: 0, pr: 100, pj: 25 }
      ] },
      // V3 (2026-10-21): Franklin dictated this table himself after playing
      // V2 ("the prizes scale up a little too fast for the top tier") — the
      // Slots top prize no longer lands at 6 tiles, and the top tier IS the
      // full clear: 17 tiles pays 100 random + 100 Jumbled. Optimal stop 6,
      // EV ≈ 1.4x the 3-alarm baseline. See TABLES-V3.md in the package.
      8: { name: 'Inside Job', alarms: 8, tiers: [
        { tiles: 2,  tokens: 3, pr: 0,   pj: 0   },
        { tiles: 4,  tokens: 0, pr: 10,  pj: 5   },
        { tiles: 6,  tokens: 0, pr: 25,  pj: 25  },
        { tiles: 9,  tokens: 0, pr: 50,  pj: 25  },
        { tiles: 12, tokens: 0, pr: 75,  pj: 50  },
        { tiles: 17, tokens: 0, pr: 100, pj: 100 }
      ] }
    }
  };
  /* ===================================================================== */

  var LS_KEY = 'vaultbreaker_proto_v1';
  var MODE_KEYS = [3, 5, 8];
  // Safe-tile colour by depth when cracked — a rarity ladder: the deeper
  // you go, the hotter the gem.
  var DEPTH_CLASSES = ['vb-gem-common', 'vb-gem-uncommon', 'vb-gem-rare',
    'vb-gem-epic', 'vb-gem-legendary', 'vb-gem-chase'];
  function depthClass(depth) { // depth is 1-based count AFTER this crack
    if (depth <= 3) return DEPTH_CLASSES[0];
    if (depth <= 6) return DEPTH_CLASSES[1];
    if (depth <= 9) return DEPTH_CLASSES[2];
    if (depth <= 12) return DEPTH_CLASSES[3];
    if (depth <= 15) return DEPTH_CLASSES[4];
    return DEPTH_CLASSES[5];
  }

  /* ---------------- pure maths (also used by the tuning panel) -------- */
  function comb(n, k) {
    if (k < 0 || k > n) return 0;
    k = Math.min(k, n - k);
    var c = 1, i;
    for (i = 0; i < k; i++) c = c * (n - i) / (i + 1);
    return c;
  }
  function safeTiles(mode) { return CONFIG.tiles - CONFIG.modes[mode].alarms; }
  // Chance of cracking `depth` safe tiles in a row without an alarm:
  // C(safe, depth) / C(25, depth).
  function survival(mode, depth) {
    if (depth <= 0) return 1;
    return comb(safeTiles(mode), depth) / comb(CONFIG.tiles, depth);
  }
  function prizeFor(mode, depth) {
    var tiers = CONFIG.modes[mode].tiers, best = null, i;
    for (i = 0; i < tiers.length; i++) if (depth >= tiers[i].tiles) best = tiers[i];
    return best;
  }
  // Announcement rule (V3, 2026-10-21): the "global announcement" note is
  // for full clears and for banking the vault's OWN top (last) tier only.
  // V2 keyed it on pr >= 50, which fired on ~7% of Inside Job runs once
  // the scaled tables put 50+25 at 6 tiles — Franklin caught it in play.
  function isTopTier(mode, p) {
    var tiers = CONFIG.modes[mode].tiers;
    return !!p && p === tiers[tiers.length - 1];
  }
  function nextTier(mode, depth) {
    var tiers = CONFIG.modes[mode].tiers, i;
    for (i = 0; i < tiers.length; i++) if (depth < tiers[i].tiles) return tiers[i];
    return null;
  }
  function prizeValue(p) { // pack-equivalents for EV comparisons: a Jumbled
    // pack counts as 1/2 a random pack, and 2 tokens = 1 pack (V2, 2026-10-21)
    return p ? (p.pr + p.pj / 2 + (p.tokens || 0) / 2) : 0;
  }
  function bestStopDepth(mode) {
    var m = CONFIG.modes[mode], bestD = m.tiers[0].tiles, bestEV = -1, i, d, ev;
    var depths = m.tiers.map(function (t) { return t.tiles; });
    if (depths[depths.length - 1] < safeTiles(mode)) depths.push(safeTiles(mode));
    for (i = 0; i < depths.length; i++) {
      d = depths[i];
      ev = survival(mode, d) * prizeValue(prizeFor(mode, d));
      if (ev > bestEV) { bestEV = ev; bestD = d; }
    }
    return bestD;
  }
  function prizeText(p) {
    if (!p) return 'Nothing';
    var parts = [];
    if (p.pr) parts.push(p.pr + ' random pack' + (p.pr === 1 ? '' : 's'));
    if (p.pj) parts.push(p.pj + ' Jumbled pack' + (p.pj === 1 ? '' : 's'));
    if (p.tokens) parts.push(p.tokens + ' token' + (p.tokens === 1 ? '' : 's') + ' back');
    return parts.length ? parts.join(' + ') : 'Nothing';
  }
  function newBoard(alarms) {
    var idx = [], i;
    for (i = 0; i < CONFIG.tiles; i++) idx.push(i);
    for (i = idx.length - 1; i > 0; i--) { // Fisher–Yates
      var j = Math.floor(Math.random() * (i + 1)), t = idx[i]; idx[i] = idx[j]; idx[j] = t;
    }
    var board = [], k;
    for (k = 0; k < CONFIG.tiles; k++) board.push(false);
    for (k = 0; k < alarms; k++) board[idx[k]] = true;
    return board; // board[i] === true -> tile i hides an alarm
  }
  // Simulate `n` runs of `mode`, strategy: cash out at exactly stopDepth
  // safe tiles (or bust trying). Never touches the real (fake) balance.
  function simulate(mode, stopDepth, n) {
    var alarms = CONFIG.modes[mode].alarms, safe = safeTiles(mode);
    var totR = 0, totJ = 0, totT = 0, busts = 0, i;
    for (i = 0; i < n; i++) {
      var board = newBoard(alarms), order = [], k;
      for (k = 0; k < CONFIG.tiles; k++) order.push(k);
      for (k = order.length - 1; k > 0; k--) {
        var j = Math.floor(Math.random() * (k + 1)), t = order[k]; order[k] = order[j]; order[j] = t;
      }
      var depth = 0, busted = false;
      while (depth < stopDepth && depth < safe) {
        if (board[order[depth]]) { busted = true; break; }
        depth++;
      }
      if (busted) { busts++; continue; }
      var p = prizeFor(mode, depth);
      if (p) { totR += p.pr; totJ += p.pj; totT += p.tokens || 0; }
    }
    return { runs: n, busts: busts, avgRandom: totR / n, avgJumbled: totJ / n,
             avgTokens: totT / n, avgPacks: (totR + totJ) / n };
  }

  /* ---------------- persistent prototype state ---------------- */
  function freshStats() {
    return { runs: 0, busts: 0, cashouts: 0, best: 0, wonTokens: 0, wonRandom: 0, wonJumbled: 0 };
  }
  function freshState() {
    return { balance: CONFIG.startBalance, mode: 3, run: null, stats: freshStats() };
  }
  var memFallback = null;
  function load() {
    try {
      var raw = window.localStorage.getItem(LS_KEY);
      if (!raw) return freshState();
      var s = JSON.parse(raw);
      if (!s || typeof s.balance !== 'number' || !s.stats) return freshState();
      if (!CONFIG.modes[s.mode]) s.mode = 3;
      return s;
    } catch (e) { return memFallback || freshState(); }
  }
  function save() {
    try { window.localStorage.setItem(LS_KEY, JSON.stringify(S)); }
    catch (e) { memFallback = S; }
  }
  var S = load();

  function startRun() {
    if (S.run && !S.run.over) return;
    if (S.balance < CONFIG.cost) return;
    S.balance -= CONFIG.cost;
    S.stats.runs++;
    S.run = {
      mode: S.mode,
      board: newBoard(CONFIG.modes[S.mode].alarms),
      revealed: [],       // tile index -> depth at which it was cracked (0 = hidden)
      depth: 0, over: false, busted: false, cashed: false, full: false,
      banked: null        // prize object banked on cash-out
    };
    for (var i = 0; i < CONFIG.tiles; i++) S.run.revealed.push(0);
    save();
  }
  function pick(i) {
    var run = S.run;
    if (!run || run.over || run.revealed[i]) return;
    if (run.board[i]) {
      run.busted = true; run.over = true;
      S.stats.busts++;
      save();
      return;
    }
    run.depth++;
    run.revealed[i] = run.depth;
    if (run.depth > S.stats.best) S.stats.best = run.depth;
    if (run.depth >= safeTiles(run.mode)) { // last safe tile = full clear
      cashOut(true);
      return;
    }
    save();
  }
  function cashOut(full) {
    var run = S.run;
    if (!run || run.over) return;
    var p = prizeFor(run.mode, run.depth);
    if (!p && !full) return; // below first tier: cash-out is disabled anyway
    run.over = true; run.cashed = true; run.full = !!full;
    run.banked = p;
    if (p) {
      S.balance += p.tokens || 0;
      S.stats.wonTokens += p.tokens || 0;
      S.stats.wonRandom += p.pr;
      S.stats.wonJumbled += p.pj;
    }
    S.stats.cashouts++;
    save();
  }

  /* ---------------- rendering ---------------- */
  var root = null;
  var ui = { tuningOpen: false, payoutsOpen: false, simOut: {} }; // panel open states + per-mode sim result html (not persisted)

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function q(sel) { return root ? root.querySelector(sel) : null; }
  function qa(sel) { return root ? Array.prototype.slice.call(root.querySelectorAll(sel)) : []; }

  function modeOf() { return (S.run && !S.run.over) ? S.run.mode : S.mode; }

  function potHtml() {
    var run = S.run, mode = modeOf();
    if (!run || run.over) {
      var p0 = prizeFor(mode, 0);
      return '<div class="vb-pot muted small">Pick a vault, then start a run — ' +
        'first prize at ' + CONFIG.modes[mode].tiers[0].tiles + ' tiles: ' +
        esc(prizeText(CONFIG.modes[mode].tiers[0])) + '.</div>';
    }
    var p = prizeFor(mode, run.depth);
    var nt = nextTier(mode, run.depth);
    var html = '<div class="vb-pot">🧱 <b>' + run.depth + ' tile' + (run.depth === 1 ? '' : 's') +
      ' cracked</b> &nbsp;·&nbsp; Cash out now: <b>' + esc(p ? prizeText(p) : 'Nothing') + '</b>';
    if (nt) html += '<div class="vb-next muted small">Next tier: ' + (nt.tiles - run.depth) +
      ' more tile' + (nt.tiles - run.depth === 1 ? '' : 's') + ' → ' + esc(prizeText(nt)) + '</div>';
    else html += '<div class="vb-next muted small">Top prize banked — every extra tile is pure nerve.</div>';
    return html + '</div>';
  }

  function boardHtml() {
    var run = S.run, cells = '', i;
    for (i = 0; i < CONFIG.tiles; i++) {
      var cls = 'vb-tile', label = '🔒', dis = '';
      if (!run) {
        cls += ' vb-tile-idle'; dis = ' disabled';
      } else if (run.revealed[i]) {
        cls += ' vb-safe ' + depthClass(run.revealed[i]); label = '💎';
      } else if (run.over) {
        if (run.board[i]) { cls += run.busted ? ' vb-alarm' : ' vb-shown-alarm'; label = run.busted ? '🚨' : '🔕'; }
        else { cls += ' vb-shown-safe'; label = '💎'; }
        dis = ' disabled';
      } else {
        cls += ' vb-tile-live';
      }
      if (run && run.over) dis = ' disabled';
      cells += '<button type="button" class="' + cls + '" data-vb-tile="' + i + '"' + dis +
        ' aria-label="Vault tile ' + (i + 1) + '">' + label + '</button>';
    }
    return '<div class="vb-board" role="grid">' + cells + '</div>';
  }

  function resultHtml() {
    var run = S.run;
    if (!run || !run.over) return '<div class="vb-result"></div>';
    if (run.busted) {
      return '<div class="vb-result"><span class="vb-bust">🚨 ALARM! The vault slams shut — ' +
        'the pot is gone. ' + run.depth + ' tile' + (run.depth === 1 ? '' : 's') + ' cracked.</span></div>';
    }
    var txt = '💰 Cashed out at ' + run.depth + ' tiles — banked <b>' + esc(prizeText(run.banked)) + '</b> (fake).';
    if (run.full) txt = '🎉 <b>FULL CLEAR!</b> Every safe tile cracked — banked <b>' +
      esc(prizeText(run.banked)) + '</b> (fake).' +
      '<div class="vb-announce">📣 GLOBAL ANNOUNCEMENT (real build): a Vault Breaker full clear!</div>';
    else if (isTopTier(run.mode, run.banked)) txt +=
      '<div class="vb-announce">📣 GLOBAL ANNOUNCEMENT (real build): a top-tier Vault Breaker cash-out!</div>';
    return '<div class="vb-result"><span class="vb-win">' + txt + '</span></div>';
  }

  function tableHtml(mode) {
    var m = CONFIG.modes[mode], safe = safeTiles(mode);
    var rows = m.tiers.map(function (t) {
      var fc = t.tiles === safe; // a tier AT the full-clear depth is the
        // full-clear row itself (Inside Job V3: top tier = 17 tiles)
      return '<tr><td>' + t.tiles + ' tiles' + (fc ? ' (full clear)' : '') + '</td><td>' +
        (survival(mode, t.tiles) * 100).toFixed(fc ? 3 : 1) +
        '%</td><td>' + esc(prizeText(t)) + (fc ? ' + announcement' : '') + '</td></tr>';
    }).join('');
    if (m.tiers[m.tiers.length - 1].tiles < safe) {
      rows += '<tr><td>' + safe + ' tiles (full clear)</td><td>' +
        (survival(mode, safe) * 100).toFixed(3) + '%</td><td>' +
        esc(prizeText(m.tiers[m.tiers.length - 1])) + ' + announcement</td></tr>';
    }
    return '<table class="vb-table"><tr><th>Cash out at</th><th>Reach it</th><th>Pays</th></tr>' + rows + '</table>';
  }

  // Payouts & odds dropdown (V3, 2026-10-21, Franklin: "can we get the
  // odds/rewards table in a drop down like in other arcade games?"): all
  // three vaults stacked so they can be compared without switching modes.
  function payoutsHtml() {
    var blocks = MODE_KEYS.map(function (k) {
      var mm = CONFIG.modes[k];
      return '<div class="vb-payout-block"><h3 class="vb-pt-title">' + k + ' alarms — ' +
        esc(mm.name) + ' · pays</h3>' + tableHtml(k) + '</div>';
    }).join('');
    return '<details class="vb-payouts" id="vbPayouts"' + (ui.payoutsOpen ? ' open' : '') + '>' +
      '<summary>Payouts &amp; odds</summary>' + blocks + '</details>';
  }

  function tuningHtml() {
    var blocks = MODE_KEYS.map(function (mode) {
      var m = CONFIG.modes[mode];
      var depths = m.tiers.map(function (t) { return t.tiles; });
      if (depths[depths.length - 1] < safeTiles(mode)) depths.push(safeTiles(mode));
      var opts = depths.map(function (d) {
        return '<option value="' + d + '"' + (d === bestStopDepth(mode) ? ' selected' : '') + '>Stop at ' +
          d + ' tiles</option>';
      }).join('');
      return '<div class="vb-tune-block"><h4>' + mode + ' alarms — ' + esc(m.name) +
        ' (' + safeTiles(mode) + ' safe tiles)</h4>' + tableHtml(mode) +
        '<p class="muted small">Best modelled stop (pack-equivalents: Jumbled = ½ pack, 2 tokens = 1 pack): ' +
        '<b>' + bestStopDepth(mode) + ' tiles</b>.</p>' +
        '<div class="vb-simrow"><label class="small">Stop at <select data-vb-simstop="' + mode + '">' +
        opts + '</select></label> ' +
        '<button type="button" class="btn" data-vb-sim="' + mode + '">Simulate 1,000</button></div>' +
        '<div class="vb-simout small" id="vbSimOut' + mode + '">' + (ui.simOut[mode] || '') + '</div></div>';
    }).join('');
    return '<details class="vb-tuning" id="vbTuning"' + (ui.tuningOpen ? ' open' : '') + '>' +
      '<summary>Tuning tools (prototype)</summary>' +
      '<p class="muted small">Survival odds are exact combinatorics: C(safe, depth) / C(25, depth). ' +
      'Simulation plays the chosen stop-at strategy on fresh boards and never touches the fake balance.</p>' +
      blocks + '</details>';
  }

  function render(el) {
    if (!el) return;
    root = el;
    var mode = modeOf();
    var m = CONFIG.modes[mode];
    var runLive = !!(S.run && !S.run.over);
    var modeBtns = MODE_KEYS.map(function (k) {
      var mm = CONFIG.modes[k];
      return '<button type="button" class="btn vb-mode' + (k === mode ? ' primary' : '') +
        '" data-vb-mode="' + k + '"' + (runLive ? ' disabled' : '') + '>' +
        k + ' alarms — ' + esc(mm.name) + '</button>';
    }).join('');
    var cashBtn;
    if (runLive) {
      var p = prizeFor(mode, S.run.depth);
      cashBtn = '<button type="button" class="btn primary vb-cash" id="vbCash"' +
        (p ? '' : ' disabled') + '>Cash out — ' + esc(p ? prizeText(p) : 'nothing yet') + '</button>';
    } else {
      cashBtn = '<button type="button" class="btn primary vb-cash" id="vbStart"' +
        (S.balance < CONFIG.cost ? ' disabled' : '') + '>Start run (' + CONFIG.cost + ' tokens)</button>';
    }
    var st = S.stats;
    el.innerHTML =
      '<div class="panel vb-wrap">' +
        '<h2>🔓 Vault Breaker <span class="vb-badge">SANDBOX · FAKE TOKENS &amp; PACKS</span></h2>' +
        '<p class="muted small">Crack the vault one tile at a time. Every safe tile grows the pot — ' +
        'cash out whenever you like, but trip a hidden alarm and the pot is gone. ' +
        'Prototype: nothing here is real; the fake balance lives on this device only.</p>' +
        '<div class="vb-balance">🪙 <b>' + S.balance + ' fake tokens</b>' +
          ' &nbsp;·&nbsp; 🎁 <b>' + (st.wonRandom + st.wonJumbled) + ' fake packs won</b>' +
          (st.wonTokens ? ' &nbsp;·&nbsp; ↩️ ' + st.wonTokens + ' fake tokens won back' : '') + '</div>' +
        '<div class="vb-modes">' + modeBtns + '</div>' +
        boardHtml() +
        potHtml() +
        '<div class="vb-controls">' + cashBtn +
          '<button type="button" class="btn" id="vbReset">Reset fake balance</button></div>' +
        resultHtml() +
        payoutsHtml() +
        '<div class="vb-stats muted small">Runs: ' + st.runs + ' · Busts: ' + st.busts +
          ' · Cash-outs: ' + st.cashouts + ' · Best depth: ' + st.best + ' tiles' +
          ' · Won: ' + st.wonRandom + ' random packs, ' + st.wonJumbled + ' Jumbled packs, ' +
          st.wonTokens + ' tokens (all fake)</div>' +
        tuningHtml() +
      '</div>';

    qa('[data-vb-mode]').forEach(function (b) {
      b.addEventListener('click', function () {
        S.mode = parseInt(b.getAttribute('data-vb-mode'), 10);
        if (S.run && S.run.over) S.run = null; // picking a vault starts fresh
        save(); render(root);
      });
    });
    qa('[data-vb-tile]').forEach(function (b) {
      b.addEventListener('click', function () {
        pick(parseInt(b.getAttribute('data-vb-tile'), 10));
        render(root);
      });
    });
    var start = q('#vbStart');
    if (start) start.addEventListener('click', function () { startRun(); render(root); });
    var cash = q('#vbCash');
    if (cash) cash.addEventListener('click', function () { cashOut(false); render(root); });
    q('#vbReset').addEventListener('click', function () {
      S.balance = CONFIG.startBalance;
      S.run = null;
      save(); render(root);
    });
    var tun = q('#vbTuning');
    if (tun) tun.addEventListener('toggle', function () { ui.tuningOpen = tun.open; });
    var pay = q('#vbPayouts');
    if (pay) pay.addEventListener('toggle', function () { ui.payoutsOpen = pay.open; });
    qa('[data-vb-sim]').forEach(function (b) {
      b.addEventListener('click', function () {
        var md = parseInt(b.getAttribute('data-vb-sim'), 10);
        var sel = q('[data-vb-simstop="' + md + '"]');
        var stop = sel ? parseInt(sel.value, 10) : bestStopDepth(md);
        var r = simulate(md, stop, 1000);
        ui.simOut[md] = '1,000 runs, stop at ' + stop + ' tiles: busted ' + r.busts +
          ' · avg <b>' + r.avgPacks.toFixed(2) + ' packs</b> (' + r.avgRandom.toFixed(2) +
          ' random + ' + r.avgJumbled.toFixed(2) + ' Jumbled) + <b>' + r.avgTokens.toFixed(2) +
          ' tokens</b> back per run. Entry was ' + CONFIG.cost + ' tokens — simulation only, balance untouched.';
        var out = q('#vbSimOut' + md);
        if (out) out.innerHTML = ui.simOut[md];
      });
    });
  }

  function teardown() { root = null; }

  CPS.vaultbreaker = {
    render: render,
    teardown: teardown,
    _test: {
      CONFIG: CONFIG, comb: comb, survival: survival, prizeFor: prizeFor,
      isTopTier: isTopTier,
      nextTier: nextTier, prizeText: prizeText, newBoard: newBoard,
      simulate: simulate, bestStopDepth: bestStopDepth, prizeValue: prizeValue,
      state: function () { return S; },
      startRun: startRun, pick: pick, cashOut: function () { cashOut(false); },
      setBalance: function (n) { S.balance = n; save(); },
      setMode: function (m) { S.mode = m; save(); },
      rigBoard: function (alarmIdx) { // test-only: force the active run's alarms
        if (!S.run) return;
        S.run.board = S.run.board.map(function () { return false; });
        alarmIdx.forEach(function (i) { S.run.board[i] = true; });
        save();
      },
      resetAll: function () { S = freshState(); save(); }
    }
  };

  function register() {
    if (CPS.sandbox && CPS.sandbox.register) {
      CPS.sandbox.register({
        id: 'vaultbreaker', title: 'Vault Breaker',
        blurb: 'Crack a 5x5 vault tile by tile — cash out anytime, but 3 / 5 / 8 hidden alarms end the run. Fake tokens.',
        status: 'testing',
        render: function (el) { CPS.vaultbreaker.render(el); },
        teardown: function () { CPS.vaultbreaker.teardown(); }
      });
      return true;
    }
    return false;
  }
  if (!register() && typeof document !== 'undefined') {
    document.addEventListener('DOMContentLoaded', function () { register(); });
  }
})(window.CPS = window.CPS || {});

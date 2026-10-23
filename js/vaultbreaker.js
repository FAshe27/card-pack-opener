/* Vault Breaker — REAL ECONOMY (graduated from the Sandbox prototype
   2026-10-21; Franklin: "Move it to real tokens and remove dev info").
   Real game tokens in, real packs out, via migration 171's RPCs
   (vault_state / vault_start / vault_pick / vault_cashout). The
   server deals every board and stores it in cps.vault_runs — alarm
   positions never reach this module until a run is over, and every
   prize is paid server-side from cps.vault_prize.

   Public build (graduated 2026-10-22 on Franklin's word, mirroring
   Plinko 147): migration 174 dropped the RPCs' Phase A admin gate,
   this registration is 'public' with noTab, and the Arcade lobby
   tile points at the sbx-vaultbreaker view.

   First-tile safety (migration 175, 2026-10-23, Franklin's ask):
   the server guarantees a run's first pick is never an alarm, so
   the payouts table below uses first-tile-safe reach odds and the
   dropdown says so. This build also adds the graduated games'
   "← Back to Arcade" button (the Plinko/Roulette pattern).

   Game shape (locked through Franklin's V1–V3 playtests): 5x5 grid,
   pick a vault per run — 3 alarms "Day Job" / 5 "Heist" / 8 "Inside
   Job" — 3 tokens entry, crack safe tiles to grow the pot, cash out
   any time at the highest tier reached, an alarm ends the run, and
   cracking the last safe tile auto-banks the top tier.

   Prize tables below are a DISPLAY copy of cps.vault_prize in
   supabase/migrations/171_vault_breaker.sql — the server is
   authoritative and also hands its own table down in vault_state;
   this module renders the server's table whenever it has loaded,
   and CONFIG only covers the first paint. Change both together.
   Consumes CPS.appCtx + CPS.cloud.call like js/plinko.js. */
(function (CPS) {
  'use strict';
  var ctx = CPS.appCtx;

  /* ================= CONFIG — display copy ================= */
  var CONFIG = {
    cost: 3,                 // real tokens per run, all modes (server charges the same)
    tiles: 25,               // 5x5 grid
    // tiers: cash-out prize by safe tiles cracked (highest tier reached
    // wins). tokens = tokens back, pr = random packs, pj = Jumbled packs.
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
      5: { name: 'Heist', alarms: 5, tiers: [
        { tiles: 3,  tokens: 3, pr: 0,   pj: 0  },
        { tiles: 5,  tokens: 0, pr: 3,   pj: 3  },
        { tiles: 7,  tokens: 0, pr: 5,   pj: 5  },
        { tiles: 9,  tokens: 0, pr: 25,  pj: 20 },
        { tiles: 11, tokens: 0, pr: 30,  pj: 20 },
        { tiles: 14, tokens: 0, pr: 40,  pj: 25 },
        { tiles: 17, tokens: 0, pr: 100, pj: 25 }
      ] },
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

  /* ---------------- state (server is authoritative) ---------------- */
  function freshStats() {
    return { runs: 0, busts: 0, cashouts: 0, best: 0, wonTokens: 0, wonRandom: 0, wonJumbled: 0 };
  }
  var S = {
    loaded: false,      // true once vault_state has answered
    tokens: 0,          // mirror of the server balance
    mode: 3,            // vault picked for the next run
    run: null,          // server run payload (kept after it ends, for the reveal)
    busy: false,        // an RPC is in flight: input locks
    tables: null,       // server prize tables from vault_state, when loaded
    stats: freshStats(), // this visit only, like Plinko's session tallies
    countedRuns: {}     // run_ids already counted in stats.runs this visit
  };
  var root = null;
  var ui = { payoutsOpen: false }; // dropdown open state survives re-renders

  /* ---------------- display helpers -------------------------------- */
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function q(sel) { return root ? root.querySelector(sel) : null; }
  function qa(sel) { return root ? Array.prototype.slice.call(root.querySelectorAll(sel)) : []; }

  function tiersOf(mode) {
    if (S.tables && S.tables[String(mode)]) return S.tables[String(mode)];
    return CONFIG.modes[mode].tiers;
  }
  function safeTiles(mode) { return CONFIG.tiles - CONFIG.modes[mode].alarms; }
  function comb(n, k) {
    if (k < 0 || k > n) return 0;
    k = Math.min(k, n - k);
    var c = 1, i;
    for (i = 0; i < k; i++) c = c * (n - i) / (i + 1);
    return c;
  }
  function survival(mode, depth) { // exact odds for the payouts table
    if (depth <= 0) return 1;
    // First tile is always safe (migration 175): reaching depth d
    // means surviving the other d - 1 picks among the remaining 24
    // tiles, which hold every alarm.
    return comb(CONFIG.tiles - 1 - CONFIG.modes[mode].alarms, depth - 1) /
      comb(CONFIG.tiles - 1, depth - 1);
  }
  function prizeFor(mode, depth) {
    var tiers = tiersOf(mode), best = null, i;
    for (i = 0; i < tiers.length; i++) if (depth >= tiers[i].tiles) best = tiers[i];
    return best;
  }
  function nextTierOf(mode, depth) {
    var tiers = tiersOf(mode), i;
    for (i = 0; i < tiers.length; i++) if (depth < tiers[i].tiles) return tiers[i];
    return null;
  }
  function prizeText(p) { // spelled out in full, always
    if (!p) return 'Nothing';
    var parts = [];
    if (p.pr) parts.push(p.pr + ' random pack' + (p.pr === 1 ? '' : 's'));
    if (p.pj) parts.push(p.pj + ' Jumbled pack' + (p.pj === 1 ? '' : 's'));
    if (p.tokens) parts.push(p.tokens + ' token' + (p.tokens === 1 ? '' : 's') + ' back');
    return parts.length ? parts.join(' + ') : 'Nothing';
  }
  function audio(name, arg) {
    try { if (ctx && ctx.audio && ctx.audio[name]) ctx.audio[name](arg); } catch (e) { /* non-fatal */ }
  }

  function modeOf() {
    return (S.run && S.run.status === 'active') ? S.run.mode : S.mode;
  }
  function runLive() { return !!(S.run && S.run.status === 'active'); }

  /* ---------------- rendering -------------------------------------- */
  function potHtml() {
    var run = S.run, mode = modeOf();
    if (!runLive()) {
      var first = tiersOf(mode)[0];
      return '<div class="vb-pot muted small">Pick a vault, then start a run — ' +
        'first prize at ' + first.tiles + ' tiles: ' + esc(prizeText(first)) + '.</div>';
    }
    var nt = run.next_tier || nextTierOf(mode, run.depth);
    var html = '<div class="vb-pot">🧱 <b>' + run.depth + ' tile' + (run.depth === 1 ? '' : 's') +
      ' cracked</b> &nbsp;·&nbsp; Cash out now: <b>' + esc(run.bankable_text || prizeText(run.bankable)) + '</b>';
    if (nt) html += '<div class="vb-next muted small">Next tier: ' + (nt.tiles - run.depth) +
      ' more tile' + (nt.tiles - run.depth === 1 ? '' : 's') + ' → ' + esc(prizeText(nt)) + '</div>';
    else html += '<div class="vb-next muted small">Top prize banked — every extra tile is pure nerve.</div>';
    return html + '</div>';
  }

  function boardHtml() {
    var run = S.run, cells = '', i;
    var pickedAt = {}; // tile index -> depth at which it was cracked
    if (run) (run.picks || []).forEach(function (t, idx) { pickedAt[t] = idx + 1; });
    var alarmAt = {};
    if (run && run.status !== 'active' && run.alarms) {
      run.alarms.forEach(function (t) { alarmAt[t] = true; });
    }
    for (i = 0; i < CONFIG.tiles; i++) {
      var cls = 'vb-tile', label = '🔒', dis = '';
      if (!run) {
        cls += ' vb-tile-idle'; dis = ' disabled';
      } else if (pickedAt[i]) {
        cls += ' vb-safe ' + depthClass(pickedAt[i]); label = '💎'; dis = ' disabled';
      } else if (run.status !== 'active') {
        if (alarmAt[i]) {
          cls += run.status === 'busted' && run.lastAlarm === i ? ' vb-alarm' : ' vb-shown-alarm';
          label = run.status === 'busted' && run.lastAlarm === i ? '🚨' : '🔕';
        } else { cls += ' vb-shown-safe'; label = '💎'; }
        dis = ' disabled';
      } else if (S.busy) {
        cls += ' vb-tile-live'; dis = ' disabled';
      } else {
        cls += ' vb-tile-live';
      }
      cells += '<button type="button" class="' + cls + '" data-vb-tile="' + i + '"' + dis +
        ' aria-label="Vault tile ' + (i + 1) + '">' + label + '</button>';
    }
    return '<div class="vb-board" role="grid">' + cells + '</div>';
  }

  function resultHtml() {
    var run = S.run;
    if (!run || run.status === 'active') return '<div class="vb-result"></div>';
    if (run.status === 'busted') {
      return '<div class="vb-result"><span class="vb-bust">🚨 ALARM! The vault slams shut — ' +
        'the pot is gone. ' + run.depth + ' tile' + (run.depth === 1 ? '' : 's') + ' cracked.</span></div>';
    }
    var banked = prizeText(run.banked);
    var txt;
    if (run.full) txt = '🎉 <b>FULL CLEAR!</b> Every safe tile cracked — banked <b>' + esc(banked) + '</b>.';
    else txt = '💰 Cashed out at ' + run.depth + ' tiles — banked <b>' + esc(banked) + '</b>.';
    if (run.announced) txt += '<div class="vb-announce">📣 Announced to every player!</div>';
    return '<div class="vb-result"><span class="vb-win">' + txt + '</span></div>';
  }

  function tableHtml(mode) {
    var tiers = tiersOf(mode), safe = safeTiles(mode);
    var rows = tiers.map(function (t) {
      var fc = t.tiles === safe; // a tier AT the full-clear depth is the
        // full-clear row itself (Inside Job: top tier = 17 tiles)
      return '<tr><td>' + t.tiles + ' tiles' + (fc ? ' (full clear)' : '') + '</td><td>' +
        (survival(mode, t.tiles) * 100).toFixed(fc ? 3 : 1) +
        '%</td><td>' + esc(prizeText(t)) + (fc ? ' + announcement' : '') + '</td></tr>';
    }).join('');
    if (tiers[tiers.length - 1].tiles < safe) {
      rows += '<tr><td>' + safe + ' tiles (full clear)</td><td>' +
        (survival(mode, safe) * 100).toFixed(3) + '%</td><td>' +
        esc(prizeText(tiers[tiers.length - 1])) + ' + announcement</td></tr>';
    }
    return '<table class="vb-table"><tr><th>Cash out at</th><th>Reach it</th><th>Pays</th></tr>' + rows + '</table>';
  }

  // Payouts & odds dropdown: all three vaults stacked so they can be
  // compared without switching modes; open state survives re-renders.
  function payoutsHtml() {
    var blocks = MODE_KEYS.map(function (k) {
      return '<div class="vb-payout-block"><h3 class="vb-pt-title">' + k + ' alarms — ' +
        esc(CONFIG.modes[k].name) + ' · pays</h3>' + tableHtml(k) + '</div>';
    }).join('');
    return '<details class="vb-payouts" id="vbPayouts"' + (ui.payoutsOpen ? ' open' : '') + '>' +
      '<summary>Payouts &amp; odds</summary>' +
      '<p class="muted small">First tile is always safe.</p>' + blocks + '</details>';
  }

  function paint() {
    if (!root) return;
    var mode = modeOf();
    var live = runLive();
    var modeBtns = MODE_KEYS.map(function (k) {
      return '<button type="button" class="btn vb-mode' + (k === mode ? ' primary' : '') +
        '" data-vb-mode="' + k + '"' + (live || S.busy ? ' disabled' : '') + '>' +
        k + ' alarms — ' + esc(CONFIG.modes[k].name) + '</button>';
    }).join('');
    var bankable = live ? S.run.bankable : null;
    var hasPrize = !!(bankable && (bankable.tokens || bankable.pr || bankable.pj));
    var startBtn = '<button type="button" class="btn primary vb-cash" id="vbStart"' +
      (live || S.busy || !S.loaded || S.tokens < CONFIG.cost ? ' disabled' : '') +
      '>Start run (' + CONFIG.cost + ' tokens)</button>';
    var cashBtn = '<button type="button" class="btn primary vb-cash" id="vbCash"' +
      (live && hasPrize && !S.busy ? '' : ' disabled') +
      '>Cash out — ' + esc(live ? (S.run.bankable_text || prizeText(bankable)) : 'nothing yet') + '</button>';
    var st = S.stats;
    root.innerHTML =
      '<div class="panel vb-wrap">' +
        '<div class="vb-backrow"><button class="btn ghost" id="vbBack" type="button">← Back to Arcade</button></div>' +
        '<h2>🔓 Vault Breaker</h2>' +
        '<p class="muted small">Crack the vault one tile at a time. Every safe tile grows the pot — ' +
        'cash out whenever you like, but trip a hidden alarm and the pot is gone.</p>' +
        '<div class="vb-balance">🪙 <b>' + S.tokens + ' tokens</b>' +
          ' &nbsp;·&nbsp; 🎁 <b>' + (st.wonRandom + st.wonJumbled) + ' packs won</b>' +
          (st.wonTokens ? ' &nbsp;·&nbsp; ↩️ ' + st.wonTokens + ' tokens won back' : '') + '</div>' +
        '<div class="vb-modes">' + modeBtns + '</div>' +
        boardHtml() +
        potHtml() +
        '<div class="vb-controls">' + startBtn + cashBtn + '</div>' +
        resultHtml() +
        payoutsHtml() +
        '<div class="vb-stats muted small">Runs: ' + st.runs + ' · Busts: ' + st.busts +
          ' · Cash-outs: ' + st.cashouts + ' · Best depth: ' + st.best + ' tiles' +
          ' · Won: ' + st.wonRandom + ' random packs, ' + st.wonJumbled + ' Jumbled packs, ' +
          st.wonTokens + ' tokens</div>' +
      '</div>';

    var bk = q('#vbBack');
    if (bk) bk.addEventListener('click', function () {
      if (typeof CPS !== 'undefined' && CPS.app) CPS.app.showView('arcade');
    });
    qa('[data-vb-mode]').forEach(function (b) {
      b.addEventListener('click', function () {
        if (runLive() || S.busy) return;
        S.mode = parseInt(b.getAttribute('data-vb-mode'), 10);
        if (S.run) S.run = null; // picking a vault starts fresh
        paint();
      });
    });
    qa('[data-vb-tile]').forEach(function (b) {
      b.addEventListener('click', function () {
        pickTile(parseInt(b.getAttribute('data-vb-tile'), 10));
      });
    });
    var start = q('#vbStart');
    if (start) start.addEventListener('click', startRun);
    var cash = q('#vbCash');
    if (cash) cash.addEventListener('click', cashOut);
    var pay = q('#vbPayouts');
    if (pay) pay.addEventListener('toggle', function () { ui.payoutsOpen = pay.open; });
  }

  function render(el) {
    if (!el) return;
    root = el;
    if (!ctx || !ctx.isCloud || !ctx.isCloud()) {
      el.innerHTML = '<div class="panel"><h2>🔓 Vault Breaker</h2>' +
        '<p class="muted">Vault Breaker — log in online to play.</p></div>';
      return;
    }
    paint();
    loadState();
  }

  function teardown() { root = null; }

  /* ---------------- server sync ------------------------------------- */
  function syncBadges() {
    try {
      if (ctx.S) ctx.S.gameTokens = S.tokens; // freshest server value we have
      if (CPS.games && CPS.games.setTokens) CPS.games.setTokens(S.tokens);
      if (CPS.packsBadge && CPS.packsBadge.update) CPS.packsBadge.update();
    } catch (e) { /* non-fatal */ }
  }

  /* Pack prizes land in S.player.sets only on a full state load, so the
     packs side list would lag a Vault Breaker win until the next
     refresh — pull the inventory counts the way js/plinko.js does. */
  async function refreshPackCounts() {
    try {
      var st = await CPS.cloud.call('get_balances');
      var sets = ctx.S && ctx.S.player && ctx.S.player.sets;
      var inv = st && st.inventory;
      if (!sets || !inv) return;
      Object.keys(sets).forEach(function (k) { if (!(k in inv)) sets[k].packs = 0; });
      Object.keys(inv).forEach(function (k) {
        if (sets[k]) sets[k].packs = inv[k];
        else sets[k] = { packs: inv[k], cards: {}, recent: [],
          stats: { opened: 0, pulled: 0, holos: 0, byRarity: {}, best: null } };
      });
      if (ctx.renderPacksSide) ctx.renderPacksSide();
      else if (CPS.packsBadge && CPS.packsBadge.update) CPS.packsBadge.update();
    } catch (e) { /* non-fatal: counts catch up on the next natural load */ }
  }

  /* Count each run once per visit in the session stats, however the
     run arrives — started here, resumed by vault_start, or restored
     by vault_state after a page reload. A reload zeroes this module's
     memory, so without this a restored run that is then cashed out
     showed "Runs: 0 · Cash-outs: 1". Keyed on the payload's run_id
     (the cps.vault_runs row id, present in every run payload), so
     repeat state loads and error resyncs within one visit can never
     recount the same run, while the next run started in the visit
     counts as run 2. Adopting a run also credits its current depth
     to Best, so a restored run's depth is on the board even before
     its next pick/settle response lands. */
  function noteRun(run) {
    if (!run || run.status !== 'active' || !run.run_id) return;
    if (S.countedRuns[run.run_id]) return;
    S.countedRuns[run.run_id] = true;
    S.stats.runs++;
    if (run.depth > S.stats.best) S.stats.best = run.depth;
  }

  function applyResponse(r, grants) {
    if (!r) return;
    if (typeof r.tokens_now === 'number') S.tokens = r.tokens_now;
    if (r.run) {
      var prev = S.run;
      S.run = r.run;
      noteRun(r.run);
      if (prev && prev.status === 'active' && r.run.status !== 'active') {
        if (r.run.status === 'busted') S.stats.busts++;
        else if (r.run.status === 'cashed') settleStats(r.run);
      }
      if (r.run.depth > S.stats.best) S.stats.best = r.run.depth;
    }
    syncBadges();
    if (grants && grants.length) refreshPackCounts();
    paint();
  }
  function settleStats(run) {
    S.stats.cashouts++;
    if (run.banked) {
      S.stats.wonTokens += run.banked.tokens || 0;
      S.stats.wonRandom += run.banked.pr || 0;
      S.stats.wonJumbled += run.banked.pj || 0;
    }
  }

  async function loadState() {
    try {
      var r = await CPS.cloud.call('vault_state', {});
      S.tokens = r.tokens_now;
      if (r.tables) S.tables = r.tables;
      S.run = r.run || null;
      if (S.run) { S.mode = S.run.mode; noteRun(S.run); }
      S.loaded = true;
      syncBadges();
    } catch (e) {
      try { ctx.cloudError(e); } catch (e2) { /* fall through */ }
      S.loaded = true; // let the panel say so instead of spinning forever
      if (root) {
        var pot = q('.vb-pot');
        if (pot) pot.innerHTML = '<span class="muted small">Could not load Vault Breaker — please try again in a few minutes.</span>';
      }
    }
    paint();
  }

  async function startRun() {
    if (S.busy || runLive() || !S.loaded) return;
    if (S.tokens < CONFIG.cost) {
      try { ctx.toast('Not enough tokens — packs, quests and the Prize Wheel can earn more.', 'warn'); } catch (e) { /* non-fatal */ }
      return;
    }
    S.busy = true; paint();
    try {
      var r = await CPS.cloud.call('vault_start', { p_mode: S.mode });
      S.busy = false; // the run (fresh or resumed) is counted by noteRun in applyResponse
      applyResponse(r, null);
    } catch (e) {
      S.busy = false;
      try { ctx.cloudError(e); } catch (e2) { /* fall through */ }
      loadState(); // resync with the server (it may have started the run)
    }
  }

  async function pickTile(i) {
    if (S.busy || !runLive()) return;
    if ((S.run.picks || []).indexOf(i) !== -1) return;
    S.busy = true; paint();
    try {
      var r = await CPS.cloud.call('vault_pick', { p_tile: i });
      S.busy = false;
      if (r.run && r.run.status === 'busted') {
        r.run.lastAlarm = i; // the tile just clicked is the one that tripped
        audio('error');
      } else if (r.run && r.run.status === 'cashed') audio('reveal', 'epic');
      else audio('click');
      applyResponse(r, r.grants);
    } catch (e) {
      S.busy = false;
      try { ctx.cloudError(e); } catch (e2) { /* fall through */ }
      loadState();
    }
  }

  async function cashOut() {
    if (S.busy || !runLive()) return;
    S.busy = true; paint();
    try {
      var r = await CPS.cloud.call('vault_cashout', {});
      S.busy = false;
      audio('reveal', 'epic');
      applyResponse(r, r.grants);
    } catch (e) {
      S.busy = false;
      try { ctx.cloudError(e); } catch (e2) { /* fall through */ }
      loadState();
    }
  }

  CPS.vaultbreaker = {
    render: render,
    mount: render,
    teardown: teardown,
    _test: {
      CONFIG: CONFIG, state: function () { return S; },
      prizeText: prizeText, prizeFor: prizeFor, survival: survival,
      setTables: function (t) { S.tables = t; },
      paint: paint
    }
  };

  function register() {
    if (CPS.sandbox && CPS.sandbox.register) {
      CPS.sandbox.register({
        id: 'vaultbreaker', title: 'Vault Breaker',
        blurb: 'Crack a 5x5 vault tile by tile — cash out anytime, but 3 / 5 / 8 hidden alarms end the run. Real tokens.',
        status: 'public', noTab: true,
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

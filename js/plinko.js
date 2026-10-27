/* Plinko arcade game — PUBLIC, REAL ECONOMY (graduated 2026-10-14).
   Real game tokens in, real packs out, via migration 145's RPCs
   (plinko_state / plinko_drop); migration 147 removed the Sandbox-phase
   admin gate, so any signed-in player can play. The server rolls every
   drop path itself, stores each
   drop in cps.plinko_drops and pays at once — this module only animates
   the paths it is handed and mirrors the server's balance.

   Board maths: 8 rows of pegs, each row the chip falls left or right with
   50/50 odds, so the 9 bins land with binomial odds C(8,k)/256 — the centre
   bin is 70/256 (27.3%), the edge bins 1/256 (0.4%) each.

   Prize table below is a DISPLAY copy of cps.plinko_prize in
   supabase/migrations/145_plinko.sql — the server is authoritative;
   change both together when tweaking.
   Consumes CPS.appCtx + CPS.cloud.call like js/slots.js.
   Mount with CPS.plinko.render(el) / .mount(el); teardown() stops timers. */
(function (CPS) {
  'use strict';
  var ctx = CPS.appCtx;

  /* ================= PLACEHOLDER CONFIG — tweak freely ================= */
  var CONFIG = {
    cost: 3,               // real tokens per drop (server charges the same)
    rows: 8,                 // peg rows -> rows + 1 bins
    // One entry per bin, left to right. tokens = tokens paid back,
    // pr = random packs, pj = Jumbled Mess packs. Display copy of
    // cps.plinko_prize (migration 145) — the server pays its own table.
    bins: [
      { label: '20 random packs',                  tokens: 0, pr: 20, pj: 0 },
      { label: '3 random packs + 3 jumbled packs', tokens: 0, pr: 3,  pj: 3 },
      { label: '1 jumbled pack',                   tokens: 0, pr: 0,  pj: 1 },
      { label: '1 token',                          tokens: 1, pr: 0,  pj: 0 },
      { label: '1 random pack',                    tokens: 0, pr: 1,  pj: 0 },
      { label: '1 token',                          tokens: 1, pr: 0,  pj: 0 },
      { label: '1 jumbled pack',                   tokens: 0, pr: 0,  pj: 1 },
      { label: '3 random packs + 3 jumbled packs', tokens: 0, pr: 3,  pj: 3 },
      { label: '20 random packs',                  tokens: 0, pr: 20, pj: 0 }
    ]
  };
  /* ===================================================================== */

  /* Board geometry, in bin-width units ("u") from the board centre.
     One bin is 100/(rows+1) percent of the field width. Peg row r sits at
     pegY(r) px; the chip's final resting offset for bin k is k - rows/2 u,
     which is exactly one more half-step past the bottom peg row — so a chip
     that keeps falling the same way lands in the edge bin. */
  var U_PCT = 100 / (CONFIG.rows + 1);
  function pegOffset(r, j) { return j - r / 2; }
  function pegY(r) { return 40 + r * 26; }
  var START_Y = 10;   // drop point above the top peg
  var BIN_Y = 242;    // where the chip dives into its bin
  var rafId = null;

  var state = {
    tokens: 0,          // mirror of the server balance (authoritative there)
    loaded: false,      // true once plinko_state has answered
    drops: 0, spent: 0, // session tallies (this visit only)
    wonTokens: 0, wonRandom: 0, wonJumbled: 0,
    binCounts: CONFIG.bins.map(function () { return 0; })
  };
  var timers = [];
  var dropping = false;
  var root = null;

  function later(fn, ms) { var t = setTimeout(fn, ms); timers.push(t); return t; }
  function clearTimers() {
    timers.forEach(clearTimeout); timers = [];
    if (rafId !== null && typeof cancelAnimationFrame === 'function') cancelAnimationFrame(rafId);
    rafId = null;
  }
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function q(sel) { return root ? root.querySelector(sel) : null; }
  function qa(sel) { return root ? Array.prototype.slice.call(root.querySelectorAll(sel)) : []; }

  function binProbability(k) {
    // C(rows, k) / 2^rows
    var n = CONFIG.rows, c = 1, i;
    for (i = 0; i < k; i++) c = c * (n - i) / (i + 1);
    return c / Math.pow(2, n);
  }
  function prizeText(b) {
    var parts = [];
    if (b.pr) parts.push(b.pr + ' random pack' + (b.pr === 1 ? '' : 's'));
    if (b.pj) parts.push(b.pj + ' jumbled pack' + (b.pj === 1 ? '' : 's'));
    if (b.tokens) parts.push(b.tokens + ' token' + (b.tokens === 1 ? '' : 's'));
    return parts.length ? parts.join(' + ') : 'Nothing';
  }

  function render(el) {
    if (!el) return;
    root = el;
    clearTimers();
    dropping = false;
    if (!ctx || !ctx.isCloud || !ctx.isCloud()) {
      el.innerHTML = '<div class="panel"><h2>🪙 Plinko</h2>' +
        '<p class="muted">Plinko plays for real tokens and packs — log in online to play.</p></div>';
      return;
    }
    var binCells = CONFIG.bins.map(function (b, i) {
      var cls = i === 0 || i === CONFIG.bins.length - 1 ? ' plk-bin-edge'
        : (b.pr + b.pj > 0 ? ' plk-bin-pack' : ' plk-bin-token');
      return '<div class="plk-bin' + cls + '" data-bin="' + i + '"><span>' + esc(b.label) + '</span></div>';
    }).join('');
    // Pegs: a true Galton lattice. Row r has r+1 pegs at offsets
    // (j - r/2) bin-widths from centre, so the field widens by half a bin
    // on each side per row and the bottom row spans almost the full board
    // (offsets -3.5..+3.5), carrying the chip right out to the edge bins
    // (centres at -4..+4). Each peg is absolutely positioned in the field.
    var pegs = '', r, j;
    for (r = 0; r < CONFIG.rows; r++) {
      for (j = 0; j <= r; j++) {
        pegs += '<span class="plk-peg" data-row="' + r + '" data-j="' + j + '" style="left:' +
          (50 + pegOffset(r, j) * U_PCT) + '%;top:' + pegY(r) + 'px"></span>';
      }
    }
    el.innerHTML =
      '<div class="panel plk-wrap">' +
        '<div class="game-backrow"><button class="btn ghost" id="plkBack" type="button">← Back to Arcade</button></div>' +
        '<h2>🪙 Plinko</h2>' +
        '<p class="muted small">Drop a chip, watch it bounce. Centre bins pay tokens, ' +
        'outer bins pay packs, the very edges are the jackpot. ' +
        '<b>Real tokens &amp; packs — the server rolls every drop.</b></p>' +
        '<div class="plk-balance" id="plkBalance"></div>' +
        '<div class="plk-board" id="plkBoard">' +
          '<div class="plk-field" id="plkField">' +
            '<div class="plk-chip" id="plkChip"></div>' +
            pegs +
          '</div>' +
          '<div class="plk-bins">' + binCells + '</div>' +
        '</div>' +
        '<div class="plk-controls">' +
          '<button class="btn primary" id="plkDrop1" type="button">Drop 1 — ' + CONFIG.cost + ' 🪙</button>' +
          '<button class="btn" id="plkDrop10" type="button">Drop 10 — ' + (CONFIG.cost * 10) + ' 🪙</button>' +
          '<button class="btn" id="plkReset" type="button">Clear session stats</button>' +
        '</div>' +
        '<div class="plk-result" id="plkResult"><span class="muted small">Pick a drop to play.</span></div>' +
        '<div class="plk-stats muted small" id="plkStats"></div>' +
        '<details class="plk-tuning"><summary>Odds &amp; prizes</summary>' +
          '<div id="plkTuning"></div>' +
        '</details>' +
      '</div>';
    var bk = q('#plkBack');
    if (bk) bk.addEventListener('click', function () {
      if (typeof CPS !== 'undefined' && CPS.app) CPS.app.showView('arcade');
    });
    q('#plkDrop1').addEventListener('click', function () { playDrops(1, false); });
    q('#plkDrop10').addEventListener('click', function () { playDrops(10, true); });
    q('#plkReset').addEventListener('click', function () {
      var keep = state.tokens, wasLoaded = state.loaded;
      state = { tokens: keep, loaded: wasLoaded, drops: 0, spent: 0, wonTokens: 0,
        wonRandom: 0, wonJumbled: 0, binCounts: CONFIG.bins.map(function () { return 0; }) };
      setResult('<span class="muted small">Session stats cleared.</span>');
      updateHud();
    });
    renderTuning();
    updateHud();
    loadState();
  }

  async function loadState() {
    try {
      var r = await CPS.cloud.call('plinko_state', {});
      state.tokens = r.tokens;
      state.loaded = true;
    } catch (e) {
      try { ctx.cloudError(e); } catch (e2) { /* fall through */ }
      setResult('<span class="muted small">Could not load Plinko — has migration 145 been run?</span>');
    }
    updateHud();
  }

  function syncBadges() {
    try {
      if (ctx.S) ctx.S.gameTokens = state.tokens; // freshest server value we have
      if (CPS.games && CPS.games.setTokens) CPS.games.setTokens(state.tokens);
      if (CPS.packsBadge && CPS.packsBadge.update) CPS.packsBadge.update();
    } catch (e) { /* non-fatal */ }
  }

  /* Pack prizes land in S.player.sets only on a full state load, so the
     top-bar Open Packs badge (and the packs side list) lagged behind a
     Plinko win until the next refresh (Franklin, 2026-10-14). Pull just
     the inventory counts from get_balances, apply them the way the app's
     own loader does, and repaint the packs side — no view remount, so
     the result line and session stats stay put. */
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

  function renderTuning() {
    var rows = CONFIG.bins.map(function (b, i) {
      return '<tr><td>Bin ' + (i + 1) + '</td><td>' + (binProbability(i) * 100).toFixed(2) + '%</td>' +
        '<td>' + esc(b.label) + '</td></tr>';
    }).join('');
    var t = q('#plkTuning');
    if (t) t.innerHTML = '<table class="plk-table"><tr><th>Bin</th><th>Odds</th><th>Pays</th></tr>' + rows + '</table>';
  }

  function setResult(html) { var r = q('#plkResult'); if (r) r.innerHTML = html; }
  function updateHud() {
    var bal = q('#plkBalance');
    if (bal) bal.innerHTML = '🪙 <b>' + state.tokens + ' token' + (state.tokens === 1 ? '' : 's') + '</b>' +
      ' &nbsp;·&nbsp; 🎁 <b>' + (state.wonRandom + state.wonJumbled) + ' packs won</b>' +
      (state.wonTokens ? ' &nbsp;·&nbsp; ↩️ ' + state.wonTokens + ' tokens won back' : '');
    var st = q('#plkStats');
    if (st) st.textContent = state.drops
      ? 'Drops: ' + state.drops + ' · Spent: ' + state.spent + ' tokens · Bins hit (L→R): ' + state.binCounts.join(' · ')
      : '';
    var d1 = q('#plkDrop1'), d10 = q('#plkDrop10');
    if (d1) d1.disabled = dropping || !state.loaded || state.tokens < CONFIG.cost;
    if (d10) d10.disabled = dropping || !state.loaded || state.tokens < CONFIG.cost * 10;
  }

  async function playDrops(n, fast) {
    if (dropping || !root || !state.loaded) return;
    var cost = CONFIG.cost * n;
    if (state.tokens < cost) { setResult('<span class="muted small">Not enough tokens — packs, quests and the Prize Wheel can earn more.</span>'); return; }
    dropping = true;
    updateHud();
    var r;
    try {
      r = await CPS.cloud.call('plinko_drop', { p_drops: n });
    } catch (e) {
      try { ctx.cloudError(e); } catch (e2) { /* fall through */ }
      setResult('<span class="muted small">That drop did not go through — no tokens were charged.</span>');
      dropping = false;
      loadState(); // resync the balance mirror with the server
      return;
    }
    // The server has charged and paid already; mirror the cost locally,
    // animate its paths, and let the per-drop settles add winnings back
    // before the authoritative tokens_now lands at the end.
    state.tokens -= cost; state.spent += cost;
    updateHud();
    var results = r.results || [], done = 0, wins = [];
    (function next() {
      if (done >= results.length) {
        dropping = false;
        state.tokens = r.tokens_now;
        syncBadges();
        var batchPacks = 0;
        results.forEach(function (res) { batchPacks += (res.pr || 0) + (res.pj || 0); });
        if (batchPacks > 0) refreshPackCounts();
        if (wins.length) {
          setResult('<span class="plk-win">' + esc(wins[wins.length - 1]) + '</span>' +
            (n > 1 ? '<div class="muted small">' + n + ' drops done.</div>' : ''));
        } else if (n > 1) setResult('<span class="muted small">' + n + ' drops done — no pack bins hit.</span>');
        updateHud();
        return;
      }
      var res = results[done];
      var path = { steps: res.steps, bin: res.bin };
      var prize = { tokens: res.tokens, pr: res.pr, pj: res.pj };
      dropOnce(fast, path, prize, function (b, binIdx) {
        done++;
        if (b.pr + b.pj > 0) wins.push('Bin ' + (binIdx + 1) + ' — ' + prizeText(b) + '!');
        next();
      });
    })();
  }

  function placeChip(chip, offsetU, yPx) {
    chip.style.left = (50 + offsetU * U_PCT) + '%';
    chip.style.top = yPx + 'px';
  }
  function flashPeg(r, offsetU) {
    var j = Math.round(offsetU + r / 2);
    var peg = q('.plk-peg[data-row="' + r + '"][data-j="' + j + '"]');
    if (!peg) return;
    peg.classList.add('plk-peg-hit');
    later(function () { peg.classList.remove('plk-peg-hit'); }, 180);
  }

  /* One hop of the bounce: animate the chip from point A to point B along a
     shallow arc (it rises a few px mid-hop, like it has just caromed off a
     peg), easing out of the bounce and into the landing. Entry/final hops
     pass arc=0 and fall straight with gravity easing instead. */
  function hop(chip, from, to, ms, arc, done) {
    var t0 = null;
    function frame(ts) {
      if (!root || !document.body.contains(chip)) { done(); return; }
      if (t0 === null) t0 = ts;
      var t = Math.min(1, (ts - t0) / ms);
      var x = from.x + (to.x - from.x) * t;
      var y = from.y + (to.y - from.y) * t - Math.sin(Math.PI * t) * arc;
      if (!arc) y = from.y + (to.y - from.y) * t * t; // entry/final: accelerating fall
      placeChip(chip, x, y);
      if (t < 1) { rafId = requestAnimationFrame(frame); }
      else { rafId = null; done(); }
    }
    rafId = requestAnimationFrame(frame);
  }

  /* Animate the chip through the pre-decided path, bouncing peg to peg,
     then settle the prize. Points: drop point -> top peg -> each next peg
     row (one path step per hop) -> a final dive into the bin. */
  function dropOnce(fast, path, prize, done) {
    var chip = q('#plkChip');
    if (!chip || !root) { settle(path, prize, done); return; }
    qa('.plk-bin').forEach(function (b) { b.classList.remove('plk-bin-hit'); });
    var hopMs = fast ? 50 : 185;
    // offsets[r] = chip offset (in u) when it sits on peg row r
    var offsets = [0], i;
    for (i = 0; i < CONFIG.rows - 1; i++) offsets.push(offsets[i] + path.steps[i] * 0.5);
    var binOffsetU = offsets[CONFIG.rows - 1] + path.steps[CONFIG.rows - 1] * 0.5;
    chip.style.display = 'block';
    placeChip(chip, 0, START_Y);
    hop(chip, { x: 0, y: START_Y }, { x: 0, y: pegY(0) }, fast ? 40 : 130, 0, function () {
      flashPeg(0, 0);
      var r = 0;
      (function nextPeg() {
        if (r >= CONFIG.rows - 1) {
          hop(chip, { x: offsets[CONFIG.rows - 1], y: pegY(CONFIG.rows - 1) },
              { x: binOffsetU, y: BIN_Y }, fast ? 40 : 160, 0, function () {
            var binEl = q('.plk-bin[data-bin="' + path.bin + '"]');
            if (binEl) binEl.classList.add('plk-bin-hit');
            chip.style.display = 'none';
            settle(path, prize, done);
          });
          return;
        }
        var from = { x: offsets[r], y: pegY(r) };
        var to = { x: offsets[r + 1], y: pegY(r + 1) };
        r++;
        hop(chip, from, to, hopMs, 10, function () {
          flashPeg(r, offsets[r]);
          nextPeg();
        });
      })();
    });
  }

  function settle(path, prize, done) {
    var b = { tokens: prize.tokens, pr: prize.pr, pj: prize.pj };
    state.drops++;
    state.binCounts[path.bin]++;
    state.tokens += b.tokens;
    state.wonTokens += b.tokens;
    state.wonRandom += b.pr;
    state.wonJumbled += b.pj;
    if (b.pr + b.pj === 0 && b.tokens > 0) {
      setResult('<span class="muted">Bin ' + (path.bin + 1) + ' — back ' + prizeText(b) + '.</span>');
    } else if (b.pr + b.pj === 0) {
      setResult('<span class="muted">Bin ' + (path.bin + 1) + ' — nothing this time.</span>');
    }
    updateHud();
    if (done) done(b, path.bin);
  }

  function teardown() {
    clearTimers();
    dropping = false;
    root = null;
  }

  CPS.plinko = {
    render: render,
    mount: render,
    teardown: teardown,
    _test: { CONFIG: CONFIG, state: function () { return state; },
             binProbability: binProbability,
             pegOffset: pegOffset, pegY: pegY, U_PCT: U_PCT, prizeText: prizeText }
  };
})(window.CPS = window.CPS || {});

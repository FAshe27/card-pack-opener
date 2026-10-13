/* Plinko arcade game — SANDBOX PROTOTYPE (Franklin, 2026-10-12).
   Admin-only Sandbox 'testing' item. NO real economy: it runs on a fake
   test-token balance held in this module, never touches CPS.appCtx state,
   server RPCs, packs, or tokens. Prizes below are PLACEHOLDERS — Franklin
   will tweak rewards/odds before this graduates out of the Sandbox.

   Board maths: 8 rows of pegs, each row the chip falls left or right with
   50/50 odds, so the 9 bins land with binomial odds C(8,k)/256 — the centre
   bin is 70/256 (27.3%), the edge bins 1/256 (0.4%) each. The drop path is
   decided up front and the animation just follows it (same shape the live
   version will use, with the server deciding the path instead).

   Mount with CPS.plinko.render(el) / .mount(el); teardown() stops timers. */
(function (CPS) {
  'use strict';

  /* ================= PLACEHOLDER CONFIG — tweak freely ================= */
  var CONFIG = {
    cost: 2,               // test tokens per drop
    startTokens: 100,      // fake sandbox balance
    rows: 8,               // peg rows -> rows + 1 bins
    // One entry per bin, left to right. tokens = test tokens paid back,
    // pr = random packs, pj = Jumbled Mess packs (all tallied, not real).
    bins: [
      { label: '20 packs',        tokens: 0, pr: 20, pj: 0 },
      { label: '2 + 2 Jumbled',   tokens: 0, pr: 2,  pj: 2 },
      { label: '1 Jumbled',       tokens: 0, pr: 0,  pj: 1 },
      { label: '3 tokens',        tokens: 3, pr: 0,  pj: 0 },
      { label: '1 token',         tokens: 1, pr: 0,  pj: 0 },
      { label: '3 tokens',        tokens: 3, pr: 0,  pj: 0 },
      { label: '1 Jumbled',       tokens: 0, pr: 0,  pj: 1 },
      { label: '2 + 2 Jumbled',   tokens: 0, pr: 2,  pj: 2 },
      { label: '20 packs',        tokens: 0, pr: 20, pj: 0 }
    ]
  };
  /* ===================================================================== */

  var state = {
    tokens: CONFIG.startTokens,
    drops: 0, spent: 0,
    wonTokens: 0, wonRandom: 0, wonJumbled: 0,
    binCounts: CONFIG.bins.map(function () { return 0; })
  };
  var timers = [];
  var dropping = false;
  var root = null;

  function later(fn, ms) { var t = setTimeout(fn, ms); timers.push(t); return t; }
  function clearTimers() { timers.forEach(clearTimeout); timers = []; }
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function q(sel) { return root ? root.querySelector(sel) : null; }
  function qa(sel) { return root ? Array.prototype.slice.call(root.querySelectorAll(sel)) : []; }

  // One drop's path: rows x (-1 left / +1 right). bin = number of rights.
  function decidePath() {
    var steps = [], rights = 0, i;
    for (i = 0; i < CONFIG.rows; i++) {
      var r = Math.random() < 0.5 ? -1 : 1;
      steps.push(r);
      if (r > 0) rights++;
    }
    return { steps: steps, bin: rights };
  }
  function binProbability(k) {
    // C(rows, k) / 2^rows
    var n = CONFIG.rows, c = 1, i;
    for (i = 0; i < k; i++) c = c * (n - i) / (i + 1);
    return c / Math.pow(2, n);
  }
  function expectedValue() {
    var packs = 0, tokens = 0, i, p, b;
    for (i = 0; i < CONFIG.bins.length; i++) {
      p = binProbability(i); b = CONFIG.bins[i];
      packs += p * (b.pr + b.pj); tokens += p * b.tokens;
    }
    return { packs: packs, tokens: tokens };
  }

  function prizeText(b) {
    var parts = [];
    if (b.pr) parts.push(b.pr + ' random pack' + (b.pr === 1 ? '' : 's'));
    if (b.pj) parts.push(b.pj + ' Jumbled Mess');
    if (b.tokens) parts.push(b.tokens + ' token' + (b.tokens === 1 ? '' : 's'));
    return parts.length ? parts.join(' + ') : 'Nothing';
  }

  function render(el) {
    if (!el) return;
    root = el;
    clearTimers();
    dropping = false;
    var binCells = CONFIG.bins.map(function (b, i) {
      var cls = i === 0 || i === CONFIG.bins.length - 1 ? ' plk-bin-edge'
        : (b.pr + b.pj > 0 ? ' plk-bin-pack' : ' plk-bin-token');
      return '<div class="plk-bin' + cls + '" data-bin="' + i + '"><span>' + esc(b.label) + '</span></div>';
    }).join('');
    // Pegs: rows of dots, offset alternating — purely decorative.
    var pegRows = '', r, c;
    for (r = 0; r < CONFIG.rows; r++) {
      var dots = '';
      for (c = 0; c <= r + 1; c++) dots += '<span class="plk-peg"></span>';
      pegRows += '<div class="plk-pegrow' + (r % 2 ? ' plk-pegrow-off' : '') + '">' + dots + '</div>';
    }
    el.innerHTML =
      '<div class="panel plk-wrap">' +
        '<h2>🪙 Plinko <span class="plk-badge">SANDBOX TEST</span></h2>' +
        '<p class="muted small">Drop a chip, watch it bounce. Centre bins pay tokens, ' +
        'outer bins pay packs, the very edges are the jackpot. ' +
        '<b>Test tokens only — nothing here is real yet.</b></p>' +
        '<div class="plk-balance" id="plkBalance"></div>' +
        '<div class="plk-board" id="plkBoard">' +
          '<div class="plk-chip" id="plkChip"></div>' +
          pegRows +
          '<div class="plk-bins">' + binCells + '</div>' +
        '</div>' +
        '<div class="plk-controls">' +
          '<button class="btn primary" id="plkDrop1" type="button">Drop 1 — ' + CONFIG.cost + ' 🪙</button>' +
          '<button class="btn" id="plkDrop10" type="button">Drop 10 — ' + (CONFIG.cost * 10) + ' 🪙</button>' +
          '<button class="btn" id="plkReset" type="button">Reset test balance</button>' +
        '</div>' +
        '<div class="plk-result" id="plkResult"><span class="muted small">Pick a drop to play.</span></div>' +
        '<div class="plk-stats muted small" id="plkStats"></div>' +
        '<details class="plk-tuning"><summary>Tuning tools (placeholder odds &amp; prizes)</summary>' +
          '<div id="plkTuning"></div>' +
          '<button class="btn" id="plkSim" type="button">Simulate 1,000 drops (free, no prizes)</button>' +
          '<div class="plk-sim muted small" id="plkSimOut"></div>' +
        '</details>' +
      '</div>';
    q('#plkDrop1').addEventListener('click', function () { playDrops(1, false); });
    q('#plkDrop10').addEventListener('click', function () { playDrops(10, true); });
    q('#plkReset').addEventListener('click', function () {
      state = { tokens: CONFIG.startTokens, drops: 0, spent: 0, wonTokens: 0,
        wonRandom: 0, wonJumbled: 0, binCounts: CONFIG.bins.map(function () { return 0; }) };
      setResult('<span class="muted small">Test balance reset.</span>');
      updateHud();
    });
    q('#plkSim').addEventListener('click', simulate);
    renderTuning();
    updateHud();
  }

  function renderTuning() {
    var ev = expectedValue();
    var rows = CONFIG.bins.map(function (b, i) {
      return '<tr><td>Bin ' + (i + 1) + '</td><td>' + (binProbability(i) * 100).toFixed(2) + '%</td>' +
        '<td>' + esc(b.label) + '</td></tr>';
    }).join('');
    var t = q('#plkTuning');
    if (t) t.innerHTML = '<table class="plk-table"><tr><th>Bin</th><th>Odds</th><th>Pays</th></tr>' + rows + '</table>' +
      '<p>Modelled return per drop: <b>' + ev.packs.toFixed(3) + ' packs</b> + <b>' +
      ev.tokens.toFixed(3) + ' tokens</b> back, for a ' + CONFIG.cost + '-token drop. ' +
      '(Slots today: ~0.46 packs per 2-token spin.)</p>';
  }

  function simulate() {
    var counts = CONFIG.bins.map(function () { return 0; });
    var packs = 0, tokens = 0, i, d;
    for (i = 0; i < 1000; i++) {
      d = decidePath();
      counts[d.bin]++;
      packs += CONFIG.bins[d.bin].pr + CONFIG.bins[d.bin].pj;
      tokens += CONFIG.bins[d.bin].tokens;
    }
    var out = q('#plkSimOut');
    if (out) out.innerHTML = 'Simulated 1,000 drops: bins hit (L→R) ' + counts.join(' · ') +
      ' — paid ' + packs + ' packs + ' + tokens + ' tokens total (' +
      (packs / 1000).toFixed(3) + ' packs and ' + (tokens / 1000).toFixed(2) + ' tokens per drop).';
  }

  function setResult(html) { var r = q('#plkResult'); if (r) r.innerHTML = html; }
  function updateHud() {
    var bal = q('#plkBalance');
    if (bal) bal.innerHTML = '🪙 <b>' + state.tokens + ' test tokens</b>' +
      ' &nbsp;·&nbsp; 🎁 <b>' + (state.wonRandom + state.wonJumbled) + ' test packs won</b>' +
      (state.wonTokens ? ' &nbsp;·&nbsp; ↩️ ' + state.wonTokens + ' tokens won back' : '');
    var st = q('#plkStats');
    if (st) st.textContent = state.drops
      ? 'Drops: ' + state.drops + ' · Spent: ' + state.spent + ' tokens · Bins hit (L→R): ' + state.binCounts.join(' · ')
      : '';
    var d1 = q('#plkDrop1'), d10 = q('#plkDrop10');
    if (d1) d1.disabled = dropping || state.tokens < CONFIG.cost;
    if (d10) d10.disabled = dropping || state.tokens < CONFIG.cost * 10;
  }

  function playDrops(n, fast) {
    if (dropping || !root) return;
    var cost = CONFIG.cost * n;
    if (state.tokens < cost) { setResult('<span class="muted small">Not enough test tokens — reset the balance.</span>'); return; }
    dropping = true;
    state.tokens -= cost; state.spent += cost;
    updateHud();
    var done = 0, wins = [];
    (function next() {
      if (done >= n) {
        dropping = false;
        if (wins.length) {
          setResult('<span class="plk-win">' + esc(wins[wins.length - 1]) + '</span>' +
            (n > 1 ? '<div class="muted small">' + n + ' drops done.</div>' : ''));
        } else if (n > 1) setResult('<span class="muted small">' + n + ' drops done — no pack bins hit.</span>');
        updateHud();
        return;
      }
      dropOnce(fast, function (b, binIdx) {
        done++;
        if (b.pr + b.pj > 0) wins.push('Bin ' + (binIdx + 1) + ' — ' + prizeText(b) + '!');
        next();
      });
    })();
  }

  /* Animate the chip through the pre-decided path, then settle the prize. */
  function dropOnce(fast, done) {
    var path = decidePath();
    var chip = q('#plkChip');
    var board = q('#plkBoard');
    if (!chip || !board) { settle(path, done); return; }
    qa('.plk-bin').forEach(function (b) { b.classList.remove('plk-bin-hit'); });
    // Position model: board width maps x in [0, bins-1]; chip starts centred
    // at x = rows/2 and moves +-0.5 per row.
    var bw = board.clientWidth || 520;
    var slot = bw / CONFIG.bins.length;
    var x = CONFIG.rows / 2;
    var stepMs = fast ? 35 : 110;
    chip.style.display = 'block';
    chip.style.transition = 'none';
    chip.style.left = (x * slot + slot / 2 - 11) + 'px';
    chip.style.top = '2px';
    var i = 0;
    (function step() {
      if (!root || !document.body.contains(chip)) { settle(path, done); return; }
      if (i >= path.steps.length) {
        var binEl = q('.plk-bin[data-bin="' + path.bin + '"]');
        if (binEl) binEl.classList.add('plk-bin-hit');
        later(function () { chip.style.display = 'none'; settle(path, done); }, fast ? 60 : 220);
        return;
      }
      x += path.steps[i] * 0.5;
      i++;
      chip.style.transition = 'left ' + stepMs + 'ms ease-in, top ' + stepMs + 'ms ease-in';
      chip.style.left = (x * slot + slot / 2 - 11) + 'px';
      chip.style.top = (2 + i * 26) + 'px';
      later(step, stepMs);
    })();
  }

  function settle(path, done) {
    var b = CONFIG.bins[path.bin];
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
    _test: { CONFIG: CONFIG, state: function () { return state; }, decidePath: decidePath,
             binProbability: binProbability, expectedValue: expectedValue }
  };
})(window.CPS = window.CPS || {});

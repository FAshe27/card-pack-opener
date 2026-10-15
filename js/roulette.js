/* ============================================================================
 * PackRipper Arcade — Roulette (REAL ECONOMY, Sandbox testing phase)
 * ----------------------------------------------------------------------------
 * Standard European roulette with real numbers and a real betting table:
 * click a bet space to place ONE token on it, click again to remove it.
 * Every standard bet is here — straights, splits, streets, trios, corners,
 * the first four, lines, dozens, columns and the even-money chances —
 * paying the standard odds (35:1 down to 1:1). For every bet on the table,
 * coverage x (odds + 1) = 36, so the theoretical return is a uniform 36/37.
 *
 * Real tokens: migration 150's cps_roulette_state / cps_roulette_spin.
 * The client only collects the layout and animates the result; the
 * SERVER validates every bet (kind + exact number set), charges the
 * stake, draws the number and pays out. Admin-only server-side while
 * Roulette is in the Sandbox; the gate drops at graduation.
 * ========================================================================== */
(function () {
  'use strict';
  window.CPS = window.CPS || {};
  var ctx = CPS.appCtx || {};

  /* ------------------------------ the wheel ------------------------------ */
  // European single-zero wheel order, clockwise.
  var WHEEL = [0, 32, 15, 19, 4, 21, 2, 25, 17, 34, 6, 27, 13, 36, 11, 30, 8, 23,
    10, 5, 24, 16, 33, 1, 20, 14, 31, 9, 22, 18, 29, 7, 28, 12, 35, 3, 26];
  var RED = [1, 3, 5, 7, 9, 12, 14, 16, 18, 19, 21, 23, 25, 27, 30, 32, 34, 36];
  function colorOf(n) { return n === 0 ? 'green' : (RED.indexOf(n) >= 0 ? 'red' : 'black'); }
  function range(a, b) { var o = []; for (var i = a; i <= b; i++) o.push(i); return o; }

  /* ---------------------------- the bet spaces -----------------------------
   * Table geometry, in grid units. The number area is 13 units wide
   * (zero = x 0..1, then 12 streets of three) and 3 units tall:
   *   top row y 0:    3  6  9 ... 36      middle row y 1: 2  5  8 ... 35
   *   bottom row y 2: 1  4  7 ... 34      column bets sit at x 13..14.
   * Hotspot x/y is where the chip sits (cell centres, shared borders and
   * corners — the same places a real chip goes).                           */
  var TX = 14.15; // total table width in units (incl. the column-bet slot)
  function streetOf(n) { return Math.ceil(n / 3); }            // 1..12
  function rowOf(n) { var p = n - 3 * (streetOf(n) - 1); return 3 - p; } // 0 top, 2 bottom

  function buildSpots() {
    var spots = [];
    function add(kind, label, mult, nums, x, y) {
      spots.push({ key: kind + ':' + nums.join('-'), kind: kind, label: label,
        mult: mult, nums: nums.slice(), x: x, y: y });
    }
    var n, s;
    // Straights (incl. zero)
    add('straight', '0', 35, [0], 0.5, 1.5);
    for (n = 1; n <= 36; n++) add('straight', String(n), 35, [n], streetOf(n) + 0.5, rowOf(n) + 0.5);
    // Splits inside a street (e.g. 1-2, 2-3)
    for (s = 1; s <= 12; s++) {
      add('split', (3 * s - 2) + '-' + (3 * s - 1), 17, [3 * s - 2, 3 * s - 1], s + 0.5, 2);
      add('split', (3 * s - 1) + '-' + (3 * s), 17, [3 * s - 1, 3 * s], s + 0.5, 1);
    }
    // Splits across streets (e.g. 1-4, 2-5, 3-6)
    for (n = 1; n <= 33; n++) add('split', n + '-' + (n + 3), 17, [n, n + 3], streetOf(n) + 1, rowOf(n) + 0.5);
    // Splits off the zero
    add('split', '0-1', 17, [0, 1], 1, 2.5);
    add('split', '0-2', 17, [0, 2], 1, 1.5);
    add('split', '0-3', 17, [0, 3], 1, 0.5);
    // Streets (three in a column) — chip on the street's bottom edge
    for (s = 1; s <= 12; s++) add('street', (3 * s - 2) + '-' + (3 * s), 11, [3 * s - 2, 3 * s - 1, 3 * s], s + 0.5, 3);
    // Trios off the zero
    add('trio', '0-1-2', 11, [0, 1, 2], 1, 2);
    add('trio', '0-2-3', 11, [0, 2, 3], 1, 1);
    // Corners (2x2 blocks)
    for (s = 1; s <= 11; s++) {
      add('corner', (3 * s - 2) + '/' + (3 * s + 2), 8, [3 * s - 2, 3 * s - 1, 3 * s + 1, 3 * s + 2], s + 1, 2);
      add('corner', (3 * s - 1) + '/' + (3 * s + 3), 8, [3 * s - 1, 3 * s, 3 * s + 2, 3 * s + 3], s + 1, 1);
    }
    // First four (0-1-2-3)
    add('firstfour', '0-1-2-3', 8, [0, 1, 2, 3], 1, 3);
    // Lines (two adjacent streets) — chip at the bottom corner between them
    for (s = 1; s <= 11; s++) add('line', (3 * s - 2) + '-' + (3 * s + 3), 5, range(3 * s - 2, 3 * s + 3), s + 1, 3);
    return spots;
  }

  // Outside bets, laid out as buttons rather than hotspots.
  function buildOutside() {
    function numsWhere(fn) { return range(1, 36).filter(fn); }
    return [
      { key: 'dozen:1', kind: 'dozen', label: '1st 12', mult: 2, nums: range(1, 12) },
      { key: 'dozen:2', kind: 'dozen', label: '2nd 12', mult: 2, nums: range(13, 24) },
      { key: 'dozen:3', kind: 'dozen', label: '3rd 12', mult: 2, nums: range(25, 36) },
      { key: 'col:0', kind: 'column', label: '2:1', mult: 2, nums: numsWhere(function (n) { return n % 3 === 0; }) },
      { key: 'col:1', kind: 'column', label: '2:1', mult: 2, nums: numsWhere(function (n) { return n % 3 === 2; }) },
      { key: 'col:2', kind: 'column', label: '2:1', mult: 2, nums: numsWhere(function (n) { return n % 3 === 1; }) },
      { key: 'low', kind: 'evenmoney', label: '1–18', mult: 1, nums: range(1, 18) },
      { key: 'even', kind: 'evenmoney', label: 'Even', mult: 1, nums: numsWhere(function (n) { return n % 2 === 0; }) },
      { key: 'red', kind: 'evenmoney', label: '🔴 Red', mult: 1, nums: RED.slice() },
      { key: 'black', kind: 'evenmoney', label: '⚫ Black', mult: 1, nums: numsWhere(function (n) { return RED.indexOf(n) < 0; }) },
      { key: 'odd', kind: 'evenmoney', label: 'Odd', mult: 1, nums: numsWhere(function (n) { return n % 2 === 1; }) },
      { key: 'high', kind: 'evenmoney', label: '19–36', mult: 1, nums: range(19, 36) }
    ];
  }

  var SPOTS = buildSpots();
  var OUTSIDE = buildOutside();
  var ALL = SPOTS.concat(OUTSIDE);
  var BY_KEY = {};
  ALL.forEach(function (b) { BY_KEY[b.key] = b; });

  // The wire format the server validates: {kind, nums}. Inside bets keep
  // their kind; outside bets map to their canonical server names.
  function wireKind(b) {
    if (b.kind === 'dozen') return 'dozen' + b.key.split(':')[1];
    if (b.kind === 'column') return 'column' + b.key.split(':')[1];
    if (b.kind === 'evenmoney') return b.key;
    return b.kind;
  }
  function wireBet(b) { return { kind: wireKind(b), nums: b.nums.slice().sort(function (x, y) { return x - y; }) }; }
  // Reverse lookup for naming server-returned wins.
  var BY_WIRE = {};
  ALL.forEach(function (b) { var w = wireBet(b); BY_WIRE[w.kind + ':' + w.nums.join('-')] = b; });
  function winLabel(w) {
    var b = BY_WIRE[w.kind + ':' + w.nums.slice().sort(function (x, y) { return x - y; }).join('-')];
    return b ? b.label : w.kind;
  }

  /* --------------------------------- state -------------------------------- */
  var state = null;
  function freshState() {
    return { tokens: 0, loaded: false, loadError: '', placed: new Set(), spinning: false,
      rotation: 0, last: null, history: [], spins: 0, staked: 0, returned: 0 };
  }
  var spinMs = 4600;

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function stake() { return state ? state.placed.size : 0; } // one token per space

  function syncBadges() {
    try {
      if (ctx.S) ctx.S.gameTokens = state.tokens;
      if (CPS.games && CPS.games.setTokens) CPS.games.setTokens(state.tokens);
      if (CPS.packsBadge && CPS.packsBadge.update) CPS.packsBadge.update();
    } catch (e) { /* non-fatal */ }
  }

  async function loadState() {
    try {
      var r = await CPS.cloud.call('roulette_state', {});
      state.tokens = r.tokens;
      state.loaded = true;
      state.loadError = '';
      syncBadges();
    } catch (e) {
      state.loadError = (e && e.message) || 'Could not reach the server.';
    }
    draw();
  }

  /* --------------------------------- render -------------------------------- */
  var root = null;

  function wheelSVG() {
    var step = 360 / 37, out = [], i, n, a0, a1, r1 = 148, r2 = 106, cx = 160, cy = 160;
    function pt(r, deg) {
      var rad = (deg - 90) * Math.PI / 180;
      return (cx + r * Math.cos(rad)).toFixed(1) + ',' + (cy + r * Math.sin(rad)).toFixed(1);
    }
    for (i = 0; i < 37; i++) {
      n = WHEEL[i]; a0 = i * step; a1 = a0 + step;
      var col = colorOf(n) === 'green' ? '#1d7a3a' : colorOf(n) === 'red' ? '#b3232a' : '#20242c';
      out.push('<path d="M' + pt(r2, a0) + ' L' + pt(r1, a0) + ' A' + r1 + ',' + r1 + ' 0 0 1 ' + pt(r1, a1) +
        ' L' + pt(r2, a1) + ' A' + r2 + ',' + r2 + ' 0 0 0 ' + pt(r2, a0) + ' Z" fill="' + col + '" stroke="#0d0f13" stroke-width="1"/>');
      var mid = a0 + step / 2, lp = pt(127, mid).split(',');
      out.push('<text x="' + lp[0] + '" y="' + lp[1] + '" fill="#fff" font-size="12" font-weight="700" ' +
        'text-anchor="middle" dominant-baseline="middle" transform="rotate(' + mid.toFixed(1) + ' ' + lp[0] + ' ' + lp[1] + ')">' + n + '</text>');
    }
    return '<svg viewBox="0 0 320 320" class="rlt-svg" aria-hidden="true">' + out.join('') +
      '<circle cx="160" cy="160" r="104" fill="#14161c"/><circle cx="160" cy="160" r="104" fill="none" stroke="#39404e" stroke-width="2"/></svg>';
  }

  function render(el) {
    root = el;
    if (!state) state = freshState();
    if (!ctx || !ctx.isCloud || !ctx.isCloud()) {
      el.innerHTML = '<div class="panel"><h2>🎡 Roulette</h2>' +
        '<p class="muted">Roulette plays for real tokens — log in online to play.</p></div>';
      return;
    }
    draw();
    if (!state.loaded && !state.spinning) loadState();
  }

  function draw() {
    if (!root || !state) return;
    var st = stake();
    var cells = [], i, n;
    cells.push('<div class="rlt-cell rlt-green" data-num="0" style="left:0%;top:0%;width:' + (100 / TX) +
      '%;height:100%"><span>0</span></div>');
    for (n = 1; n <= 36; n++) {
      cells.push('<div class="rlt-cell rlt-' + colorOf(n) + (state.last && state.last.n === n ? ' rlt-hit' : '') +
        '" data-num="' + n + '" style="left:' + ((streetOf(n)) / TX * 100) + '%;top:' + (rowOf(n) / 3 * 100) +
        '%;width:' + (100 / TX) + '%;height:' + (100 / 3) + '%"><span>' + n + '</span></div>');
    }
    for (i = 0; i < 3; i++) {
      cells.push('<div class="rlt-cell rlt-colbet" style="left:' + (13.1 / TX * 100) + '%;top:' + (i / 3 * 100) +
        '%;width:' + (0.95 / TX * 100) + '%;height:' + (100 / 3) + '%"><span>2:1</span></div>');
    }
    var spots = SPOTS.map(function (b) {
      var on = state.placed.has(b.key);
      return '<button type="button" class="rlt-spot' + (on ? ' rlt-on' : '') + '" data-key="' + b.key + '"' +
        (state.spinning ? ' disabled' : '') + ' title="' + esc(b.kind + ' ' + b.label + ' — pays ' + b.mult + ':1') +
        '" style="left:' + (b.x / TX * 100) + '%;top:' + (b.y / 3 * 100) + '%">' + (on ? '🪙' : '') + '</button>';
    }).join('');
    var colSpots = OUTSIDE.filter(function (b) { return b.kind === 'column'; }).map(function (b, i) {
      var on = state.placed.has(b.key);
      return '<button type="button" class="rlt-spot rlt-colspot' + (on ? ' rlt-on' : '') + '" data-key="' + b.key + '"' +
        (state.spinning ? ' disabled' : '') + ' title="Column — pays 2:1" style="left:' + (13.575 / TX * 100) +
        '%;top:' + ((i + 0.5) / 3 * 100) + '%">' + (on ? '🪙' : '') + '</button>';
    }).join('');
    function outBtn(b) {
      var on = state.placed.has(b.key);
      return '<button type="button" class="rlt-out' + (on ? ' rlt-on' : '') + '" data-key="' + b.key + '"' +
        (state.spinning ? ' disabled' : '') + '>' + esc(b.label) + (on ? ' 🪙' : '') + '</button>';
    }
    var dozens = OUTSIDE.filter(function (b) { return b.kind === 'dozen'; }).map(outBtn).join('');
    var evens = OUTSIDE.filter(function (b) { return b.kind === 'evenmoney'; }).map(outBtn).join('');

    var result = '';
    if (state.loadError && !state.loaded) {
      result = '<div class="rlt-result" role="status">⚠️ ' + esc(state.loadError) +
        ' — if this is a fresh deploy, has migration 150 been run?</div>';
    } else if (state.last) {
      var L = state.last;
      result = '<div class="rlt-result" role="status">' +
        '<span class="rlt-ball rlt-' + colorOf(L.n) + '">' + L.n + '</span> ' +
        (L.returned > 0
          ? '<strong>' + L.n + ' ' + colorOf(L.n) + ' — you won ' + L.returned + ' tokens!</strong> ' +
            '<span class="rlt-wins">' + L.wins.map(function (w) { return esc(winLabel(w)) + ' (' + w.mult + ':1)'; }).join(' · ') + '</span>'
          : '<strong>' + L.n + ' ' + colorOf(L.n) + ' — no win this spin.</strong>') +
        ' <span class="rlt-net">(staked ' + L.staked + ', net ' + (L.returned - L.staked >= 0 ? '+' : '') + (L.returned - L.staked) + ')</span></div>';
    }
    var history = state.history.length
      ? '<div class="rlt-history">Recent: ' + state.history.map(function (h) {
          return '<span class="rlt-hist rlt-' + colorOf(h) + '">' + h + '</span>';
        }).join('') + '</div>'
      : '';

    root.innerHTML =
      '<div class="rlt-wrap">' +
        '<p class="sbx-note">Standard European roulette — <b>real tokens</b>, Sandbox testing. Click any bet space to place a token on it (splits, corners and lines sit on the borders, just like a real table); click again to pick it back up. The server validates every bet and draws the number.</p>' +
        '<div class="rlt-top">' +
          '<div class="rlt-wheelbox"><div class="rlt-pointer">▼</div>' +
            '<div class="rlt-rotor" id="rltRotor">' + wheelSVG() + '</div>' +
            '<div class="rlt-center" id="rltCenter">' + (state.last ? state.last.n : '🎯') + '</div></div>' +
          '<div class="rlt-side">' +
            '<div class="rlt-balance">Tokens: <strong id="rltBal">' + (state.loaded ? state.tokens : '…') + '</strong> 🪙</div>' +
            '<div class="rlt-stake">On the table: <strong id="rltStake">' + st + '</strong> token' + (st === 1 ? '' : 's') + '</div>' +
            '<div class="rlt-actions">' +
              '<button type="button" class="btn primary" id="rltSpin"' + (state.spinning || !state.loaded || st === 0 || st > state.tokens ? ' disabled' : '') + '>🎡 Spin</button>' +
              '<button type="button" class="btn" id="rltClear"' + (state.spinning || st === 0 ? ' disabled' : '') + '>Clear table</button>' +
            '</div>' +
            (state.loaded && st > state.tokens ? '<p class="rlt-warn">That\'s more tokens than you have — pick some back up.</p>' : '') +
            result + history +
            '<p class="rlt-session">Session: ' + state.spins + ' spins · staked ' + state.staked + ' · returned ' + state.returned + '</p>' +
          '</div>' +
        '</div>' +
        '<div class="rlt-tablescroll"><div class="rlt-table">' + cells.join('') + spots + colSpots + '</div></div>' +
        '<div class="rlt-outrow">' + dozens + '</div>' +
        '<div class="rlt-outrow">' + evens + '</div>' +
        '<details class="rlt-odds"><summary>Bet guide &amp; odds</summary><div class="rlt-oddsgrid">' +
          '<div><strong>Straight</strong> 1 number · 35:1</div><div><strong>Split</strong> 2 numbers · 17:1</div>' +
          '<div><strong>Street / Trio</strong> 3 numbers · 11:1</div><div><strong>Corner / First four</strong> 4 numbers · 8:1</div>' +
          '<div><strong>Line</strong> 6 numbers · 5:1</div><div><strong>Dozen / Column</strong> 12 numbers · 2:1</div>' +
          '<div><strong>Red / Black / Even / Odd / High / Low</strong> 18 numbers · 1:1</div>' +
          '<p>Every bet returns stake × (odds + 1) when it hits, and coverage × (odds + 1) is always 36 — so the theoretical return is a uniform 36/37 ≈ 97.3%, the real European game.</p>' +
        '</div></details>' +
      '</div>';

    var rotor = root.querySelector('#rltRotor');
    if (rotor) {
      rotor.style.transition = 'none';
      rotor.style.transform = 'rotate(' + state.rotation + 'deg)';
    }
    root.querySelectorAll('.rlt-spot, .rlt-out').forEach(function (btn) {
      btn.addEventListener('click', function () { toggle(btn.dataset.key); });
    });
    var spin = root.querySelector('#rltSpin'); if (spin) spin.addEventListener('click', function () { spinWheel(); });
    var clear = root.querySelector('#rltClear'); if (clear) clear.addEventListener('click', function () { state.placed.clear(); draw(); });
  }

  function toggle(key) {
    if (!state || state.spinning) return;
    if (state.placed.has(key)) state.placed.delete(key);
    else state.placed.add(key);
    draw();
  }

  async function spinWheel() {
    if (!state || state.spinning || !state.loaded) return;
    var st = stake();
    if (st === 0 || st > state.tokens) return;
    state.spinning = true;
    draw();
    var resp;
    try {
      var bets = [];
      state.placed.forEach(function (key) { bets.push(wireBet(BY_KEY[key])); });
      resp = await CPS.cloud.call('roulette_spin', { p_bets: bets });
    } catch (e) {
      state.spinning = false;
      state.last = null;
      draw();
      var box = root && root.querySelector('.rlt-side');
      if (box) {
        var warn = document.createElement('div');
        warn.className = 'rlt-result'; warn.setAttribute('role', 'status');
        warn.textContent = '⚠️ ' + ((e && e.message) || 'Spin failed — try again.');
        box.appendChild(warn);
      }
      return;
    }
    var n = resp.result;
    var idx = WHEEL.indexOf(n);
    var step = 360 / 37;
    var prev = state.rotation;
    var targetNorm = ((-(idx * step + step / 2)) % 360 + 360) % 360;
    state.rotation = prev + 360 * 5 + ((targetNorm - (prev % 360)) + 360) % 360;
    draw();
    var rotor = root && root.querySelector('#rltRotor');
    if (rotor) { // draw() rebuilt the DOM: restart the rotor at the old angle
      rotor.style.transition = 'none';
      rotor.style.transform = 'rotate(' + prev + 'deg)';
      void rotor.offsetWidth;
      rotor.style.transition = 'transform ' + spinMs + 'ms cubic-bezier(.12,.8,.16,1)';
      rotor.style.transform = 'rotate(' + state.rotation + 'deg)';
    }
    setTimeout(function () {
      state.spinning = false;
      state.tokens = resp.tokens_now;
      state.spins += 1; state.staked += resp.stake; state.returned += resp.returned;
      state.last = { n: n, staked: resp.stake, returned: resp.returned, wins: resp.wins || [] };
      state.history.unshift(n);
      if (state.history.length > 14) state.history.length = 14;
      state.placed.clear();
      syncBadges();
      draw();
    }, spinMs + 30);
  }

  function teardown() { root = null; }

  CPS.roulette = {
    render: render,
    teardown: teardown,
    _test: {
      state: function () { return state; },
      spots: function () { return ALL; },
      wireBets: function () {
        var out = [];
        if (state) state.placed.forEach(function (k) { out.push(wireBet(BY_KEY[k])); });
        return out;
      },
      allWireBets: function () { return ALL.map(wireBet); },
      toggle: toggle,
      spin: spinWheel,
      setSpinMs: function (ms) { spinMs = ms; },
      resetState: function () { state = freshState(); }
    }
  };
})();

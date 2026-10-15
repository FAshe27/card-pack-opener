/* ============================================================================
 * PackRipper Arcade — Roulette (SANDBOX PROTOTYPE)
 * ----------------------------------------------------------------------------
 * Standard European roulette with real numbers and a real betting table:
 * click a bet space to place ONE test token on it, click again to remove it.
 * Every standard bet is here — straights, splits, streets, trios, corners,
 * the first four, lines, dozens, columns and the even-money chances — paying
 * the standard odds (35:1 down to 1:1). For every bet on the table,
 * coverage x (odds + 1) = 36, so the theoretical return is a uniform 36/37.
 *
 * FAKE MONEY ONLY (Franklin, 2026-10-14): a Sandbox test balance that lives
 * in this module (starts at 100, Reset restores it). No server RPCs, no real
 * tokens, no packs — exactly like the original Plinko/Scratchoffs prototypes.
 * If it graduates, the spin + settlement move server-side the way
 * Scratchoffs did (migration + cps_roulette_spin validating every bet).
 * ========================================================================== */
(function () {
  'use strict';
  window.CPS = window.CPS || {};

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
    var n, s, r;
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

  /* --------------------------------- state -------------------------------- */
  var START_BALANCE = 100;
  function storeKey() {
    var a = 'guest';
    try {
      var S = CPS.appCtx && CPS.appCtx.S;
      if (S && S.acct && S.acct.id) a = S.acct.id;
    } catch (e) { /* guest */ }
    return 'cps_roulette_' + a;
  }
  function loadBalance() {
    try {
      var v = JSON.parse(localStorage.getItem(storeKey()) || 'null');
      if (v && typeof v.b === 'number' && v.b >= 0) return v.b;
    } catch (e) { /* fall through */ }
    return START_BALANCE;
  }
  function saveBalance() {
    try { localStorage.setItem(storeKey(), JSON.stringify({ b: state.balance })); } catch (e) { /* non-fatal */ }
  }

  var state = null;
  function freshState() {
    return { balance: loadBalance(), placed: new Set(), spinning: false,
      rotation: 0, last: null, history: [], spins: 0, staked: 0, returned: 0 };
  }
  var spinMs = 4600;

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function stake() {
    if (!state) return 0;
    return state.placed.size; // one test token per space
  }

  /* ------------------------------- settlement ------------------------------ */
  // Pure settlement: given the winning number, what does the current layout
  // return? Returns {returned, wins:[{key,label,mult,pay}]} where pay is the
  // total returned for that space (stake back + winnings).
  function settleFor(n) {
    var returned = 0, wins = [];
    state.placed.forEach(function (key) {
      var b = BY_KEY[key];
      if (b && b.nums.indexOf(n) >= 0) {
        var pay = b.mult + 1;
        returned += pay;
        wins.push({ key: key, label: b.label, kind: b.kind, mult: b.mult, pay: pay });
      }
    });
    return { returned: returned, wins: wins };
  }

  function applySettle(n) {
    var st = stake();
    var res = settleFor(n);
    state.balance += res.returned;
    state.spins += 1; state.staked += st; state.returned += res.returned;
    state.last = { n: n, staked: st, returned: res.returned, wins: res.wins };
    state.history.unshift(n);
    if (state.history.length > 14) state.history.length = 14;
    state.placed.clear();
    saveBalance();
    return state.last;
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
    draw();
  }

  function draw() {
    if (!root) return;
    var st = stake();
    var cells = [], i, n;
    // number cells (zero spans all three rows)
    cells.push('<div class="rlt-cell rlt-green" data-num="0" style="left:0%;top:0%;width:' + (100 / TX) +
      '%;height:100%"><span>0</span></div>');
    for (n = 1; n <= 36; n++) {
      cells.push('<div class="rlt-cell rlt-' + colorOf(n) + (state.last && state.last.n === n ? ' rlt-hit' : '') +
        '" data-num="' + n + '" style="left:' + ((streetOf(n)) / TX * 100) + '%;top:' + (rowOf(n) / 3 * 100) +
        '%;width:' + (100 / TX) + '%;height:' + (100 / 3) + '%"><span>' + n + '</span></div>');
    }
    // column-bet cells (visual only; the bet itself is a hotspot at x 13.55)
    for (i = 0; i < 3; i++) {
      cells.push('<div class="rlt-cell rlt-colbet" style="left:' + (13.1 / TX * 100) + '%;top:' + (i / 3 * 100) +
        '%;width:' + (0.95 / TX * 100) + '%;height:' + (100 / 3) + '%"><span>2:1</span></div>');
    }
    // hotspots over the number area
    var spots = SPOTS.map(function (b) {
      var on = state.placed.has(b.key);
      return '<button type="button" class="rlt-spot' + (on ? ' rlt-on' : '') + '" data-key="' + b.key + '"' +
        (state.spinning ? ' disabled' : '') + ' title="' + esc(b.kind + ' ' + b.label + ' — pays ' + b.mult + ':1') +
        '" style="left:' + (b.x / TX * 100) + '%;top:' + (b.y / 3 * 100) + '%">' + (on ? '🪙' : '') + '</button>';
    }).join('');
    // column bets are hotspots too (they live outside SPOTS' x range logic)
    var colSpots = OUTSIDE.filter(function (b) { return b.kind === 'column'; }).map(function (b, i) {
      var on = state.placed.has(b.key);
      return '<button type="button" class="rlt-spot rlt-colspot' + (on ? ' rlt-on' : '') + '" data-key="' + b.key + '"' +
        (state.spinning ? ' disabled' : '') + ' title="Column — pays 2:1" style="left:' + (13.575 / TX * 100) +
        '%;top:' + ((i + 0.5) / 3 * 100) + '%">' + (on ? '🪙' : '') + '</button>';
    }).join('');
    var dozens = OUTSIDE.filter(function (b) { return b.kind === 'dozen'; }).map(function (b) {
      var on = state.placed.has(b.key);
      return '<button type="button" class="rlt-out' + (on ? ' rlt-on' : '') + '" data-key="' + b.key + '"' +
        (state.spinning ? ' disabled' : '') + '>' + esc(b.label) + (on ? ' 🪙' : '') + '</button>';
    }).join('');
    var evens = OUTSIDE.filter(function (b) { return b.kind === 'evenmoney'; }).map(function (b) {
      var on = state.placed.has(b.key);
      return '<button type="button" class="rlt-out' + (on ? ' rlt-on' : '') + '" data-key="' + b.key + '"' +
        (state.spinning ? ' disabled' : '') + '>' + esc(b.label) + (on ? ' 🪙' : '') + '</button>';
    }).join('');

    var result = '';
    if (state.last) {
      var L = state.last;
      result = '<div class="rlt-result" role="status">' +
        '<span class="rlt-ball rlt-' + colorOf(L.n) + '">' + L.n + '</span> ' +
        (L.returned > 0
          ? '<strong>' + L.n + ' ' + colorOf(L.n) + ' — you won ' + L.returned + ' test tokens!</strong> ' +
            '<span class="rlt-wins">' + L.wins.map(function (w) { return esc(w.label) + ' (' + w.mult + ':1)'; }).join(' · ') + '</span>'
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
        '<p class="sbx-note">Standard European roulette — fake test tokens, Sandbox only. Click any bet space to place a token on it (splits, corners and lines sit on the borders, just like a real table); click again to pick it back up. The wheel pays the standard odds.</p>' +
        '<div class="rlt-top">' +
          '<div class="rlt-wheelbox"><div class="rlt-pointer">▼</div>' +
            '<div class="rlt-rotor" id="rltRotor">' + wheelSVG() + '</div>' +
            '<div class="rlt-center" id="rltCenter">' + (state.last ? state.last.n : '🎯') + '</div></div>' +
          '<div class="rlt-side">' +
            '<div class="rlt-balance">Test tokens: <strong id="rltBal">' + state.balance + '</strong> 🪙</div>' +
            '<div class="rlt-stake">On the table: <strong id="rltStake">' + st + '</strong> token' + (st === 1 ? '' : 's') + '</div>' +
            '<div class="rlt-actions">' +
              '<button type="button" class="btn primary" id="rltSpin"' + (state.spinning || st === 0 || st > state.balance ? ' disabled' : '') + '>🎡 Spin</button>' +
              '<button type="button" class="btn" id="rltClear"' + (state.spinning || st === 0 ? ' disabled' : '') + '>Clear table</button>' +
              '<button type="button" class="btn" id="rltReset">Reset test balance</button>' +
            '</div>' +
            (st > state.balance ? '<p class="rlt-warn">That\'s more tokens than you have — pick some back up.</p>' : '') +
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
      rotor.style.transition = state.spinning ? 'transform ' + spinMs + 'ms cubic-bezier(.12,.8,.16,1)' : 'none';
      rotor.style.transform = 'rotate(' + state.rotation + 'deg)';
    }
    root.querySelectorAll('.rlt-spot, .rlt-out').forEach(function (btn) {
      btn.addEventListener('click', function () { toggle(btn.dataset.key); });
    });
    var spin = root.querySelector('#rltSpin'); if (spin) spin.addEventListener('click', function () { spinWheel(); });
    var clear = root.querySelector('#rltClear'); if (clear) clear.addEventListener('click', function () { state.placed.clear(); draw(); });
    var reset = root.querySelector('#rltReset'); if (reset) reset.addEventListener('click', function () {
      state.balance = START_BALANCE; state.placed.clear(); saveBalance(); draw();
    });
  }

  function toggle(key) {
    if (!state || state.spinning) return;
    if (state.placed.has(key)) state.placed.delete(key);
    else state.placed.add(key);
    draw();
  }

  function spinWheel(resultOverride) {
    if (!state || state.spinning) return null;
    var st = stake();
    if (st === 0 || st > state.balance) return null;
    state.balance -= st;
    saveBalance();
    var n = (typeof resultOverride === 'number') ? resultOverride : WHEEL[Math.floor(Math.random() * 37)];
    var idx = WHEEL.indexOf(n);
    var step = 360 / 37;
    // Land the winning pocket under the top pointer: pocket centre starts at
    // idx*step + step/2 (SVG is drawn from -90deg), so the final resting
    // angle must be the negative of that, mod 360. Spin 5 full turns from
    // wherever the wheel currently rests.
    var prev = state.rotation;
    var targetNorm = ((-(idx * step + step / 2)) % 360 + 360) % 360;
    state.rotation = prev + 360 * 5 + ((targetNorm - (prev % 360)) + 360) % 360;
    state.spinning = true;
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
      applySettle(n);
      draw();
    }, spinMs + 30);
    return n;
  }

  function teardown() { root = null; }

  CPS.roulette = {
    render: render,
    teardown: teardown,
    _test: {
      state: function () { return state; },
      spots: function () { return ALL; },
      settleFor: settleFor,
      toggle: toggle,
      spin: spinWheel,
      setSpinMs: function (ms) { spinMs = ms; },
      resetState: function () { state = freshState(); state.balance = START_BALANCE; }
    }
  };
})();

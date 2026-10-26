/* WordGuesser — REAL economy, server-dealt (migration 193).
   Sandbox 'testing' phase: the RPCs are admin-gated server-side.
   The answer lives ONLY on the server (cps.wordle_games) and is never
   sent to the client while a game is playing; guesses are validated
   and scored by cps_wordle_guess, which returns tile marks only.
   This file ships NO word list. Real game tokens in (first game each
   Chicago day free, extras 10), real packs + spin tickets out.
   Consumes CPS.appCtx + CPS.cloud.call like js/vaultbreaker.js. */
(function (CPS) {
  'use strict';
  CPS.sandbox = CPS.sandbox || {};
  var ctx = CPS.appCtx;

  /* Display fallback only — wordle_state hands down the server's own
     table (cps.wordle_table, derived from cps.wordle_prize) and it
     replaces this on load, so the numbers can never drift. */
  var PRIZES = [
    { guesses: 1, packs: 10, tickets: 10, text: '10 random packs + 10 spin tickets' },
    { guesses: 2, packs: 10, tickets: 5, text: '10 random packs + 5 spin tickets' },
    { guesses: 3, packs: 5, tickets: 5, text: '5 random packs + 5 spin tickets' },
    { guesses: 4, packs: 0, tickets: 5, text: '5 spin tickets' },
    { guesses: 5, packs: 5, tickets: 0, text: '5 random packs' },
    { guesses: 6, packs: 3, tickets: 0, text: '3 random packs' }
  ];

  var S = {
    loaded: false, busy: false, loadError: false,
    tokens: 0, spins: 0, cost: 10, freeAvailable: true,
    game: null,      // the playing game (server payload), or null
    lastGame: null,  // today's latest finished game (server payload)
    table: PRIZES,
    stats: null,
    input: ''
  };

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function displayGame() { return S.game || S.lastGame; }

  /* ---------------- server sync ------------------------------------- */
  function syncBadges() {
    try {
      // Mirror BOTH balances into the app state and refresh the header
      // badges, so a prize (or a paid start) shows in the top bar without
      // a reload -- spins were the missing half (Franklin, 2026-10-26).
      if (ctx.S) { ctx.S.gameTokens = S.tokens; ctx.S.spins = S.spins; }
      if (CPS.games && CPS.games.setTokens) CPS.games.setTokens(S.tokens);
      if (ctx.updateWheelBadge) ctx.updateWheelBadge();
      if (CPS.packsBadge && CPS.packsBadge.update) CPS.packsBadge.update();
    } catch (e) { /* non-fatal */ }
  }

  /* Pack prizes land in S.player.sets only on a full state load —
     pull the inventory counts the way js/vaultbreaker.js does. */
  async function refreshPackCounts() {
    try {
      var st = await CPS.cloud.call('get_state');
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

  function applyState(r) {
    S.tokens = r.tokens_now; S.spins = r.spins_now;
    if (r.cost) S.cost = r.cost;
    S.freeAvailable = !!r.free_available;
    if (r.table) S.table = r.table;
    if (r.stats) S.stats = r.stats;
    S.game = r.game || null;
    S.lastGame = r.last_game || null;
    if (S.game) S.input = '';
  }

  async function loadState() {
    try {
      var r = await CPS.cloud.call('wordle_state', {});
      applyState(r);
      S.loaded = true; S.loadError = false;
      syncBadges();
    } catch (e) {
      try { ctx.cloudError(e); } catch (e2) { /* fall through */ }
      S.loaded = true; S.loadError = true;
    }
    paint();
  }

  async function startGame() {
    if (S.busy || S.game || !S.loaded) return;
    if (!S.freeAvailable && S.tokens < S.cost) {
      try { ctx.toast('Not enough tokens — packs, quests and the Prize Wheel can earn more.', 'warn'); }
      catch (e) { /* non-fatal */ }
      return;
    }
    S.busy = true; paint();
    try {
      var r = await CPS.cloud.call('wordle_start', {});
      S.busy = false;
      S.game = r.game || null;
      S.lastGame = null;
      S.tokens = r.tokens_now; S.spins = r.spins_now;
      if (S.game && S.game.free) S.freeAvailable = false;
      S.input = '';
      syncBadges();
      paint();
    } catch (e) {
      S.busy = false;
      try { ctx.cloudError(e); } catch (e2) { /* fall through */ }
      loadState(); // resync with the server (it may have dealt the game)
    }
  }

  async function submitGuess() {
    var g = S.game;
    if (S.busy || !g || g.status !== 'playing') return;
    var w = S.input;
    if (w.length < 5) { nudge('Not enough letters'); return; }
    S.busy = true;
    try {
      var r = await CPS.cloud.call('wordle_guess', { p_guess: w });
      S.busy = false;
      S.game = (r.game && r.game.status === 'playing') ? r.game : null;
      if (r.game && r.game.status !== 'playing') S.lastGame = r.game;
      S.tokens = r.tokens_now; S.spins = r.spins_now;
      if (r.stats) S.stats = r.stats;
      S.input = '';
      animRow = (r.game ? r.game.guesses.length : 0) - 1;
      var won = r.game && r.game.status === 'won';
      var over = r.game && r.game.status !== 'playing';
      if (won) pendingWin = true;
      if (over && !won) pendingLose = true;
      if (over) { syncBadges(); refreshPackCounts(); }
      paint();
    } catch (e) {
      S.busy = false;
      var m = (e && e.message) || '';
      if (m.indexOf('Not in word list') !== -1) { nudge('Not in word list'); return; }
      if (m.indexOf('Not enough letters') !== -1) { nudge('Not enough letters'); return; }
      try { ctx.cloudError(e); } catch (e2) { /* fall through */ }
      loadState();
    }
  }

  /* ---------------- play -------------------------------------------- */
  function keyState() {
    // best-known state per letter: G > Y > X, from server marks
    var rank = { G: 2, Y: 1, X: 0 }, best = {}, g = displayGame();
    if (!g) return best;
    (g.guesses || []).forEach(function (gu, idx) {
      if (idx === animRow) return; // still flipping: its colours are not public yet
      for (var i = 0; i < 5; i++) {
        var ch = gu.word[i], v = gu.marks[i];
        if (best[ch] === undefined || rank[v] > rank[best[ch]]) best[ch] = v;
      }
    });
    return best;
  }
  function shareText() {
    var g = displayGame(); if (!g) return '';
    var head = 'WordGuesser ' + (g.status === 'won' ? g.guesses.length + '/6' : 'X/6');
    var rows = (g.guesses || []).map(function (gu) {
      return gu.marks.split('').map(function (v) {
        return v === 'G' ? '🟩' : (v === 'Y' ? '🟨' : '⬛');
      }).join('');
    });
    return head + '\n' + rows.join('\n') + '\n\nPlay PackRipper!';
  }
  function handleKey(k) {
    var g = S.game;
    if (!g || g.status !== 'playing') { preGameKey(k); return; }
    if (S.busy) return;
    if (k === 'ENTER') { submitGuess(); return; }
    if (k === 'BACK') { S.input = S.input.slice(0, -1); updateCurrentRow(); return; }
    if (/^[A-Z]$/.test(k) && S.input.length < 5) { S.input += k; updateCurrentRow(); }
  }
  /* Before a game starts the keyboard must not be silently dead
     (Franklin, 2026-10-26): a letter starts the FREE game and lands as
     the first letter; when only paid games remain it nudges instead --
     a stray tap never charges tokens. */
  function preGameKey(k) {
    if (S.busy || !S.loaded || S.loadError) return;
    if (!/^[A-Z]$/.test(k)) return;
    if (S.freeAvailable) {
      startGame().then(function () {
        if (S.game && S.game.status === 'playing' && !S.input) {
          S.input = k; updateCurrentRow();
        }
      });
    } else {
      nudge('Start a game first — Play again is ' + S.cost + ' 🪙');
    }
  }
  function onKeyDown(e) {
    if (!rootEl || !document.body.contains(rootEl)) return;
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    var tag = (e.target && e.target.tagName) || '';
    if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return;
    var mroot = document.getElementById('wrModalRoot');
    if (mroot && document.body.contains(mroot)) return; // a modal is up
    var k = e.key === 'Enter' ? 'ENTER' : (e.key === 'Backspace' ? 'BACK' : String(e.key || '').toUpperCase());
    if (k === 'ENTER' || k === 'BACK' || /^[A-Z]$/.test(k)) { e.preventDefault(); handleKey(k); }
  }

  /* ---------------- rendering ---------------------------------------- */
  var rootEl = null, animRow = -1, listening = false, pendingWin = false, pendingLose = false, flipTimer = null;
  var toastTimer = null;
  /* Wordle-style transient toast: guess errors flash in a pill over the
     board for ~a second and fade — they never park in the status line. */
  function nudge(t) {
    if (!rootEl) return;
    var toast = rootEl.querySelector('#wrToast');
    if (toast) {
      toast.textContent = t;
      toast.classList.add('show');
      if (toastTimer) clearTimeout(toastTimer);
      toastTimer = setTimeout(function () { toast.classList.remove('show'); }, 1300);
    }
    var row = rootEl.querySelector('.wr-row.cur');
    if (row) { row.classList.remove('wr-shake'); void row.offsetWidth; row.classList.add('wr-shake'); }
  }
  function tileCls(v) { return v === 'G' ? 'wr-t-green' : (v === 'Y' ? 'wr-t-yellow' : 'wr-t-gray'); }

  function boardHtml() {
    var g = displayGame(), html = '<div class="wr-board">';
    var guesses = g ? (g.guesses || []) : [];
    for (var r = 0; r < 6; r++) {
      var isCur = !!S.game && r === guesses.length;
      var isAnim = !!g && r === animRow && r < guesses.length;
      html += '<div class="wr-row' + (isCur ? ' cur' : '') + '">';
      for (var c = 0; c < 5; c++) {
        var ch = '', cls = 'wr-tile';
        if (r < guesses.length) {
          ch = guesses[r].word[c];
          cls += ' filled ' + tileCls(guesses[r].marks[c]) + (isAnim ? ' flip' : '');
        } else if (isCur && c < S.input.length) {
          ch = S.input[c]; cls += ' filled pop';
        }
        html += '<div class="' + cls + '"' + (isAnim ? ' style="animation-delay:' + (c * 120) + 'ms"' : '') + '>' + esc(ch) + '</div>';
      }
      html += '</div>';
    }
    return html + '</div>';
  }
  /* Typing updates ONLY the current row's tiles in place — a full repaint
     per keystroke would rebuild the submitted rows' tiles and restart
     their flip animations (Franklin's catch, 2026-10-26). */
  function updateCurrentRow() {
    if (!rootEl || !S.game) return;
    var row = rootEl.querySelector('.wr-row.cur');
    if (!row) { paint(); return; }
    var tiles = row.children;
    for (var c = 0; c < 5; c++) {
      var ch = c < S.input.length ? S.input[c] : '';
      if (tiles[c].textContent !== ch) {
        tiles[c].textContent = ch;
        tiles[c].className = 'wr-tile' + (ch ? ' filled pop' : '');
      }
    }
  }
  function keyboardHtml() {
    var rows = ['QWERTYUIOP', 'ASDFGHJKL', 'ZXCVBNM'], best = keyState();
    var html = '<div class="wr-kb">';
    rows.forEach(function (row, ri) {
      html += '<div class="wr-kb-row">';
      if (ri === 2) html += '<button type="button" class="wr-key wr-key-wide" data-wr-key="ENTER">ENTER</button>';
      row.split('').forEach(function (ch) {
        var v = best[ch];
        html += '<button type="button" class="wr-key' + (v !== undefined ? ' ' + tileCls(v) : '') + '" data-wr-key="' + ch + '">' + ch + '</button>';
      });
      if (ri === 2) html += '<button type="button" class="wr-key wr-key-wide" data-wr-key="BACK">⌫</button>';
      html += '</div>';
    });
    return html + '</div>';
  }
  function statsInnerHtml() {
    var st = S.stats || { played: 0, wins: 0, win_pct: 0, streak: 0, best_streak: 0, dist: {}, packs_won: 0, tickets_won: 0 };
    var dist = st.dist || {};
    var maxD = 1; for (var k = 1; k <= 6; k++) maxD = Math.max(maxD, dist[String(k)] || 0);
    var bars = '';
    for (var i = 1; i <= 6; i++) {
      var n = dist[String(i)] || 0;
      bars += '<div class="wr-dist-row"><span>' + i + '</span><div class="wr-dist-bar" style="width:' +
        Math.max(8, Math.round(100 * n / maxD)) + '%">' + n + '</div></div>';
    }
    return '<div class="wr-stat-grid">' +
      '<div><b>' + st.played + '</b><span>Played</span></div>' +
      '<div><b>' + st.win_pct + '%</b><span>Win rate</span></div>' +
      '<div><b>' + st.streak + '</b><span>Streak</span></div>' +
      '<div><b>' + st.best_streak + '</b><span>Best streak</span></div></div>' +
      '<h4>Guess distribution</h4>' + bars;
  }
  function openStats() {
    if (!ctx.openModal) return;
    ctx.openModal('<div id="wrModalRoot">' +
      '<button class="modal-x" data-close aria-label="Close">×</button>' +
      '<h2>📊 Your WordGuesser stats</h2>' + statsInnerHtml() +
      '<div class="modal-actions"><button class="btn" data-close>Close</button></div></div>');
    wireModal();
  }
  function showWinModal() {
    var g = displayGame();
    if (!g || g.status !== 'won' || !ctx.openModal) return;
    var grid = (g.guesses || []).map(function (gu) {
      return gu.marks.split('').map(function (v) {
        return v === 'G' ? '🟩' : (v === 'Y' ? '🟨' : '⬛');
      }).join('');
    }).join('<br>');
    ctx.openModal('<div id="wrModalRoot">' +
      '<button class="modal-x" data-close aria-label="Close">×</button>' +
      '<h2 style="text-align:center">🎉 WordGuesser 🎉</h2>' +
      '<p style="text-align:center;font-size:1.05rem;margin:6px 0">You got it in <b>' +
      g.guesses.length + (g.guesses.length === 1 ? ' guess' : ' guesses') + '</b>!</p>' +
      '<p style="text-align:center;letter-spacing:.35em;font-size:1.6rem;margin:10px 0">' + grid + '</p>' +
      '<p style="text-align:center">The word was <b>' + esc(g.answer || '') + '</b></p>' +
      '<p style="text-align:center">Prize: <b>' + esc(g.prize ? g.prize.text : '') + '</b></p>' +
      '<div class="modal-actions" style="display:flex;justify-content:center;gap:8px">' +
      '<button class="btn primary" id="wrCopyBtn2">Copy result</button>' +
      '<button class="btn" data-close>Close</button></div></div>');
    if (ctx.fx && ctx.fx.confetti) { try { ctx.fx.confetti(160); } catch (e) { /* non-fatal */ } }
    wireModal();
  }
  function showLoseModal() {
    var g = displayGame();
    if (!g || g.status !== 'lost' || !ctx.openModal) return;
    var grid = (g.guesses || []).map(function (gu) {
      return gu.marks.split('').map(function (v) {
        return v === 'G' ? '🟩' : (v === 'Y' ? '🟨' : '⬛');
      }).join('');
    }).join('<br>');
    ctx.openModal('<div id="wrModalRoot">' +
      '<button class="modal-x" data-close aria-label="Close">×</button>' +
      '<h2 style="text-align:center">😞 WordGuesser 😞</h2>' +
      '<p style="text-align:center;font-size:1.05rem;margin:6px 0">Out of guesses!</p>' +
      '<p style="text-align:center;letter-spacing:.35em;font-size:1.6rem;margin:10px 0">' + grid + '</p>' +
      '<p style="text-align:center;margin:6px 0 2px">The word was</p>' +
      '<p style="text-align:center;letter-spacing:.3em;font-size:1.9rem;font-weight:700;margin:0 0 8px">' +
      esc(g.answer || '') + '</p>' +
      '<p style="text-align:center">No prize this time — your streak resets.</p>' +
      '<div class="modal-actions" style="display:flex;justify-content:center;gap:8px">' +
      '<button class="btn primary" id="wrCopyBtn2">Copy result</button>' +
      '<button class="btn" data-close>Close</button></div></div>');
    wireModal();
  }
  function wireModal() {
    var mroot = document.getElementById('wrModalRoot');
    if (!mroot) return;
    mroot.querySelectorAll('[data-close]').forEach(function (b) {
      b.addEventListener('click', function () { if (ctx.closeModal) ctx.closeModal(); });
    });
    var c2 = mroot.querySelector('#wrCopyBtn2');
    if (c2) c2.addEventListener('click', copyResult);
  }
  function copyResult() {
    var t = shareText();
    if (!t) return;
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(t).then(function () {
        try { ctx.toast('Result copied — go brag!', 'ok'); } catch (e) { /* non-fatal */ }
      }, function () { /* clipboard denied: silent */ });
    }
  }
  function statusAndActions() {
    var g = S.game, d = displayGame(), statusLine, actionBtn = '';
    // While the just-submitted row is still flipping, nothing may give its
    // result away: the header keeps the in-progress wording and the
    // end-of-game buttons wait for the reveal (Franklin, 2026-10-26).
    if (animRow >= 0 && !g && !!d && animRow === d.guesses.length - 1) {
      return { statusLine: d.free ? 'Free game in progress — good luck!'
                                  : 'Game in progress (' + S.cost + ' tokens paid).', actionBtn: '' };
    }
    if (!S.loaded) {
      statusLine = 'Loading…';
    } else if (g) {
      statusLine = g.free ? 'Free game in progress — good luck!'
                          : 'Game in progress (' + S.cost + ' tokens paid).';
    } else if (d) {
      statusLine = d.status === 'won'
        ? '🎉 Solved in ' + d.guesses.length + (d.guesses.length === 1 ? ' guess' : ' guesses') +
          '! Prize: ' + (d.prize ? d.prize.text : '') + '.'
        : 'Out of guesses — the word was ' + (d.answer || '') + '.';
      actionBtn = '<button type="button" class="btn primary" id="wrNewBtn"' + (S.busy ? ' disabled' : '') + '>' +
        (S.freeAvailable ? 'Play again — free game' : 'Play again — ' + S.cost + ' 🪙') + '</button>' +
        '<button type="button" class="btn" id="wrCopyBtn">Copy result</button>';
    } else {
      statusLine = S.freeAvailable ? 'Your free game for today is ready.'
        : 'Free game used today — extra games cost ' + S.cost + ' tokens.';
      actionBtn = '<button type="button" class="btn primary" id="wrNewBtn"' + (S.busy ? ' disabled' : '') + '>' +
        (S.freeAvailable ? 'Play free game' : 'Start game — ' + S.cost + ' 🪙') + '</button>';
    }
    return { statusLine: statusLine, actionBtn: actionBtn };
  }
  function paint() {
    if (!rootEl) return;
    var sa = statusAndActions();
    /* Until a round begins, a translucent cover darkens the board +
       keyboard so the play area is unmistakably closed (Franklin,
       2026-10-26), with the start button right on it. It never covers
       a flipping row (animRow) or a game in progress, and it settles
       in only on the post-flip repaint like the end-of-game modal. */
    var coverHtml = '';
    if (S.loaded && !S.loadError && !S.busy && !S.game && animRow < 0) {
      coverHtml = '<div class="wr-cover"><button type="button" class="btn primary wr-cover-btn" id="wrCoverBtn">' +
        (S.freeAvailable ? 'Play free game' : 'Play again — ' + S.cost + ' 🪙') + '</button></div>';
    }
    rootEl.innerHTML =
      /* ONE big box: header, board, keyboard and the action buttons all
         live in a single panel; Play again / Copy / Stats sit BELOW the
         game (Franklin, 2026-10-26). */
      '<div class="wr-main"><div class="panel wr-game">' +
      '<button type="button" class="btn ghost wr-back" id="wrBackBtn">← Back to Arcade</button>' +
      '<div class="wr-head-in"><h2>🔤 WordGuesser</h2>' +
      '<p class="muted small">Guess the 5-letter word in 6 or fewer tries. Green means the right ' +
      'letter in the right spot. Yellow means the right letter, but in the wrong spot. If it\'s ' +
      'gray, it\'s not in the word at all. The better you do, the better your prize!</p>' +
      '<p class="muted small">Your first game every day is free - after that, it\'s 10 tokens to ' +
      'play again if you don\'t want to wait until reset.</p>' +
      '<div class="wr-topbar"><span class="wr-balance">🪙 <b>' + S.tokens + '</b> tokens</span>' +
      '<span class="muted small">' + esc(sa.statusLine) + '</span></div>' +
      (S.loadError ? '<p class="wr-msg">Could not load WordGuesser — please try again in a few minutes.</p>' : '') +
      '</div>' +
      '<div class="wr-play"><div class="wr-toast" id="wrToast" role="status"></div>' +
      boardHtml() + keyboardHtml() + coverHtml +
      '</div>' +
      '<div class="wr-actions">' + sa.actionBtn +
      '<button type="button" class="btn" id="wrStatsBtn">📊 Stats</button></div>' +
      '</div></div>';
    bindUi();
    var wasFlip = animRow >= 0;
    animRow = -1; // the flip belongs to THIS paint only
    if (wasFlip) {
      // Let the row finish flipping before anything else lands: the
      // repaint settles the keyboard colours, the end-of-game status and
      // buttons, and the win modal (930 ms of animation + margin).
      if (flipTimer) clearTimeout(flipTimer);
      flipTimer = setTimeout(function () { flipTimer = null; if (rootEl) paint(); }, 1000);
    } else if (pendingWin) { pendingWin = false; showWinModal(); }
    else if (pendingLose) { pendingLose = false; showLoseModal(); }
  }
  function bindUi() {
    if (!rootEl) return;
    var bk = rootEl.querySelector('#wrBackBtn');
    if (bk) bk.addEventListener('click', function () {
      if (typeof CPS !== 'undefined' && CPS.app) CPS.app.showView('arcade');
    });
    var nb = rootEl.querySelector('#wrNewBtn');
    if (nb) nb.addEventListener('click', startGame);
    var cv = rootEl.querySelector('#wrCoverBtn');
    if (cv) cv.addEventListener('click', startGame);
    var cb = rootEl.querySelector('#wrCopyBtn');
    if (cb) cb.addEventListener('click', copyResult);
    var sb = rootEl.querySelector('#wrStatsBtn');
    if (sb) sb.addEventListener('click', openStats);
    rootEl.querySelectorAll('[data-wr-key]').forEach(function (b) {
      b.addEventListener('click', function () { handleKey(b.getAttribute('data-wr-key')); });
    });
  }

  /* ---------------- lifecycle ------------------------------------------ */
  function render(el) {
    rootEl = el || rootEl;
    if (!listening) { document.addEventListener('keydown', onKeyDown); listening = true; }
    paint();
    if (!S.loaded && !S.busy) loadState();
  }
  function teardown() {
    if (flipTimer) { clearTimeout(flipTimer); flipTimer = null; }
    if (toastTimer) { clearTimeout(toastTimer); toastTimer = null; }
    if (listening) { document.removeEventListener('keydown', onKeyDown); listening = false; }
    rootEl = null;
  }

  CPS.wordle = {
    render: render,
    teardown: teardown,
    _test: {
      state: function () { return S; },
      paint: paint,
      shareText: shareText,
      handleKey: handleKey
    }
  };

  if (CPS.sandbox && CPS.sandbox.register) {
    CPS.sandbox.register({
      id: 'wordle', title: 'WordGuesser',
      blurb: 'The daily word game: guess the 5-letter word in 6 tries. One free game a day, ' +
             'extra games 10 tokens — win real packs and spin tickets.',
      status: 'public', noTab: true,
      render: function (el) { CPS.wordle.render(el); },
      teardown: function () { CPS.wordle.teardown(); }
    });
  }
})(window.CPS = window.CPS || {});

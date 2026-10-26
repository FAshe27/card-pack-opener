/* Word Rip — SANDBOX PROTOTYPE, FAKE TOKENS ONLY.
   Franklin's design (2026-10-26): a Wordle game for the Arcade — one FREE
   game daily, then 15 tokens a game; a unique word per player from a sizable
   answer bank; prizes by guesses used (his table, CONFIG.prizes below).

   PROTOTYPE RULES: no server, no RPCs, no real tokens, packs or tickets.
   The fake balance (starts at 100), the daily-free marker, any in-progress
   game and the session stats live in localStorage only (key
   wordle_proto_v1), exactly like the Plinko / Scratchoff / Vault Breaker
   Sandbox prototypes did before they graduated.

   THE WORD IN THIS PROTOTYPE: the answer sits in this module's memory,
   because a client-only prototype has nowhere else to put it. That is
   acceptable here — Sandbox is admin-only and nothing real is at stake —
   and it is NOT how the real build works. Graduation (separate build, on
   Franklin's word) moves dealing + scoring behind RPCs
   (wordle_start / wordle_guess / wordle_state): the answer lives only in
   a cps table, the client receives tile colours only, and the word banks
   below move server-side with it. The Dealer-shaped seam is marked where
   the swap lands. The word banks themselves (js/wordle-words.js, loaded
   lazily on first open) were screened with PackRipper's own profanity
   lists — see that file's header for counts and provenance.

   Registered into the Sandbox as status 'testing' — admin accounts only,
   NO Arcade tile (Franklin, 2026-10-26: not even a coming-soon box), no
   top-bar tab. All prices/prizes live in CONFIG at the top for tuning. */
(function (CPS) {
  'use strict';

  /* ================= CONFIG — tweak freely ================= */
  var CONFIG = {
    cost: 15,                // fake tokens per extra game (Franklin, 2026-10-26)
    startBalance: 100,       // fake balance a fresh / reset prototype holds
    // Prizes by guesses used — Franklin's table (2026-10-26), spelled out in
    // full wherever shown. pr = random packs, tickets = spin tickets. In the
    // prototype both are FAKE tallies on the stats panel; nothing is granted.
    prizes: {
      1: { pr: 10, tickets: 10 },
      2: { pr: 10, tickets: 5 },
      3: { pr: 5,  tickets: 5 },
      4: { pr: 0,  tickets: 5 },
      5: { pr: 5,  tickets: 0 },
      6: { pr: 3,  tickets: 0 }
    },
    openers: ['SLATE', 'CRANE', 'TRACE', 'SLANT', 'CRATE'] // simulate-bot openers
  };
  /* ===================================================================== */

  var LS_KEY = 'wordle_proto_v1';
  var WORDS_URL = 'js/wordle-words.js';

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function todayStr() {
    var d = new Date();
    function p(n) { return (n < 10 ? '0' : '') + n; }
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
  }
  function prizeText(p) {
    if (!p) return 'nothing';
    var parts = [];
    if (p.pr) parts.push(p.pr + ' random packs');
    if (p.tickets) parts.push(p.tickets + ' spin tickets');
    return parts.length ? parts.join(' + ') : 'nothing';
  }

  /* ---------------- word banks (lazy) ---------------- */
  var ANSWERS = null, ALLOWED = null; // arrays + Sets, filled by loadWords()
  var ANSWER_SET = null, ALLOWED_SET = null;
  function wordsReady() { return !!ANSWERS; }
  function loadWords() {
    if (CPS.wordleWords) { adoptWords(); return Promise.resolve(true); }
    return new Promise(function (resolve) {
      var s = document.createElement('script');
      s.src = WORDS_URL;
      s.onload = function () { adoptWords(); resolve(wordsReady()); };
      s.onerror = function () { resolve(false); };
      document.head.appendChild(s);
    });
  }
  function adoptWords() {
    if (!CPS.wordleWords || ANSWERS) return;
    ANSWERS = CPS.wordleWords.answers.split(' ');
    var allowed = CPS.wordleWords.allowed.split(' ');
    ANSWER_SET = new Set(ANSWERS);
    ALLOWED_SET = new Set(allowed);
    ALLOWED = allowed;
  }

  /* ---------------- scoring (the graduation RPC's algorithm) ----------------
     Two passes, exactly like Wordle: greens first (consuming those letters),
     then yellows left-to-right against the letters that remain. Returns an
     array of 5: 2 = green, 1 = yellow, 0 = gray. */
  function score(guess, answer) {
    var res = [0, 0, 0, 0, 0], rest = {}, i, ch;
    for (i = 0; i < 5; i++) {
      if (guess[i] === answer[i]) res[i] = 2;
      else rest[answer[i]] = (rest[answer[i]] || 0) + 1;
    }
    for (i = 0; i < 5; i++) {
      if (res[i] === 2) continue;
      ch = guess[i];
      if (rest[ch] > 0) { res[i] = 1; rest[ch]--; }
    }
    return res;
  }
  function patternKey(p) { return p.join(''); }

  /* ---------------- state ---------------- */
  function freshState() {
    return {
      balance: CONFIG.startBalance,
      freeDate: '',            // local date the free game was used ('' = unused today)
      active: null,            // {answer, guesses:[], patterns:[], status, free, input}
      nextAnswer: '',          // tuning override for the next deal
      lastAnswer: '',
      stats: {
        played: 0, won: 0, streak: 0, best: 0,
        dist: { 1: 0, 2: 0, 3: 0, 4: 0, 5: 0, 6: 0 },
        fakePacks: 0, fakeTickets: 0, tokensSpent: 0
      }
    };
  }
  var S = freshState();
  function load() {
    try {
      var raw = localStorage.getItem(LS_KEY);
      if (raw) { var p = JSON.parse(raw); if (p && typeof p.balance === 'number') S = Object.assign(freshState(), p); }
    } catch (e) { /* fresh state is fine */ }
  }
  function save() {
    try { localStorage.setItem(LS_KEY, JSON.stringify(S)); } catch (e) { /* ignore */ }
  }
  load();

  function freeAvailable() { return S.freeDate !== todayStr(); }

  /* ---------------- game flow ----------------
     DEALER SEAM: startGame/scoreGuess are the two places the graduation
     build replaces with RPC calls; everything else (board, keyboard,
     stats, prizes) is shared shape. */
  function startGame() {
    if (S.active && S.active.status === 'playing') { paint(); return; }
    var free = freeAvailable();
    if (!free && S.balance < CONFIG.cost) { msg('Not enough fake tokens — reset the prototype below, or come back tomorrow for the free game.'); return; }
    var answer;
    if (S.nextAnswer && ANSWER_SET && ANSWER_SET.has(S.nextAnswer)) answer = S.nextAnswer;
    else if (S.nextAnswer && ALLOWED_SET && ALLOWED_SET.has(S.nextAnswer)) answer = S.nextAnswer;
    else {
      answer = ANSWERS[Math.floor(Math.random() * ANSWERS.length)];
      if (ANSWERS.length > 1 && answer === S.lastAnswer) answer = ANSWERS[Math.floor(Math.random() * ANSWERS.length)];
    }
    S.nextAnswer = '';
    if (free) S.freeDate = todayStr();
    else { S.balance -= CONFIG.cost; S.stats.tokensSpent += CONFIG.cost; }
    S.active = { answer: answer, guesses: [], patterns: [], status: 'playing', free: free, input: '' };
    S.lastAnswer = answer;
    save(); animRow = -1; paint();
  }
  function submitGuess() {
    var g = S.active;
    if (!g || g.status !== 'playing') return;
    var w = (g.input || '').toUpperCase();
    if (w.length < 5) { nudge('Not enough letters'); return; }
    if (!ALLOWED_SET.has(w)) { nudge('Not in word list'); return; }
    var pat = score(w, g.answer); // DEALER SEAM: server scores at graduation
    g.guesses.push(w); g.patterns.push(pat); g.input = '';
    animRow = g.guesses.length - 1;
    if (patternKey(pat) === '22222') finishGame(true);
    else if (g.guesses.length >= 6) finishGame(false);
    save(); paint();
  }
  function finishGame(wonGame) {
    var g = S.active, st = S.stats;
    g.status = wonGame ? 'won' : 'lost';
    st.played++;
    if (wonGame) {
      var used = g.guesses.length, p = CONFIG.prizes[used];
      st.won++; st.dist[used]++; st.streak++; if (st.streak > st.best) st.best = st.streak;
      if (p) { st.fakePacks += p.pr; st.fakeTickets += p.tickets; }
      g.prize = p || null;
    } else { st.streak = 0; g.prize = null; }
  }
  function keyState() {
    // best-known state per letter: green > yellow > gray
    var best = {}, g = S.active;
    if (!g) return best;
    g.guesses.forEach(function (w, gi) {
      for (var i = 0; i < 5; i++) {
        var ch = w[i], v = g.patterns[gi][i];
        if (best[ch] === undefined || v > best[ch]) best[ch] = v;
      }
    });
    return best;
  }
  function shareText() {
    var g = S.active; if (!g) return '';
    var head = 'Word Rip ' + (g.status === 'won' ? g.guesses.length + '/6' : 'X/6');
    var rows = g.patterns.map(function (p) {
      return p.map(function (v) { return v === 2 ? '🟩' : (v === 1 ? '🟨' : '⬛'); }).join('');
    });
    return head + '\n' + rows.join('\n');
  }

  /* ---------------- simulate (tuning) ----------------
     A simple bot: fixed opener, then guesses a random word still consistent
     with every pattern so far. Shows the prize table's shape against
     solver-ish play; a human plays worse, a real solver plays better. */
  function simulate(n) {
    var dist = { 1: 0, 2: 0, 3: 0, 4: 0, 5: 0, 6: 0 }, fail = 0, packs = 0, tickets = 0, totalGuesses = 0;
    for (var game = 0; game < n; game++) {
      var answer = ANSWERS[Math.floor(Math.random() * ANSWERS.length)];
      var cands = ANSWERS, opener = CONFIG.openers[Math.floor(Math.random() * CONFIG.openers.length)];
      var used = 0, wonGame = false;
      for (var turn = 0; turn < 6; turn++) {
        var guess = turn === 0 ? opener : cands[Math.floor(Math.random() * cands.length)];
        var pat = score(guess, answer); used++;
        if (patternKey(pat) === '22222') { wonGame = true; break; }
        var key = patternKey(pat);
        cands = cands.filter(function (w) { return patternKey(score(guess, w)) === key; });
        if (!cands.length) break;
      }
      if (wonGame) { dist[used]++; var p = CONFIG.prizes[used]; packs += p.pr; tickets += p.tickets; totalGuesses += used; }
      else fail++;
    }
    return { n: n, dist: dist, fail: fail, packs: packs, tickets: tickets,
             avgWin: n - fail ? (totalGuesses / (n - fail)) : 0 };
  }

  /* ---------------- rendering ---------------- */
  var rootEl = null, animRow = -1, msgText = '', listening = false;
  function msg(t) { msgText = t; if (rootEl) paint(); }
  function nudge(t) {
    msgText = t;
    if (rootEl) {
      var m = rootEl.querySelector('.wr-msg'); if (m) m.textContent = t;
      var row = rootEl.querySelector('.wr-row.cur');
      if (row) { row.classList.remove('wr-shake'); void row.offsetWidth; row.classList.add('wr-shake'); }
    }
  }
  function tileCls(v) { return v === 2 ? 'wr-t-green' : (v === 1 ? 'wr-t-yellow' : 'wr-t-gray'); }

  function boardHtml() {
    var g = S.active, html = '<div class="wr-board">';
    for (var r = 0; r < 6; r++) {
      var isCur = !!g && g.status === 'playing' && r === g.guesses.length;
      var isAnim = g && r === animRow && r < g.guesses.length;
      html += '<div class="wr-row' + (isCur ? ' cur' : '') + '">';
      for (var c = 0; c < 5; c++) {
        var ch = '', cls = 'wr-tile';
        if (g && r < g.guesses.length) { ch = g.guesses[r][c]; cls += ' filled ' + tileCls(g.patterns[r][c]) + (isAnim ? ' flip' : ''); }
        else if (isCur && g.input && c < g.input.length) { ch = g.input[c]; cls += ' filled pop'; }
        html += '<div class="' + cls + '"' + (isAnim ? ' style="animation-delay:' + (c * 120) + 'ms"' : '') + '>' + esc(ch) + '</div>';
      }
      html += '</div>';
    }
    return html + '</div>';
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
  function statsHtml() {
    var st = S.stats;
    var winPct = st.played ? Math.round(100 * st.won / st.played) : 0;
    var maxD = 1; for (var k = 1; k <= 6; k++) maxD = Math.max(maxD, st.dist[k]);
    var bars = '';
    for (var i = 1; i <= 6; i++) {
      bars += '<div class="wr-dist-row"><span>' + i + '</span><div class="wr-dist-bar" style="width:' +
        Math.max(8, Math.round(100 * st.dist[i] / maxD)) + '%">' + st.dist[i] + '</div></div>';
    }
    return '<div class="panel wr-side"><h3>Prototype stats</h3>' +
      '<div class="wr-stat-grid">' +
      '<div><b>' + st.played + '</b><span>Played</span></div>' +
      '<div><b>' + winPct + '%</b><span>Win rate</span></div>' +
      '<div><b>' + st.streak + '</b><span>Streak</span></div>' +
      '<div><b>' + st.best + '</b><span>Best streak</span></div></div>' +
      '<h4>Guess distribution</h4>' + bars +
      '<p class="muted small">Fake prizes banked here: <b>' + st.fakePacks + ' random packs</b> + <b>' +
      st.fakeTickets + ' spin tickets</b> · fake tokens spent: ' + st.tokensSpent + '</p></div>';
  }
  function prizesHtml() {
    var rows = '';
    for (var i = 1; i <= 6; i++) rows += '<tr><td>' + i + (i === 1 ? ' guess' : ' guesses') + '</td><td>' + esc(prizeText(CONFIG.prizes[i])) + '</td></tr>';
    return '<details class="wr-details"><summary>Payouts</summary>' +
      '<p class="small muted">First game each day is free. Extra games cost ' + CONFIG.cost + ' tokens. ' +
      'Solve the word in 6 guesses or fewer:</p>' +
      '<table class="wr-table">' + rows + '</table></details>';
  }
  function paint() {
    if (!rootEl) return;
    var g = S.active;
    var statusLine, actionBtn;
    if (g && g.status === 'playing') {
      statusLine = g.free ? 'Free game in progress — good luck!' : 'Game in progress (' + CONFIG.cost + ' tokens paid).';
      actionBtn = '';
    } else if (g && g.status !== 'playing') {
      statusLine = g.status === 'won'
        ? '🎉 Solved in ' + g.guesses.length + (g.guesses.length === 1 ? ' guess' : ' guesses') + '! Prize: ' + prizeText(g.prize) + ' (fake, prototype).'
        : 'Out of guesses — the word was ' + g.answer + '.';
      actionBtn = '<button type="button" class="btn primary" id="wrNewBtn">' +
        (freeAvailable() ? 'Play free game' : 'New game — ' + CONFIG.cost + ' 🪙') + '</button>' +
        ' <button type="button" class="btn" id="wrCopyBtn">Copy result</button>';
    } else {
      statusLine = freeAvailable() ? 'Your free game for today is ready.' : 'Free game used today — extra games cost ' + CONFIG.cost + ' fake tokens.';
      actionBtn = '<button type="button" class="btn primary" id="wrNewBtn">' +
        (freeAvailable() ? 'Play free game' : 'Start game — ' + CONFIG.cost + ' 🪙') + '</button>';
    }
    rootEl.innerHTML =
      '<div class="panel wr-head"><h2>🔤 Word Rip <span class="wr-badge">SANDBOX PROTOTYPE</span></h2>' +
      '<p class="muted small">Guess the 5-letter word in 6 tries. Green = right letter, right spot · ' +
      'yellow = in the word, wrong spot · gray = not in the word. Fake tokens and fake prizes — nothing here is real.</p>' +
      '<div class="wr-topbar"><span class="wr-balance">🪙 <b>' + S.balance + '</b> fake tokens</span>' +
      '<span class="muted small">' + esc(statusLine) + '</span>' + actionBtn + '</div>' +
      '<p class="wr-msg">' + esc(msgText) + '</p></div>' +
      '<div class="wr-main"><div class="panel wr-game">' +
      (wordsReady() ? boardHtml() + keyboardHtml() : '<p class="muted">Loading word banks…</p>') +
      '</div>' + statsHtml() + '</div>' +
      '<div class="panel wr-tools">' + prizesHtml() +
      '<details class="wr-details"><summary>Tuning tools (prototype only — gone at graduation)</summary>' +
      '<div class="wr-tune-row"><label class="small">Force next word <input id="wrForce" type="text" maxlength="5" size="7" placeholder="e.g. PACKS"></label>' +
      '<button type="button" class="btn" id="wrForceBtn">Set next word</button>' +
      '<button type="button" class="btn" id="wrPeekBtn">Peek at answer</button>' +
      '<button type="button" class="btn" id="wrSimBtn">Simulate 1,000 bot games</button>' +
      '<button type="button" class="btn danger" id="wrResetBtn">Reset prototype</button></div>' +
      '<p class="small muted" id="wrTuneOut">Banks: ' + (wordsReady() ? ANSWERS.length + ' answers / ' + ALLOWED.length + ' allowed guesses. ' : 'loading… ') +
      'The bot plays a fixed opener then random consistent guesses — a floor for solver play, a ceiling for most humans.</p>' +
      '</details></div>';
    bindUi();
  }
  function bindUi() {
    var nb = rootEl.querySelector('#wrNewBtn');
    if (nb) nb.addEventListener('click', function () { msgText = ''; startGame(); });
    var cb = rootEl.querySelector('#wrCopyBtn');
    if (cb) cb.addEventListener('click', function () {
      var t = shareText(); if (!t) return;
      function done() { msg('Result copied — no spoilers in it, just the grid.'); }
      if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(t).then(done, done);
      else done();
    });
    rootEl.querySelectorAll('[data-wr-key]').forEach(function (b) {
      b.addEventListener('click', function () { handleKey(b.getAttribute('data-wr-key')); });
    });
    var fb = rootEl.querySelector('#wrForceBtn');
    if (fb) fb.addEventListener('click', function () {
      var v = (rootEl.querySelector('#wrForce').value || '').toUpperCase().trim();
      var out = rootEl.querySelector('#wrTuneOut');
      if (v.length === 5 && ALLOWED_SET && ALLOWED_SET.has(v)) { S.nextAnswer = v; save(); if (out) out.textContent = 'Next game\'s word set to ' + v + ' (prototype cheat — testing only).'; }
      else if (out) out.textContent = '"' + v + '" isn\'t in the word list.';
    });
    var pk = rootEl.querySelector('#wrPeekBtn');
    if (pk) pk.addEventListener('click', function () {
      var out = rootEl.querySelector('#wrTuneOut');
      if (out) out.textContent = S.active && S.active.status === 'playing' ? 'Current answer: ' + S.active.answer + ' (prototype only — the real build never sends this to the browser).' : 'No game in progress.';
    });
    var sm = rootEl.querySelector('#wrSimBtn');
    if (sm) sm.addEventListener('click', function () {
      var out = rootEl.querySelector('#wrTuneOut');
      if (out) out.textContent = 'Simulating…';
      setTimeout(function () {
        var r = simulate(1000), o2 = rootEl && rootEl.querySelector('#wrTuneOut'); if (!o2) return;
        var line = '';
        for (var i = 1; i <= 6; i++) line += i + ': ' + (100 * r.dist[i] / r.n).toFixed(1) + '%  ';
        o2.textContent = 'Bot over ' + r.n + ' games — ' + line + '· fail ' + (100 * r.fail / r.n).toFixed(1) +
          '% · avg win ' + r.avgWin.toFixed(2) + ' guesses · EV ' + (r.packs / r.n).toFixed(2) + ' packs + ' +
          (r.tickets / r.n).toFixed(2) + ' tickets per game.';
      }, 30);
    });
    var rs = rootEl.querySelector('#wrResetBtn');
    if (rs) rs.addEventListener('click', function () {
      try { localStorage.removeItem(LS_KEY); } catch (e) { /* ignore */ }
      S = freshState(); msgText = ''; animRow = -1; paint();
    });
  }
  function handleKey(k) {
    var g = S.active;
    if (!g || g.status !== 'playing' || !wordsReady()) return;
    if (k === 'ENTER') { submitGuess(); return; }
    if (k === 'BACK') { g.input = (g.input || '').slice(0, -1); }
    else if (/^[A-Z]$/.test(k) && (g.input || '').length < 5) g.input = (g.input || '') + k;
    else return;
    save(); paint();
  }
  function onKeyDown(e) {
    if (!rootEl || !rootEl.isConnected) return;
    var t = e.target;
    if (t && t.closest && t.closest('input, textarea, select')) return;
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    var k = e.key === 'Enter' ? 'ENTER' : (e.key === 'Backspace' ? 'BACK' : (e.key || '').toUpperCase());
    if (k === 'ENTER' || k === 'BACK' || /^[A-Z]$/.test(k)) { e.preventDefault(); handleKey(k); }
  }

  function render(el) {
    rootEl = el; msgText = ''; animRow = -1;
    if (!listening) { document.addEventListener('keydown', onKeyDown); listening = true; }
    if (wordsReady()) { paint(); return; }
    el.innerHTML = '<div class="panel"><p class="muted">Loading word banks…</p></div>';
    loadWords().then(function (ok) {
      if (!rootEl) return;
      if (ok) paint();
      else rootEl.innerHTML = '<div class="panel"><p class="muted">Could not load the word banks (js/wordle-words.js). Check the file is deployed.</p></div>';
    });
  }
  function teardown() {
    if (listening) { document.removeEventListener('keydown', onKeyDown); listening = false; }
    rootEl = null;
  }

  CPS.wordle = {
    render: render, teardown: teardown,
    _test: { CONFIG: CONFIG, score: score, prizeText: prizeText, simulate: simulate,
             state: function () { return S; }, wordsReady: wordsReady,
             adoptForTest: function (a, al) { ANSWERS = a; ALLOWED = al; ANSWER_SET = new Set(a); ALLOWED_SET = new Set(al); } }
  };

  function register() {
    if (CPS.sandbox && CPS.sandbox.register) {
      CPS.sandbox.register({
        id: 'wordle', title: 'Word Rip',
        blurb: 'Wordle for the Arcade — one free game daily, then 15 tokens; unique word per player, prizes by guesses used. Fake tokens here.',
        status: 'testing',
        render: function (el) { CPS.wordle.render(el); },
        teardown: function () { CPS.wordle.teardown(); }
      });
      return true;
    }
    return false;
  }
  if (!register() && typeof document !== 'undefined') {
    document.addEventListener('DOMContentLoaded', function () { register(); });
  }
})(window.CPS = window.CPS || {});

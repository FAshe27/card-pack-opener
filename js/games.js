/* Arcade — lobby + game pages (Franklin, 2026-10-14).
   Layout inspired by Torn's casino grid (token header strip, one big tile
   per game, click a tile to go to that game's page) skinned in PackRipper's
   own palette/type — not a Torn clone. Prize Wheel stays its own tab and is
   NOT part of this lobby.
   Structure: CPS.games.render() draws either the lobby or the currently
   open game page inside #gamesPanel, the same in-place swap the Sandbox
   uses for Launch test / Back. No app.js changes: the existing 'arcade'
   renderView branch calls render(), and setTokens/updateBadge are the only
   touchpoints other modules use.
   Higher/Lower is server-driven via cps_game_* RPCs; Slots mounts from
   CPS.slots (js/slots.js) on its own page. Scratchoffs graduated to its
   own public tab (2026-10-14) — its tile links there. Plinko is still
   testing in the Sandbox, so its tile is a greyed 'In testing' tile —
   admins can click through to the Sandbox, everyone else sees Coming soon. */
(function (CPS) {
  var ctx = CPS.appCtx;
  var G = null; // {run, card, streak, bank}
  var acting = false; // in-flight guard: double-taps can't double-spend or double-claim
  var page = 'lobby'; // 'lobby' | 'highlow' | 'slots'

  function el() { return ctx.$('#gamesPanel'); }

  function prizeName(p) {
    if (p.kind === 'pack') return '🎁 Pack';
    if (p.kind === 'ticket') return '🎟️ Spin ticket';
    if (p.kind === 'tokens') return '🪙 ' + (p.n || 1) + ' token' + ((p.n || 1) === 1 ? '' : 's');
    return '—';
  }

  function cardHTML(c) {
    return '<div class="numcard"><span>' + c.rank + '</span></div>';
  }

  function bankHTML(bank) {
    if (!bank || !bank.length) return '<span class="muted small">No prizes yet — win a round!</span>';
    return bank.map(function (p) { return '<span class="bank-prize">' + prizeName(p) + '</span>'; }).join('');
  }

  /* ---------------- shared header (Torn's info strip, our words) -------- */
  function headerHTML() {
    var tokens = ctx.S.gameTokens || 0;
    var html = '<div class="arc-head"><span class="arc-head-icon" aria-hidden="true">i</span>' +
      '<span class="arc-head-text">You have 🪙 <b><span id="gameTokens">' + tokens + '</span> token' +
      (tokens === 1 ? '' : 's') + '</b></span>';
    if (G && !G.over) html += '<span class="arc-head-streak">High / Low streak: <b>' + G.streak + '</b></span>';
    html += '</div>';
    return html;
  }

  function backHTML() {
    return '<div class="arc-backrow"><button class="btn ghost arc-back" id="arcBackBtn" type="button">← Back to Arcade</button></div>';
  }

  function bindBack(box) {
    var b = box.querySelector('#arcBackBtn');
    if (b) b.addEventListener('click', function () { page = 'lobby'; window.scrollTo(0, 0); render(); });
  }

  /* ---------------- lobby ---------------- */
  function artHTML(key) {
    if (key === 'slots') {
      return '<div class="arc-art-slots" aria-hidden="true">' +
        '<span class="arc-reel r-common">7</span><span class="arc-reel r-legendary">7</span><span class="arc-reel r-chase">7</span></div>';
    }
    if (key === 'highlow') {
      return '<div class="arc-art-highlow" aria-hidden="true">' +
        '<span class="arc-arrow up">▲</span><span class="arc-minicard">7</span><span class="arc-arrow down">▼</span></div>';
    }
    if (key === 'plinko') {
      return '<div class="arc-art-plinko" aria-hidden="true"><span class="arc-ball"></span>' +
        '<span class="arc-pegs"><i></i><i></i><i></i></span>' +
        '<span class="arc-pegs"><i></i><i></i><i></i><i></i></span>' +
        '<span class="arc-pegs"><i></i><i></i><i></i><i></i><i></i></span>' +
        '<span class="arc-bins"><i></i><i></i><i></i><i></i><i></i></span></div>';
    }
    // scratchoffs
    return '<div class="arc-art-scratch" aria-hidden="true"><div class="arc-ticket">' +
      '<span class="arc-foil"></span><span class="arc-foil"></span><span class="arc-foil"></span>' +
      '<span class="arc-foil"></span><span class="arc-foil"></span><span class="arc-foil"></span>' +
      '<span class="arc-foil"></span><span class="arc-foil"></span><span class="arc-foil"></span>' +
      '</div><span class="arc-coin">🪙</span></div>';
  }

  var TILES = [
    { id: 'highlow', title: 'HIGH / LOW', tag: '1 🪙 a run', accent: 'highlow',
      blurb: 'Guess whether the next card is higher or lower. Every round is win-or-bust — claim your prize bank any time.' },
    { id: 'slots', title: 'SLOTS', tag: '2 🪙 a spin', accent: 'slots',
      blurb: 'Match three rarity symbols to win packs. Legendary and Chase triples are announced to everyone!' },
    { id: 'plinko', title: 'PLINKO', tag: 'IN TESTING', accent: 'plinko', testing: true,
      blurb: 'Drop a chip down 8 rows of pegs — centre bins pay tokens, edge bins pay big packs.' },
    { id: 'scratchoffs', title: 'SCRATCHOFFS', tag: '2 🪙 a ticket', accent: 'scratch', view: 'sbx-scratchoffs',
      blurb: 'Buy a ticket in 3 tiers, scratch 9 foil spots, match 3 of a rarity to win packs.' }
  ];

  function renderLobby(box) {
    var admin = false;
    try { admin = !!ctx.isAdmin(); } catch (e) { /* local/guest: not admin */ }
    var tiles = TILES.map(function (t) {
      var cls = 'arc-tile arc-tile-' + t.accent + (t.testing ? ' is-testing' : '');
      var foot = t.testing
        ? (admin ? '<span class="arc-play">Open in Sandbox →</span>' : '<span class="arc-soon">Coming soon</span>')
        : '<span class="arc-play">Play →</span>';
      var attrs = t.testing
        ? (admin ? ' data-arc-sandbox="1"' : ' disabled aria-disabled="true"')
        : (t.view ? ' data-arc-view="' + t.view + '"' : ' data-arc-open="' + t.id + '"');
      return '<button type="button" class="' + cls + '"' + attrs + '>' +
        '<span class="arc-tile-head"><span class="arc-tile-title">' + t.title + '</span>' +
        '<span class="arc-tile-tag' + (t.testing ? ' testing' : '') + '">' + t.tag + '</span></span>' +
        '<span class="arc-tile-art">' + artHTML(t.id) + '</span>' +
        '<span class="arc-tile-foot"><span class="arc-tile-blurb">' + t.blurb + '</span>' + foot + '</span>' +
        '</button>';
    }).join('');
    box.innerHTML = headerHTML() +
      '<div class="arc-grid">' + tiles + '</div>';
    box.querySelectorAll('[data-arc-open]').forEach(function (b) {
      b.addEventListener('click', function () {
        page = b.getAttribute('data-arc-open');
        window.scrollTo(0, 0);
        render();
      });
    });
    box.querySelectorAll('[data-arc-sandbox]').forEach(function (b) {
      b.addEventListener('click', function () {
        if (typeof CPS !== 'undefined' && CPS.app) CPS.app.showView('sandbox');
      });
    });
    box.querySelectorAll('[data-arc-view]').forEach(function (b) {
      b.addEventListener('click', function () {
        if (typeof CPS !== 'undefined' && CPS.app) CPS.app.showView(b.getAttribute('data-arc-view'));
      });
    });
  }

  /* ---------------- High / Low page ---------------- */
  function renderHighLow(box) {
    var tokens = ctx.S.gameTokens || 0;
    var html = headerHTML() + backHTML();
    html += '<div class="panel"><h3>High / Low</h3>';
    if (!G) {
      html += '<p class="muted">Guess whether the next number is <b>higher</b> or <b>lower</b>. ' +
        'Every round is win-or-bust &mdash; one wrong guess loses the whole bank. Claim your prizes any time!</p>';
      html += '<button class="btn primary" id="gameStartBtn"' + (tokens > 0 ? '' : ' disabled') + '>New run (1 token)</button>';
      if (!(tokens > 0)) html += '<p class="muted small">Earn tokens from packs (5 on a token slip, ~1 in 10 packs).</p>';
    } else {
      html += '<div class="game-table">';
      html += '<div class="game-card">' + cardHTML(G.card) + '</div>';
      html += '<div class="game-streak">Streak: <b>' + G.streak + '</b></div>';
      if (!G.over) {
        var rk = G.card.rank;
        html += '<div class="row wrap"><button class="btn big" id="gameHigher"' + (rk >= 10 ? ' disabled' : '') + '>▲ Higher</button>' +
                '<button class="btn big" id="gameLower"' + (rk <= 1 ? ' disabled' : '') + '>▼ Lower</button></div>';
        html += '<button class="btn ghost" id="gameClaim"' + (G.bank && G.bank.length ? '' : ' disabled') + '>Claim prizes &amp; end run</button>';
      } else {
        html += '<div class="game-over">' + (G.busted ? '💥 Bust! The bank is gone.' : 'Prizes claimed!') + '</div>';
        html += '<button class="btn primary" id="gameAgain">Play again (1 token)</button>';
      }
      html += '<div class="prize-box"><b>Prize bank</b><div id="gameBank">' + bankHTML(G.bank) + '</div></div>';
      html += '<p class="muted small">Cards are numbered 1&ndash;10.</p>';
      html += '</div>';
    }
    html += '</div>';
    box.innerHTML = html;
    bindBack(box);
    bind();
  }

  /* ---------------- Slots page ---------------- */
  function renderSlots(box) {
    box.innerHTML = headerHTML() + backHTML() + '<div id="slotsMount"></div>';
    bindBack(box);
    if (CPS.slots) CPS.slots.mount(ctx.$('#slotsMount'));
  }

  function render() {
    var box = el(); if (!box) return;
    if (page === 'highlow') renderHighLow(box);
    else if (page === 'slots') renderSlots(box);
    else renderLobby(box);
    updateBadge();
  }

  function setTokens(n) {
    ctx.S.gameTokens = n;
    var t = ctx.$('#gameTokens'); if (t) t.textContent = n;
    updateBadge();
  }

  function updateBadge() {
    var b = ctx.$('#arcadeBadge'); if (!b) return;
    var n = ctx.S.gameTokens || 0;
    b.textContent = n;
    b.classList.toggle('hidden', !(n > 0));
  }

  function bind() {
    var b;
    b = ctx.$('#gameStartBtn'); if (b) b.addEventListener('click', start);
    b = ctx.$('#gameAgain'); if (b) b.addEventListener('click', start);
    b = ctx.$('#gameHigher'); if (b) b.addEventListener('click', function () { guess(true); });
    b = ctx.$('#gameLower'); if (b) b.addEventListener('click', function () { guess(false); });
    b = ctx.$('#gameClaim'); if (b) b.addEventListener('click', claim);
  }

  async function start() {
    if (acting) return;
    if (!ctx.isCloud()) { ctx.toast('Games need online play.', 'warn'); return; }
    acting = true;
    try {
      var r = await CPS.cloud.call('game_start', {});
      setTokens(r.tokens_left);
      G = { run: r.run, card: r.card, streak: 0, bank: [], over: false };
      ctx.audio.click();
      render();
    } catch (e) { ctx.cloudError(e); } finally { acting = false; }
  }

  async function guess(higher) {
    if (acting || !G || G.over) return;
    acting = true;
    var bh = ctx.$('#gameHigher'), bl = ctx.$('#gameLower');
    if (bh) bh.disabled = true; if (bl) bl.disabled = true;
    try {
      var r = await CPS.cloud.call('game_guess', { p_run: G.run, p_higher: higher });
      G.card = r.card; G.streak = r.streak || 0; G.bank = r.bank || G.bank;
      if (r.win) {
        ctx.audio.reveal('rare');
      } else if (r.bust) {
        G.over = true; G.busted = true; G.bank = [];
        ctx.audio.error();
      }
      render();
    } catch (e) { ctx.cloudError(e); } finally { acting = false; }
  }

  async function claim() {
    if (acting || !G || G.over) return;
    acting = true;
    try {
      var r = await CPS.cloud.call('game_claim', { p_run: G.run });
      var bits = [];
      if (r.packs) bits.push('🎁 ' + r.packs + ' pack' + (r.packs === 1 ? '' : 's'));
      if (r.tickets) bits.push('🎟️ ' + r.tickets + ' ticket' + (r.tickets === 1 ? '' : 's'));
      if (r.tokens) bits.push('🪙 ' + r.tokens + ' token' + (r.tokens === 1 ? '' : 's'));
      // sync live balances so no refresh is needed
      Object.keys(r.inventory || {}).forEach(function (sid) { ctx.ps({ id: sid }).packs = r.inventory[sid]; });
      if (typeof r.spins === 'number') ctx.S.spins = r.spins;
      if (typeof r.game_tokens === 'number') setTokens(r.game_tokens);
      ctx.toast(bits.length ? 'Claimed: ' + bits.join(', ') : 'No prizes banked.', bits.length ? 'good' : '');
      ctx.audio.reveal('epic');
      G = null;
      render();
      ctx.renderPacksSide();
      ctx.updateWheelBadge();
    } catch (e) { ctx.cloudError(e); } finally { acting = false; }
  }

  CPS.games = {
    render: render, refresh: render, setTokens: setTokens, updateBadge: updateBadge,
    open: function (p) { page = p || 'lobby'; render(); },
    lobby: function () { page = 'lobby'; render(); }
  };
})(window.CPS);

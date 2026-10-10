/* Higher/Lower game (admin-only beta). Server-driven via cps_game_* RPCs.
   Consumes CPS.appCtx (S, $, toast, audio, isAdmin, isCloud) and registers
   as CPS.games. The panel lives in the admin view for now; moving it to a
   public Games tab later is just a visibility change. */
(function (CPS) {
  var ctx = CPS.appCtx;
  var G = null; // {run, card, streak, bank}

  function el() { return ctx.$('#gamesPanel'); }

  function prizeName(p) {
    if (p.kind === 'pack') return p.guaranteed ? '🎁 Pack ★' : '🎁 Pack';
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

  function render() {
    var box = el(); if (!box) return;
    var tokens = ctx.S.gameTokens || 0;
    var html = '<div class="panel"><h2>Arcade</h2>' +
      '<div class="arcade-tokens">🪙 <b><span id="gameTokens">' + tokens + '</span> token' + (tokens === 1 ? '' : 's') + '</b></div></div>';
    html += '<div class="panel"><h3>High / Low</h3>';
    if (!G) {
      html += '<p class="muted">Guess whether the next number is <b>higher</b> or <b>lower</b>. ' +
        'Ties keep your streak alive, but one wrong guess busts the whole bank &mdash; claim your prizes any time! ' +
        'Streaks of 3, 5, 7&hellip; guarantee a bonus pack.</p>';
      html += '<button class="btn primary" id="gameStartBtn"' + (tokens > 0 ? '' : ' disabled') + '>New run (1 token)</button>';
      if (!(tokens > 0)) html += '<p class="muted small">Earn tokens from packs (5 on a token slip, ~1 in 10 packs).</p>';
    } else {
      html += '<div class="game-table">';
      html += '<div class="game-card">' + cardHTML(G.card) + '</div>';
      html += '<div class="game-streak">Streak: <b>' + G.streak + '</b></div>';
      if (!G.over) {
        var rk = G.card.rank;
        html += '<div class="row wrap"><button class="btn big" id="gameHigher"' + (rk >= 10 ? ' disabled' : '') + '>\u25b2 Higher</button>' +
                '<button class="btn big" id="gameLower"' + (rk <= 1 ? ' disabled' : '') + '>\u25bc Lower</button></div>';
        html += '<button class="btn ghost" id="gameClaim">Claim prizes &amp; end run</button>';
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
    updateBadge();
    bind();
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
    if (!ctx.isCloud()) { ctx.toast('Games need online play.', 'warn'); return; }
    try {
      var r = await CPS.cloud.call('game_start', {});
      setTokens(r.tokens_left);
      G = { run: r.run, card: r.card, streak: 0, bank: [], over: false };
      ctx.audio.click();
      render();
    } catch (e) { ctx.cloudError(e); }
  }

  async function guess(higher) {
    if (!G || G.over) return;
    try {
      var r = await CPS.cloud.call('game_guess', { p_run: G.run, p_higher: higher });
      G.card = r.card; G.streak = r.streak || 0; G.bank = r.bank || G.bank;
      if (r.tie) { ctx.toast('Tie — flip again, streak safe!', ''); }
      else if (r.win) {
        ctx.audio.reveal('rare');
        (r.prizes || []).forEach(function (pr) { ctx.toast('Won: ' + prizeName(pr), 'good'); });
      } else if (r.bust) {
        G.over = true; G.busted = true; G.bank = [];
        ctx.audio.error();
      }
      render();
    } catch (e) { ctx.cloudError(e); }
  }

  async function claim() {
    if (!G || G.over) return;
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
    } catch (e) { ctx.cloudError(e); }
  }

  CPS.games = { render: render, refresh: render, setTokens: setTokens, updateBadge: updateBadge };
})(window.CPS);

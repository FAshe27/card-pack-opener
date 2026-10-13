/* Slot machine arcade game (Franklin's spec, 2026-10-11).
   2 tokens per spin, server-authoritative reels (public.cps_slot_spin).
   Bet buttons: 1 / 5 / 10 spins, auto-spun sequentially.
   Triples pay packs only: common 0+3J / uncommon 3+3J / rare 5+5J /
   epic 10+10J / legendary 20+20J / chase 50+25J (random + Jumbled Mess).
   Global announcement on legendary/chase tiers (server-side).
   Consumes CPS.appCtx (S, $, esc, toast, isCloud, ...). Loads after js/app.js.
   Mount with CPS.slots.mount(el) from the Arcade view render (one line in
   js/games.js) or as a sandbox testing item. Registers as CPS.slots. */
(function (CPS) {
  var ctx = CPS.appCtx;
  var SPIN_COST = 2;
  var SYMBOLS = ['common', 'uncommon', 'rare', 'epic', 'legendary', 'chase'];
  var LABEL = {
    common: 'Common', uncommon: 'Uncommon', rare: 'Rare',
    epic: 'Epic', legendary: 'Legendary', chase: 'Chase'
  };
  var PAYTABLE = [
    ['common', '3 Jumbled Mess packs'],
    ['uncommon', '3 random packs + 3 Jumbled Mess'],
    ['rare', '5 random packs + 5 Jumbled Mess'],
    ['epic', '10 random packs + 10 Jumbled Mess'],
    ['legendary', '20 random packs + 20 Jumbled Mess'],
    ['chase', '50 random packs + 25 Jumbled Mess']
  ];
  var spinning = false;

  function symChip(sym) {
    return '<span class="slot-sym slot-sym-' + sym + '">' + LABEL[sym] + '</span>';
  }

  function prizeText(r) {
    var parts = [];
    if (r.packs_random > 0) parts.push(r.packs_random + ' random pack' + (r.packs_random === 1 ? '' : 's'));
    if (r.packs_jumbled > 0) parts.push(r.packs_jumbled + ' Jumbled Mess');
    return 'TRIPLE ' + LABEL[r.tier].toUpperCase() + '! +' + parts.join(' + ');
  }

  function mount(box) {
    if (!box) return;
    if (!ctx.isCloud()) {
      box.innerHTML = '<div class="panel"><h2>🎰 Slots</h2>' +
        '<p class="muted">Slots need online play — log in to spin.</p></div>';
      return;
    }
    var startBal = (ctx.S && ctx.S.gameTokens) || 0;
    var payRows = PAYTABLE.map(function (row) {
      return '<tr><td>' + symChip(row[0]) + ' × 3</td><td>' + row[1] + '</td></tr>';
    }).join('');
    box.innerHTML =
      '<div class="panel slot-machine">' +
        '<h2>🎰 Slots</h2>' +
        '<p class="muted small">Match three symbols to win packs — ' +
        'legendary and chase triples are announced to everyone!</p>' +
        '<div class="slot-balance" id="slotBalance"></div>' +
        '<div class="slot-reels">' +
          '<div class="slot-reel" id="slotReel0">' + symChip('common') + '</div>' +
          '<div class="slot-reel" id="slotReel1">' + symChip('uncommon') + '</div>' +
          '<div class="slot-reel" id="slotReel2">' + symChip('rare') + '</div>' +
        '</div>' +
        '<div class="slot-controls">' +
          '<button class="btn primary slot-bet" data-spins="1" data-cost="2">1 Spin — 2 🪙</button>' +
          '<button class="btn slot-bet" data-spins="5" data-cost="10">5 Spins — 10 🪙</button>' +
          '<button class="btn slot-bet" data-spins="10" data-cost="20">10 Spins — 20 🪙</button>' +
        '</div>' +
        '<div class="slot-result" id="slotResult"><span class="muted small">Pick a bet to play.</span></div>' +
        '<details class="slot-paytable"><summary>Paytable</summary><table>' + payRows + '</table></details>' +
      '</div>';
    var btns = box.querySelectorAll('.slot-bet');
    for (var i = 0; i < btns.length; i++) {
      btns[i].addEventListener('click', function (e) {
        spin(parseInt(e.currentTarget.getAttribute('data-spins'), 10));
      });
    }
    updateBalance(startBal);
  }

  /* Reel animation: cycle random symbols, staggered stops, land on server's.
     fast=true shortens it for multi-spin auto-play. */
  function animateReels(finalSyms, fast, done) {
    var reels = [0, 1, 2].map(function (i) { return ctx.$('#slotReel' + i); });
    var stopAt = fast ? [350, 550, 750] : [700, 1100, 1500];
    var start = Date.now();
    var timers = reels.map(function (reel, i) {
      return setInterval(function () {
        var t = Date.now() - start;
        if (t >= stopAt[i]) {
          clearInterval(timers[i]);
          if (reel) {
            reel.innerHTML = symChip(finalSyms[i]);
            reel.classList.remove('spinning');
          }
          if (i === 2) done();
        } else if (reel) {
          reel.innerHTML = symChip(SYMBOLS[(Math.random() * SYMBOLS.length) | 0]);
        }
      }, fast ? 70 : 90);
    });
    reels.forEach(function (reel) { if (reel) reel.classList.add('spinning'); });
  }

  function setBetButtons(disabled) {
    var btns = document.querySelectorAll('.slot-bet');
    for (var i = 0; i < btns.length; i++) btns[i].disabled = disabled;
  }

  /* Balance line + affordability: bet buttons you can't afford stay disabled,
     so you can't overspend. Also keeps the arcade/packs badges in sync. */
  function updateBalance(n) {
    var d = ctx.$('#slotBalance');
    if (d) d.innerHTML = '🪙 <b>' + n + ' token' + (n === 1 ? '' : 's') + '</b>';
    var btns = document.querySelectorAll('.slot-bet');
    for (var i = 0; i < btns.length; i++) {
      var cost = parseInt(btns[i].getAttribute('data-cost'), 10) || 0;
      if (!spinning) btns[i].disabled = n < cost;
    }
    try {
      if (CPS.games && CPS.games.setTokens) CPS.games.setTokens(n);
      if (CPS.packsBadge && CPS.packsBadge.update) CPS.packsBadge.update();
    } catch (e) { /* non-fatal */ }
  }

  /* Auto-spin n times, sequentially. Stops early if tokens run out. */
  async function spin(n) {
    var res = ctx.$('#slotResult');
    if (spinning || !res) return;
    spinning = true;
    setBetButtons(true);
    var fast = n > 1;
    var wins = [];
    var totRandom = 0, totJumbled = 0, done = 0, stoppedEarly = false;
    var tokNow = (ctx.S && ctx.S.gameTokens) || 0;

    for (var s = 0; s < n; s++) {
      res.innerHTML = '<span class="muted small">Spin ' + (s + 1) + ' of ' + n + '…</span>';
      var r;
      try {
        r = await CPS.cloud.call('slot_spin', {});
      } catch (e) {
        // most likely: out of tokens — stop the auto-run cleanly
        stoppedEarly = true;
        try { ctx.cloudError(e); } catch (e2) { /* keep the summary below */ }
        break;
      }
      done++;
      tokNow = r.tokens_now;
      updateBalance(tokNow);
      if (r.win) {
        // Sync local pack inventory from the server's grant list, the way
        // the wheel (packs_now) and Higher/Lower claim (inventory) already do.
        (r.grants || []).forEach(function (g) { var st = ctx.ps({ id: g.set_id }); if (st) st.packs = (st.packs || 0) + (g.packs || 0); });
        if (r.packs_jumbled > 0) { var jst = ctx.ps({ id: 'jumbled' }); if (jst) jst.packs = (jst.packs || 0) + r.packs_jumbled; }
        wins.push({ spin: s + 1, text: prizeText(r) });
        totRandom += r.packs_random;
        totJumbled += r.packs_jumbled;
      }
      await new Promise(function (ok) { animateReels(r.symbols, fast, ok); });
    }
    if (wins.length && ctx.renderPacksSide) ctx.renderPacksSide();

    var html;
    if (done === 0 && stoppedEarly) {
      html = '<span class="muted small">Not enough tokens — spin stopped.</span>';
    } else {
      html = wins.map(function (w) {
        return '<div class="slot-win">Spin ' + w.spin + ': ' + escHtml(w.text) + '</div>';
      }).join('');
      var summary = done + ' spin' + (done === 1 ? '' : 's') + ': ' + wins.length +
        ' win' + (wins.length === 1 ? '' : 's');
      if (wins.length) summary += ' (+' + totRandom + ' random, +' + totJumbled + ' Jumbled)';
      if (stoppedEarly) summary += ' — stopped early (out of tokens)';
      else if (!wins.length) summary += ' — no triples, spin again!';
      html += '<div class="slot-summary muted small">' + escHtml(summary) + '</div>';
      if (wins.length && ctx.toast) ctx.toast('🎰 ' + wins.length + ' win' + (wins.length === 1 ? '' : 's') + '!');
    }
    res.innerHTML = html || '<span class="muted small">Pick a bet to play.</span>';
    spinning = false;
    updateBalance(tokNow);
  }

  function escHtml(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  CPS.slots = { mount: mount, SPIN_COST: SPIN_COST };
})(window.CPS = window.CPS || {});

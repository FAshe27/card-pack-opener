/* js/turninrewards.js — Turn-In Rewards (migration 126).
   Prizes for turning in 25% / 50% / 75% of a set (Franklin's table:
   25% = 5 spin tickets + 5 Jumbled Mess packs; 50% = 10 tickets +
   5 Jumbled; 75% = 10 tickets + 10 packs of that set + 5 Jumbled).
   One time per player per set per threshold, turned-in only.
   NO claim button by design: after every state load this asks the
   server (cps_award_turnin_rewards) to pay anything owed — the server
   recounts turn-ins itself, dedupes via cps.turnin_rewards, and grants
   on the spot. The congrats pop-up below only announces what the
   server has ALREADY granted, so closing the app, missing the pop-up,
   or a second device can never lose or duplicate a prize: a passed-
   but-unpaid threshold stays owed and is paid on a later load.
   Backpay for thresholds passed before launch is handled entirely by
   migration 126's sweep + notifications; nothing here pops for it,
   because the award RPC finds those thresholds already paid.
   Failure is silent by design: if the RPC isn't live yet (126 not run)
   or a call fails, nothing pops and everything stays owed. */
(function (CPS) {
  'use strict';
  var ctx = CPS.appCtx;
  var running = false;
  var retryTimer = null;
  var seen = {}; /* session cache: setId:turnedCount -> already asked */

  function modalBusy() {
    var m = document.getElementById('modal');
    return !!(m && !m.classList.contains('hidden'));
  }

  function turnedCount(set) {
    var n = 0;
    set.cards.forEach(function (c) { if (ctx.isTurned(set.id, c.id)) n++; });
    return n;
  }

  function prizeText(paid, setName) {
    var t = 0, j = 0, p = 0;
    paid.forEach(function (r) { t += r.tickets || 0; j += r.jumbled || 0; p += r.set_packs || 0; });
    var parts = [];
    if (t) parts.push(t + ' spin tickets');
    if (j) parts.push(j + ' Jumbled Mess packs');
    if (p) parts.push(p + ' ' + setName + ' packs');
    if (parts.length === 2) return parts[0] + ' and ' + parts[1];
    if (parts.length === 3) return parts[0] + ', ' + parts[1] + ', and ' + parts[2];
    return parts.join(', ');
  }

  function showPopups(queue) {
    var item = queue.shift();
    if (!item) return;
    var top = 0;
    item.paid.forEach(function (r) { if (r.threshold > top) top = r.threshold; });
    ctx.fx.confetti(260);
    ctx.openModal('<button class="modal-x" data-close aria-label="Close">×</button>' +
      '<div style="text-align:center;padding:10px 6px 4px">' +
      '<div style="font-size:52px;line-height:1">🎁</div>' +
      '<h2>Turn-In Reward!</h2>' +
      '<p>You\'ve turned in <b>' + top + '%</b> of <b>' + ctx.esc(item.set.name) + '</b>!</p>' +
      '<p><b>' + ctx.esc(prizeText(item.paid, item.set.name)) + '</b> have been added to your account.</p>' +
      '<p class="muted">Rewards are one time per set — turn in more of the set for the next one!</p>' +
      '<div class="confirm-btns" style="justify-content:center"><button class="btn primary" data-close>Awesome!</button></div></div>');
    var box = document.getElementById('modalBox');
    if (box) box.querySelectorAll('[data-close]').forEach(function (b) {
      b.addEventListener('click', function () { ctx.closeModal(); if (queue.length) setTimeout(function () { showPopups(queue); }, 250); });
    });
  }

  async function check() {
    try {
      if (running) return;
      if (!ctx.isCloud() || !ctx.S.account || !ctx.S.turnedIn) return;
      if (ctx.S.opening) { /* mid pack-reveal: check again once it settles */
        if (!retryTimer) retryTimer = setTimeout(function () { retryTimer = null; check(); }, 3000);
        return;
      }
      /* Cheap local filter: only ask the server about sets that could
         have passed 25% (the server does the real counting). */
      var candidates = [];
      window.CardSets.all().forEach(function (set) {
        if (set.id === 'jumbled' || !set.cards.length) return;
        var n = turnedCount(set);
        if (n < Math.ceil(set.cards.length * 0.25)) return;
        var key = set.id + ':' + n;
        if (seen[key]) return;
        seen[key] = true;
        candidates.push(set);
      });
      if (!candidates.length) return;

      running = true;
      var queue = [];
      for (var i = 0; i < candidates.length; i++) {
        var set = candidates[i];
        try {
          var r = await CPS.cloud.call('award_turnin_rewards', { p_set: set.id });
          if (r && r.paid && r.paid.length) queue.push({ set: set, paid: r.paid });
        } catch (e) { /* not live yet / offline: stays owed, retried next load */ }
      }
      if (!queue.length) { running = false; return; }

      /* Prizes are already granted; refresh so spins + pack counts on
         screen match the account before the pop-up announces them.
         refreshCloud re-enters check() via milestones — the running
         flag makes that nested call a no-op. */
      try { await ctx.refreshCloud(); } catch (e) { /* pop-up still tells the truth */ }
      running = false;

      if (modalBusy()) { /* don't stomp an open dialog; prizes are already in */
        if (!retryTimer) retryTimer = setTimeout(function () { retryTimer = null; showPopups(queue); }, 4000);
        return;
      }
      showPopups(queue);
    } catch (e) { running = false; /* rewards must never break the app */ }
  }

  CPS.turninRewards = { check: check };
})(window.CPS);

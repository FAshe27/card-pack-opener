/* Daily Achievements: Claim All button.
   Adds a "Claim all (N)" button when 2+ quests are claimable.
   Registers as CPS.daily. */
(function (CPS) {
  var claiming = false;
  function getClaimable() {
    var C = window.CPS && CPS.appCtx;
    if (!C || !C.S) return [];
    return (C.S.quests || []).filter(function (q) { return q.done && !q.claimed; });
  }

  async function claimAll() {
    if (claiming) return;
    claiming = true;
    var btn = document.getElementById('claimAllBtn');
    if (btn) { btn.disabled = true; btn.textContent = 'Claiming...'; }
    var claimable = getClaimable();
    var total = 0, totalTokens = 0, totalCredit = 0, count = 0, failed = 0, lastSpins = null;
    var perfect = null;
    var C = window.CPS && CPS.appCtx;
    for (var i = 0; i < claimable.length; i++) {
      try {
        var r = await CPS.cloud.call('claim_quest', { p_key: claimable[i].key });
        total += r.tickets || 0;
        totalTokens += r.tokens || 0;
        totalCredit += r.credit || 0;
        if (r.spins_now != null) lastSpins = r.spins_now;
        if (r.perfect_day) perfect = r.perfect_day;
        count++;
      } catch (e) { failed++; }
    }
    // Sync the header wheel badge + local spins (single-claim path does this;
    // Claim All previously left both stale until a full reload).
    if (lastSpins != null && C && C.S) {
      C.S.spins = lastSpins;
      if (C.S.player) C.S.player.spins = lastSpins;
      if (C.updateWheelBadge) C.updateWheelBadge();
    }
    if (C && C.toast) {
      if (count > 0) {
        var parts = [];
        if (total) parts.push(total + ' ticket' + (total === 1 ? '' : 's'));
        if (totalTokens) parts.push(totalTokens + ' token' + (totalTokens === 1 ? '' : 's'));
        if (totalCredit) parts.push('$' + totalCredit + ' Store Credit');
        C.toast('Claimed ' + count + ' quest' + (count === 1 ? '' : 's') + (parts.length ? ' for ' + parts.join(' + ') : '') + '!', 'good');
      } else if (claimable.length) {
        C.toast("Couldn't claim any quests — please try again.", 'warn');
      }
      if (failed > 0 && count > 0) C.toast(failed + ' quest claim' + (failed === 1 ? '' : 's') + ' failed — try again shortly.', 'warn');
    }
    if (count > 0 && C && C.audio) C.audio.coin();
    // Re-render the current view (renderDaily isn't exposed, but renderView is).
    // renderView -> renderDaily -> refreshQuests, so no explicit refresh needed.
    if (C && C.renderView) C.renderView();
    if (perfect) perfectDay(perfect);
    claiming = false;
    updateBtn();
  }

  /* Perfect Day celebration (migration 201): cps_claim_quest reports
     perfect_day on the claim that leaves the whole board claimed; the
     5-ticket bonus is already in the player's spins by then, so this
     is purely the party. */
  function perfectDay(pd) {
    var C = window.CPS && CPS.appCtx;
    if (!C || !C.openModal || !pd) return;
    if (C.fx && C.fx.confetti) C.fx.confetti(240);
    if (C.audio && C.audio.coin) C.audio.coin();
    var total = pd.total_days || 1;
    var line = total > 1
      ? 'That makes ' + total + ' Perfect Days in your Trophy Case.'
      : 'A Perfect Day trophy just landed in your Trophy Case.';
    C.openModal('<button class="modal-x" data-close aria-label="Close">×</button>' +
      '<h2 style="text-align:center">🎉 Perfect Day! 🎉</h2>' +
      '<p style="text-align:center">You completed <b>all ' + (pd.quests || 30) + ' daily quests</b> today!</p>' +
      '<p style="text-align:center">Bonus: <b>5 spin tickets</b></p>' +
      '<p style="text-align:center">' + line + '</p>' +
      '<div class="modal-actions" style="display:flex;justify-content:center"><button class="btn primary" data-close>Awesome!</button></div>');
    var box = document.getElementById('modalBox');
    if (box && C.closeModal) {
      box.querySelectorAll('[data-close]').forEach(function (b) {
        b.addEventListener('click', function () { C.closeModal(); });
      });
    }
  }

  function updateBtn() {
    var btn = document.getElementById('claimAllBtn');
    if (!btn || claiming) return;
    var claimable = getClaimable();
    if (claimable.length > 1) {
      btn.classList.remove('hidden');
      btn.disabled = false;
      btn.textContent = 'Claim all (' + claimable.length + ')';
    } else {
      btn.classList.add('hidden');
    }
  }

  function init() {
    var btn = document.getElementById('claimAllBtn');
    if (btn) btn.addEventListener('click', claimAll);
    // Watch for quest list changes
    var list = document.getElementById('questList');
    if (list) {
      new MutationObserver(updateBtn).observe(list, { childList: true, subtree: true });
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

  CPS.daily = { claimAll: claimAll, updateBtn: updateBtn, perfectDay: perfectDay };
})(window.CPS = window.CPS || {});

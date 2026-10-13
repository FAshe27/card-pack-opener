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
    var total = 0, totalTokens = 0, count = 0, lastSpins = null;
    var C = window.CPS && CPS.appCtx;
    for (var i = 0; i < claimable.length; i++) {
      try {
        var r = await CPS.cloud.call('claim_quest', { p_key: claimable[i].key });
        total += r.tickets || 0;
        totalTokens += r.tokens || 0;
        if (r.spins_now != null) lastSpins = r.spins_now;
        count++;
      } catch (e) { /* skip */ }
    }
    // Sync the header wheel badge + local spins (single-claim path does this;
    // Claim All previously left both stale until a full reload).
    if (lastSpins != null && C && C.S) {
      C.S.spins = lastSpins;
      if (C.S.player) C.S.player.spins = lastSpins;
      if (C.updateWheelBadge) C.updateWheelBadge();
    }
    if (C && C.toast) {
      var parts = [];
      if (total) parts.push(total + ' ticket' + (total === 1 ? '' : 's'));
      if (totalTokens) parts.push(totalTokens + ' token' + (totalTokens === 1 ? '' : 's'));
      C.toast('Claimed ' + count + ' quest' + (count === 1 ? '' : 's') + (parts.length ? ' for ' + parts.join(' + ') : '') + '!', 'good');
    }
    if (C && C.audio) C.audio.coin();
    // Re-render the current view (renderDaily isn't exposed, but renderView is).
    // renderView -> renderDaily -> refreshQuests, so no explicit refresh needed.
    if (C && C.renderView) C.renderView();
    claiming = false;
    updateBtn();
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
    // Also check periodically (quests load async)
    setInterval(updateBtn, 2000);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

  CPS.daily = { claimAll: claimAll, updateBtn: updateBtn };
})(window.CPS = window.CPS || {});

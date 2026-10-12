/* Daily Achievements: Claim All button.
   Adds a "Claim all (N)" button when 2+ quests are claimable.
   Registers as CPS.daily. */
(function (CPS) {
  function getClaimable() {
    var C = window.CPS && CPS.appCtx;
    if (!C || !C.S) return [];
    return (C.S.quests || []).filter(function (q) { return q.done && !q.claimed; });
  }

  async function claimAll() {
    var btn = document.getElementById('claimAllBtn');
    if (btn) { btn.disabled = true; btn.textContent = 'Claiming...'; }
    var claimable = getClaimable();
    var total = 0, count = 0;
    var C = window.CPS && CPS.appCtx;
    for (var i = 0; i < claimable.length; i++) {
      try {
        var r = await CPS.cloud.call('claim_quest', { p_key: claimable[i].key });
        total += r.tickets || 0;
        count++;
      } catch (e) { /* skip */ }
    }
    if (C && C.toast) C.toast('Claimed ' + count + ' quest' + (count === 1 ? '' : 's') + ' for ' + total + ' ticket' + (total === 1 ? '' : 's') + '!', 'good');
    if (C && C.audio) C.audio.coin();
    // Refresh quests via appCtx
    if (C && C.refreshQuests) {
      await C.refreshQuests();
      // Trigger re-render by dispatching a custom event app.js listens for, or reload view
      if (C.S && C.S.view === 'daily' && C.renderDaily) C.renderDaily();
    }
    updateBtn();
  }

  function updateBtn() {
    var btn = document.getElementById('claimAllBtn');
    if (!btn) return;
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

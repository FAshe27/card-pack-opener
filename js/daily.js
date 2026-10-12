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
    // Patch single-claim toast to handle token rewards
    // (app.js shows "+N spin tickets" — we intercept via MutationObserver on toast container)
    patchSingleClaim();
    // Watch for quest list changes
    var list = document.getElementById('questList');
    if (list) {
      new MutationObserver(updateBtn).observe(list, { childList: true, subtree: true });
    }
    // Also check periodically (quests load async)
    setInterval(updateBtn, 2000);
  }

  /* The server now returns currency/amount. app.js still does
     toast('+' + r.tickets + ' spin ticket...'). For token quests r.tickets=0.
     We watch for the toast and correct it if the last claim was tokens. */
  var lastClaimWasTokens = false;
  var lastTokenAmount = 0;
  function patchSingleClaim() {
    // Intercept CPS.cloud.call for claim_quest to capture the currency
    if (!CPS.cloud || !CPS.cloud.call || CPS.cloud.call._patched) return;
    var orig = CPS.cloud.call;
    var patched = async function (name, args) {
      var r = await orig(name, args);
      if (name === 'claim_quest' && r) {
        if (r.currency === 'token') {
          lastClaimWasTokens = true;
          lastTokenAmount = r.tokens || r.amount || 0;
          // The toast was already shown by app.js; show a correction
          var C = window.CPS && CPS.appCtx;
          if (C && C.toast) {
            setTimeout(function() {
              C.toast('+' + lastTokenAmount + ' arcade token' + (lastTokenAmount === 1 ? '' : 's') + '!', 'good');
            }, 100);
          }
        }
      }
      return r;
    };
    patched._patched = true;
    CPS.cloud.call = patched;
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

  CPS.daily = { claimAll: claimAll, updateBtn: updateBtn };
})(window.CPS = window.CPS || {});

/* Admin grants via the "Grant X to:" panels (everyone or a specific
   account). Consumes CPS.appCtx and registers as CPS.admintokens.
   (The old per-account-row grant buttons were removed in the Oct 2026
   admin reorganization — the dropdown panels replaced them.) */
(function (CPS) {
  var ctx = CPS.appCtx;

  function bindAll() {
    var btn = ctx.$('#gaTokenAllBtn');
    if (!btn || btn.dataset.bound) return;
    btn.dataset.bound = '1';
    btn.addEventListener('click', async function () {
      var n = parseInt(ctx.$('#gaTokenAllN').value, 10);
      var whoSel = ctx.$('#grantTokensWho');
      var who = whoSel ? whoSel.value : 'everyone';
      if (!(n >= 1)) { ctx.toast('Pick a number of game tokens.', 'warn'); return; }
      var whoName = who === 'everyone' ? 'every non-admin player' : (whoSel.selectedOptions[0].textContent || 'player');
      if (!confirm('Give ' + n + ' game token' + (n === 1 ? '' : 's') + ' to ' + whoName + '?')) return;
      btn.disabled = true;
      try {
        var r;
        if (who === 'everyone') {
          r = await CPS.cloud.call('admin_grant_tokens_all', { p_tokens: n });
          ctx.toast('Gave ' + n + ' game token' + (n === 1 ? '' : 's') + ' to ' + r.players + ' player' + (r.players === 1 ? '' : 's') + '.', 'good');
        } else {
          r = await CPS.cloud.call('admin_grant_tokens', { p_account: who, p_tokens: n });
          ctx.toast('Gave ' + n + ' game token' + (n === 1 ? '' : 's') + ' to ' + whoName + '.', 'good');
        }
        ctx.renderAdmin();
      } catch (e) { ctx.cloudError(e); }
      btn.disabled = false;
    });
  }

  function bindCreditAll() {
    var btn = ctx.$('#gaCreditAllBtn');
    if (!btn || btn.dataset.bound) return;
    btn.dataset.bound = '1';
    btn.addEventListener('click', async function () {
      var n = parseInt(ctx.$('#gaCreditAllN').value, 10);
      var whoSel = ctx.$('#grantCreditWho');
      var who = whoSel ? whoSel.value : 'everyone';
      if (!(n >= 1)) { ctx.toast('Pick an amount of Store Credit.', 'warn'); return; }
      var whoName = who === 'everyone' ? 'every non-admin player' : (whoSel.selectedOptions[0].textContent || 'player');
      if (!confirm('Give $' + n + ' Store Credit to ' + whoName + '?')) return;
      btn.disabled = true;
      try {
        var r;
        if (who === 'everyone') {
          r = await CPS.cloud.call('admin_grant_credit_all', { p_credit: n });
          ctx.toast('Gave $' + n + ' Store Credit to ' + r.players + ' player' + (r.players === 1 ? '' : 's') + '.', 'good');
        } else {
          r = await CPS.cloud.call('admin_grant_credit', { p_account: who, p_credit: n });
          ctx.toast('Gave $' + n + ' Store Credit to ' + whoName + '.', 'good');
        }
        ctx.renderAdmin();
      } catch (e) { ctx.cloudError(e); }
      btn.disabled = false;
    });
  }

  function bindNotify() {
    var btn = ctx.$('#notifyBtn');
    if (!btn || btn.dataset.bound) return;
    btn.dataset.bound = '1';
    btn.addEventListener('click', async function () {
      var whoSel = ctx.$('#notifyWho');
      var who = whoSel ? whoSel.value : 'everyone';
      var text = ctx.$('#notifyText').value.trim();
      if (!text) { ctx.toast('Type a message first.', 'warn'); return; }
      var whoName = who === 'everyone' ? 'every non-admin player' : (whoSel.selectedOptions[0].textContent || 'player');
      if (!confirm('Send this notification to ' + whoName + '?\n\n"' + text + '"')) return;
      btn.disabled = true;
      try {
        var r;
        if (who === 'everyone') {
          r = await CPS.cloud.call('admin_notify_all', { p_text: text });
          ctx.toast('Notification sent to ' + r.players + ' player' + (r.players === 1 ? '' : 's') + '.', 'good');
        } else {
          r = await CPS.cloud.call('admin_notify', { p_account: who, p_text: text });
          ctx.toast('Notification sent to ' + whoName + '.', 'good');
        }
        ctx.$('#notifyText').value = '';
      } catch (e) { ctx.cloudError(e); }
      btn.disabled = false;
    });
  }

  CPS.admintokens = { bindAll: bindAll, bindCreditAll: bindCreditAll, bindNotify: bindNotify };
})(window.CPS);

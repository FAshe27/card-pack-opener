/* Admin game-token grants. Consumes CPS.appCtx (S, $, toast, cloudError,
   renderAdmin, games) and registers as CPS.admintokens. */
(function (CPS) {
  var ctx = CPS.appCtx;

  function rowHTML(setOpts) {
    return '<div class="acct-actions row wrap"><select class="ga-set">' + setOpts + '</select>' +
      '<input class="ga-n" type="number" value="3" min="-99" max="999" aria-label="Packs">' +
      '<button class="btn small" data-act="grant">Give packs</button>' +
      '<input class="ga-sp" type="number" value="1" min="-99" max="999" aria-label="Spins">' +
      '<button class="btn small" data-act="grantspins">Give spins</button>' +
      '<input class="ga-tk" type="number" value="3" min="-99" max="999" aria-label="Tokens">' +
      '<button class="btn small" data-act="granttokens">Give tokens</button>' +
      '<input class="ga-cr" type="number" value="5" min="-99" max="999" aria-label="Store Credit">' +
      '<button class="btn small" data-act="grantcredit">Give credit</button>';
  }

  async function grantCredit(row, id, name) {
    var cn = parseInt(ctx.$('.ga-cr', row).value, 10);
    if (!cn) { ctx.toast('Enter an amount of Store Credit.', 'warn'); return; }
    try {
      var r = await CPS.cloud.call('admin_grant_credit', { p_account: id, p_credit: cn });
      ctx.toast((cn > 0 ? 'Gave $' : 'Removed $') + Math.abs(cn) + ' Store Credit' + (cn > 0 ? ' to ' : ' from ') + name + ' (now $' + r.credit_now + ').', 'good');
      ctx.renderAdmin();
    } catch (e) { ctx.cloudError(e); }
  }

  async function grant(row, id, name) {
    var tn = parseInt(ctx.$('.ga-tk', row).value, 10);
    if (!tn) { ctx.toast('Enter a number of tokens.', 'warn'); return; }
    try {
      var r = await CPS.cloud.call('admin_grant_tokens', { p_account: id, p_tokens: tn });
      ctx.toast((tn > 0 ? 'Gave ' : 'Removed ') + Math.abs(tn) + ' token' + (Math.abs(tn) === 1 ? '' : 's') + (tn > 0 ? ' to ' : ' from ') + name + ' (now ' + r.tokens_now + ').', 'good');
      if (id === ctx.S.account.id && CPS.games) {
        CPS.games.setTokens(r.tokens_now);
        CPS.games.render();
      }
      ctx.renderAdmin();
    } catch (e) { ctx.cloudError(e); }
  }

  function bindAll() {
    var btn = ctx.$('#gaTokenAllBtn');
    if (!btn || btn.dataset.bound) return;
    btn.dataset.bound = '1';
    btn.addEventListener('click', async function () {
      var n = parseInt(ctx.$('#gaTokenAllN').value, 10);
      if (!(n >= 1)) { ctx.toast('Pick a number of game tokens.', 'warn'); return; }
      if (!confirm('Give ' + n + ' game token' + (n === 1 ? '' : 's') + ' to every non-admin player?')) return;
      btn.disabled = true;
      try {
        var r = await CPS.cloud.call('admin_grant_tokens_all', { p_tokens: n });
        ctx.toast('Gave ' + n + ' game token' + (n === 1 ? '' : 's') + ' to ' + r.players + ' player' + (r.players === 1 ? '' : 's') + '.', 'good');
        ctx.renderAdmin();
      } catch (e) { ctx.cloudError(e); btn.disabled = false; }
    });
  }

  function bindCreditAll() {
    var btn = ctx.$('#gaCreditAllBtn');
    if (!btn || btn.dataset.bound) return;
    btn.dataset.bound = '1';
    btn.addEventListener('click', async function () {
      var n = parseInt(ctx.$('#gaCreditAllN').value, 10);
      if (!(n >= 1)) { ctx.toast('Pick an amount of Store Credit.', 'warn'); return; }
      if (!confirm('Give $' + n + ' Store Credit to every non-admin player?')) return;
      btn.disabled = true;
      try {
        var r = await CPS.cloud.call('admin_grant_credit_all', { p_credit: n });
        ctx.toast('Gave $' + n + ' Store Credit to ' + r.players + ' player' + (r.players === 1 ? '' : 's') + '.', 'good');
        ctx.renderAdmin();
      } catch (e) { ctx.cloudError(e); btn.disabled = false; }
    });
  }

  CPS.admintokens = { rowHTML: rowHTML, grant: grant, grantCredit: grantCredit, bindAll: bindAll, bindCreditAll: bindCreditAll };
  // rowHTML(setOpts) renders the full grant-buttons block for an account row.
})(window.CPS);

/* Support / donate page — client module.
   Split out so js/app.js stays under the push size limit.
   Consumes the shared context exposed as CPS.appCtx (grabbed at load, like
   js/cotd.js — this file loads after js/app.js). Registers as CPS.donate.

   The #donate view is UNLINKED: no tab, menu item, or button anywhere on
   the site points to it. It is reachable only by visiting /#donate directly.

   LIVE (staged 2026-10-27): Chip in opens Franklin's Stripe
   "Customers choose what to pay" Payment Link in a new tab, with
   ?prefilled_amount=<cents> appended, so the amount picked here arrives
   pre-filled on Stripe's page (the payer can still edit it there) and the
   PackRipper tab stays open. That link type does not support
   recurring payments, which keeps the page's one-time-only promise.
   A prefilled_amount outside the link's configured min/max is disregarded
   by Stripe, which falls back to the link's own preset — safe by design.

   The funding bar is live too (migration 206): Stripe webhooks record
   each paid donation in the private cps.donations ledger via the
   stripe-donations Edge Function, and this module reads the month's
   aggregate from the public cps_donation_progress RPC. Gross amounts
   count (refunds subtract; Stripe fees don't), the display caps at
   the $58 goal, the month window is America/Chicago and resets on
   its own each month, and at the goal the bar turns gold and shows
   "Fully Funded for <Month>!". On bind, the module also pokes the
   function's reconcile endpoint (fire-and-forget; the server throttles
   it) so a missed webhook self-heals. */
(function (CPS) {
  'use strict';

  var C = CPS.appCtx || null;
  var amount = 5; // the $5 chip is preselected in index.html

  function fmt(n) { return '$' + n; }

  function render() {
    var sum = document.getElementById('dnSummary');
    if (sum) sum.textContent = fmt(amount) + ', one-time.';
  }

  var STRIPE_LINK = 'https://donate.stripe.com/eVqcMX0XL4Jx34a4ha3gk01';

  function goStripe() {
    var url = STRIPE_LINK + '?prefilled_amount=' + (amount * 100);
    var opened = window.open(url, '_blank');
    if (opened) opened.opener = null;
    else window.location.href = url; // popup blocked: preserve the old behaviour
  }

  // ------------------------------------------------ funding bar (206)
  var progressPainted = false;

  function money(cents) {
    var d = (Number(cents) || 0) / 100;
    return '$' + (d % 1 === 0 ? String(d) : d.toFixed(2));
  }

  function paintProgress(p) {
    var fill = document.getElementById('dnBarFill');
    var bar = document.getElementById('dnBar');
    var text = document.getElementById('dnProgressText');
    var funded = document.getElementById('dnFunded');
    if (!fill || !text || !p) return;
    var goal = Number(p.goal_cents) || 5800;
    var shown = Math.min(Number(p.display_cents) || 0, goal);
    fill.style.width = (goal > 0 ? (shown / goal) * 100 : 0) + '%';
    text.textContent = money(shown) + ' of ' + money(goal) + ' toward ' +
      (p.month_name || 'this month') + "'s costs.";
    if (bar) bar.classList.toggle('funded', !!p.fully_funded);
    if (funded) {
      funded.hidden = !p.fully_funded;
      funded.textContent = p.fully_funded
        ? 'Fully Funded for ' + (p.month_name || 'this month') + '!' : '';
    }
    progressPainted = true;
  }

  function donateVisible() {
    var view = document.getElementById('view-donate');
    return !!view && view.offsetParent !== null;
  }

  function refreshProgress() {
    if (!(CPS.cloud && CPS.cloud.rpc)) return;
    CPS.cloud.rpc('cps_donation_progress', {}).then(function (p) {
      if (p && p.ok) paintProgress(p);
    }).catch(function () {
      var text = document.getElementById('dnProgressText');
      if (text && !progressPainted) {
        text.textContent = "This month's total is unavailable right now.";
      }
    });
  }

  function pokeReconcile() {
    try {
      var cfg = (CPS.cloud && CPS.cloud.config) || window.CPS_CONFIG || {};
      if (!cfg.supabaseUrl || !window.fetch) return;
      window.fetch(
        cfg.supabaseUrl.replace(/\/+$/, '') +
          '/functions/v1/stripe-donations?reconcile=1',
        { headers: cfg.supabaseKey ? { apikey: cfg.supabaseKey } : {} }
      ).catch(function () {});
    } catch (e) { /* best-effort only */ }
  }

  function bind() {
    var view = document.getElementById('view-donate');
    if (!view || view.dataset.bound) return;
    view.dataset.bound = '1';

    var chips = view.querySelectorAll('.dn-amt');
    var custom = document.getElementById('dnCustom');

    chips.forEach(function (chip) {
      chip.addEventListener('click', function () {
        chips.forEach(function (c) { c.classList.remove('on'); });
        chip.classList.add('on');
        if (custom) custom.value = '';
        amount = parseInt(chip.dataset.amt, 10) || 0;
        render();
        if (C && C.audio) C.audio.click();
      });
    });

    if (custom) custom.addEventListener('input', function () {
      var v = parseInt(custom.value, 10);
      if (v > 0) {
        chips.forEach(function (c) { c.classList.remove('on'); });
        amount = v;
      } else {
        var on = view.querySelector('.dn-amt.on') || view.querySelector('[data-amt="5"]');
        chips.forEach(function (c) { c.classList.toggle('on', c === on); });
        amount = on ? (parseInt(on.dataset.amt, 10) || 5) : 5;
      }
      render();
    });

    var go = document.getElementById('dnGo');
    if (go) go.addEventListener('click', goStripe);
    render();

    // Funding bar: load now, keep it fresh while the page sits open,
    // and refresh when the player comes back from the Stripe tab.
    refreshProgress();
    pokeReconcile();
    window.setInterval(function () { if (donateVisible()) refreshProgress(); }, 60000);
    document.addEventListener('visibilitychange', function () {
      if (!document.hidden && donateVisible()) refreshProgress();
    });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', bind);
  else bind();

  CPS.donate = { bind: bind };
})(window.CPS);

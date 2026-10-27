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
   by Stripe, which falls back to the link's own preset — safe by design. */
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
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', bind);
  else bind();

  CPS.donate = { bind: bind };
})(window.CPS);

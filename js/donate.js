/* Support / donate page — client module.
   Split out so js/app.js stays under the push size limit.
   Consumes the shared context exposed as CPS.appCtx (grabbed at load, like
   js/cotd.js — this file loads after js/app.js). Registers as CPS.donate.

   The #donate view is UNLINKED: no tab, menu item, or button anywhere on
   the site points to it. It is reachable only by visiting /#donate directly.

   The chip-in buttons are PLACEHOLDERS: Franklin has no Stripe account yet,
   so there are no payment links and clicking Chip in only explains that
   donations aren't open. To go live later, replace placeholder() with a
   redirect to the Stripe Payment Link for the chosen amount (one link per
   preset, plus a flexible-amount link for Custom) — nothing else changes. */
(function (CPS) {
  'use strict';

  var C = CPS.appCtx || null;
  var amount = 5; // the $5 chip is preselected in index.html

  function fmt(n) { return '$' + n; }

  function render() {
    var sum = document.getElementById('dnSummary');
    if (sum) sum.textContent = fmt(amount) + ', one-time.';
  }

  function placeholder() {
    var msg = "Donations aren't open yet — this button is a placeholder until the payment setup is finished. Thanks for thinking of it, though!";
    if (C && C.toast) C.toast(msg, 'warn', 6000);
    else window.alert(msg);
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
    if (go) go.addEventListener('click', placeholder);
    render();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', bind);
  else bind();

  CPS.donate = { bind: bind };
})(window.CPS);

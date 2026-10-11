/* Card of the Day — client module.
   Split out so js/app.js stays under the push size limit.
   Consumes the shared context exposed as CPS.appCtx (grabbed at load, like
   js/tickets.js — this file loads after js/app.js). Registers as CPS.cotd.

   - Topbar pill indicator: today's set · rarity · prize · claimed state.
   - Claim pop-up at pack finish. The shared finish path (app.js finish() and the
     jumbled flow) calls CPS.slips.applyPackGrants, so we wrap that function —
     no app.js changes needed.
   - Claim state comes from the cps_cotd_status RPC (server is source of truth);
     the pop-up shows once per cotd_date per login session.
*/
(function (CPS) {
  'use strict';

  var C = CPS.appCtx || null;
  var statusCache = null;  // last cps_cotd_status payload
  var poppedFor = null;    // in-memory fast path; localStorage (per account+date) is the durable record

  /* The pop-up guard must survive page reloads: st.claimed stays true all
     day, and onPackFinish runs after EVERY pack, so a memory-only flag
     re-pops the announcement on the next pack after any reload or login
     flap. Persist it per account + date in localStorage. */
  function popKey() {
    var pid = (C && C.S && C.S.player && C.S.player.id) || 'anon';
    return 'cps_cotd_popped_' + pid;
  }
  function alreadyPopped(dateStr) {
    if (poppedFor === dateStr) return true;
    try { return localStorage.getItem(popKey()) === dateStr; } catch (e) { return false; }
  }
  function markPopped(dateStr) {
    poppedFor = dateStr;
    try { localStorage.setItem(popKey(), dateStr); } catch (e) {}
  }
  var pillEl = null;
  var hooked = false;
  var wasOnline = false;

  function online() { return !!(C && C.isCloud && C.isCloud()); }
  function esc(s) { return C ? C.esc(s) : String(s); }
  function cap(r) { return r ? r.charAt(0).toUpperCase() + r.slice(1) : r; }

  /* ---------- status ---------- */

  async function fetchStatus() {
    if (!online()) return null;
    try {
      var st = await CPS.cloud.call('cotd_status', {});
      if (st && st.ok) { statusCache = st; renderPill(); }
      return st;
    } catch (e) { return null; } // silent: the pill just stays as-is
  }

  /* ---------- topbar pill ---------- */

  function ensurePill() {
    if (pillEl || !C) return;
    var actions = C.$('.top-actions');
    var bell = document.getElementById('notifBtn');
    if (!actions) return;
    pillEl = document.createElement('button');
    pillEl.id = 'cotdPill';
    pillEl.className = 'cotd-pill hidden';
    pillEl.title = "Today's Card of the Day";
    pillEl.addEventListener('click', openDetail);
    actions.insertBefore(pillEl, bell || null);
  }

  function renderPill() {
    ensurePill();
    if (!pillEl || !statusCache) return;
    var st = statusCache;
    pillEl.classList.remove('hidden');
    pillEl.classList.toggle('claimed', !!st.claimed);
    pillEl.innerHTML = '🎯 <b>' + esc(cap(st.rarity)) + '</b>' +
      '<span class="cotd-pill-set">&nbsp;·&nbsp;' + esc(st.set_name) + '</span>' +
      '&nbsp;·&nbsp;+' + st.prize + '🎟️' + (st.claimed ? ' <span class="cotd-done">✓</span>' : '');
    pillEl.title = st.claimed ? 'Card of the Day — claimed! Nice hunting.'
      : "Today's Card of the Day: a " + cap(st.rarity) + ' hiding in ' + st.set_name + '. Tap for details.';
  }

  function openDetail() {
    if (!C || !statusCache) return;
    var st = statusCache;
    var html = '<button class="modal-x" data-close aria-label="Close">×</button>' +
      '<div class="cotd-modal">' +
      '<div class="cotd-big">🎯</div>' +
      '<h2>Card of the Day</h2>' +
      '<p class="cotd-sub">A <b>' + esc(cap(st.rarity)) + '</b> is hiding in the <b>' + esc(st.set_name) + '</b> set.</p>' +
      '<p class="cotd-prize">Pull it from any pack to win <b>+' + st.prize + ' 🎟️ spin tickets</b>.</p>';
    if (st.found) {
      html += '<p class="cotd-found">First found by <b>' + esc(st.found_by || 'someone') + '</b>' +
        (st.card_name ? ': <b>' + esc(st.card_name) + '</b>' : '') + '.</p>';
    } else {
      html += '<p class="cotd-unfound">Nobody has found it yet — it could be yours.</p>';
    }
    if (st.claimed) {
      html += '<p class="cotd-claimed">✅ You claimed today\'s card. Nice hunting.</p>';
    } else if (C.isAdmin && C.isAdmin()) {
      html += '<p class="muted small">Admins can\'t claim the Card of the Day.</p>';
    }
    html += '</div>';
    C.openModal(html);
  }

  /* ---------- claim pop-up at pack finish ---------- */

  function claimPopup(st) {
    if (!C) return;
    C.openModal('<button class="modal-x" data-close aria-label="Close">×</button>' +
      '<div class="cotd-modal">' +
      '<div class="cotd-big">🎯</div>' +
      '<h2>You\'ve pulled today\'s Card of the Day!</h2>' +
      '<p class="cotd-prize">+' + st.prize + ' 🎟️ spin tickets are yours.</p>' +
      (st.card_name ? '<p class="muted">The card: <b>' + esc(st.card_name) + '</b></p>' : '') +
      '</div>');
    try { C.fx.confetti(220); C.fx.banner('CARD OF THE DAY!', 'legendary'); } catch (e) {}
  }

  async function onPackFinish() {
    var st = await fetchStatus(); // force refresh: the server is source of truth
    if (!st || !st.ok) return;
    if (st.claimed && !alreadyPopped(st.cotd_date)) {
      markPopped(st.cotd_date);
      claimPopup(st);
    }
  }

  function hookFinish() {
    if (hooked || !window.CPS || !CPS.slips || !CPS.slips.applyPackGrants) return;
    if (CPS.slips.applyPackGrants.__cotdHooked) { hooked = true; return; }
    var orig = CPS.slips.applyPackGrants;
    var wrapped = function () {
      var r = orig.apply(this, arguments);
      try { onPackFinish(); } catch (e) { if (window.console) console.error(e); }
      return r;
    };
    wrapped.__cotdHooked = true;
    CPS.slips.applyPackGrants = wrapped;
    hooked = true;
  }

  /* ---------- boot: watch for login transitions (no page reload on login) ---------- */

  function tick() {
    var on = online();
    if (on && !wasOnline) {
      statusCache = null; poppedFor = null; // fresh login: forget the last account's state
      hookFinish();
      fetchStatus();
    }
    if (!on && pillEl) pillEl.classList.add('hidden');
    wasOnline = on;
  }

  if (C) {
    tick();
    setInterval(tick, 2500);
  } else if (window.console) {
    console.error('cotd.js: CPS.appCtx missing — is js/app.js loaded before js/cotd.js?');
  }

  CPS.cotd = { refresh: fetchStatus, status: function () { return statusCache; } };
})(window.CPS);

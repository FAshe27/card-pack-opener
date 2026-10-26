/* js/giftpop.js — Gift pop-ups + Say Thanks (migration 165).
   When someone gifts you a card, the server already writes a bell
   notification (kind 'gift_card'); this module makes it POP:
     * polls cps_list_notifications on the bell badge's own cadence
       (every 60s, plus on tab-visible and shortly after load);
     * any UNREAD gift_card / gift_thanks notification created after
       the feature launched queues a pop-up — oldest first, one at a
       time, never stomping an open modal or a pack reveal (a toast
       announces it and the pop waits, same pattern as Turn-In
       Rewards / milestones);
     * dismissing a pop marks its notification read (server-side), so
       it pops exactly once, on exactly one device — the bell keeps
       the row as history;
     * gifts from before migration 165 have no card meta: they pop
       text-only (from the notification text) with no card render and
       no Thanks button. Gifts AFTER 165 carry meta (set/card/holo/
       variant/giver), so the pop renders the actual card, offers
       "View Card", and offers "🙏 Say Thanks" — one call to
       cps_say_thanks, which notifies the giver exactly once with
       "<Name> said thank you for <Card>!" (kind 'gift_thanks'),
       which pops for the giver through this same module.
   Failure is silent by design: offline, logged out, or the RPC not
   live yet just means no pop this pass; nothing is marked read and
   nothing is lost. */
(function (CPS) {
  'use strict';
  var ctx = CPS.appCtx;
  if (!ctx) return;

  /* Only notifications created after the feature was built can pop —
     the 30 days of bell history that predates it stays bell-only. */
  var LAUNCH_ISO = '2026-10-20T13:00:00Z';
  var POLL_MS = 60000;
  var MAX_PER_PASS = 5;

  var queue = [];
  var inQueue = {};
  var running = false;
  var showing = false;
  var retryTimer = null;

  function seenKey() {
    var pid = (ctx.S && ctx.S.account && ctx.S.account.id) || 'anon';
    return 'cps_giftpop_seen_' + pid;
  }
  function seenSet() {
    try { return JSON.parse(localStorage.getItem(seenKey()) || '[]'); } catch (e) { return []; }
  }
  function markSeen(id) {
    try {
      var s = seenSet();
      if (s.indexOf(id) === -1) { s.push(id); localStorage.setItem(seenKey(), JSON.stringify(s.slice(-100))); }
    } catch (e) {}
  }
  function wasSeen(id) {
    return seenSet().indexOf(id) !== -1;
  }

  function modalBusy() {
    var m = document.getElementById('modal');
    return !!(m && !m.classList.contains('hidden'));
  }

  function markRead(id) {
    return CPS.cloud.call('read_notifications', { p_ids: [id] })
      .then(function () { ctx.refreshNotifBadge(true); }) // forced: a mark-read must not re-read the 10s cache
      .catch(function () { /* local seen-set still prevents a re-pop here */ });
  }

  function variantOf(meta) {
    if (meta && meta.tier && CPS.cards && CPS.cards.VARIANTS && CPS.cards.VARIANTS[meta.tier]) {
      return { tier: meta.tier, serial: parseInt(meta.serial, 10) };
    }
    return null;
  }
  function variantLabel(meta) {
    var v = variantOf(meta);
    if (!v) return '';
    var vt = CPS.cards.VARIANTS[v.tier];
    return ' ' + vt.name + ' #' + v.serial + '/' + vt.run;
  }

  async function cardHtml(meta) {
    if (!meta || !meta.set_id || !meta.card_id || !window.CardSets) return '';
    try {
      var set = window.CardSets.get(meta.set_id);
      if (set && set.stub && window.CardSets.load) set = await window.CardSets.load(meta.set_id);
      if (!set || !set.byId) return '';
      var card = set.byId.get(meta.card_id);
      if (!card) return '';
      var v = variantOf(meta);
      var rendered = CPS.cards.render(set, card, v ? { variant: v } : { holo: !!meta.holo });
      return '<div class="giftpop-card">' + rendered +
        '<div class="giftpop-cap"><b>' + ctx.esc(card.name) + '</b>' +
        '<span class="muted small">' + ctx.esc(set.name) + '</span></div></div>';
    } catch (e) { return ''; }
  }

  var current = null; /* the pop on screen, if any */

  function deliver(toasted) {
    if (showing && !modalBusy()) {
      /* The pop was closed without its buttons (backdrop tap — the
         site's delegated modal handler closes it directly): count it
         as seen on this device so it doesn't nag, leave the bell row
         unread as the reminder, and free the queue. */
      if (current) { markSeen(current.id); current = null; }
      showing = false;
    }
    if (!queue.length || showing) return;
    if (modalBusy() || (ctx.S && ctx.S.opening)) {
      if (!toasted) {
        var it = queue[0];
        ctx.toast(it.kind === 'gift_thanks' ? '🙏 Someone said thanks!' : '🎁 You got a gift!', 'good', 4000);
      }
      setTimeout(function () { deliver(true); }, 1500);
      return;
    }
    showNext();
  }

  async function showNext() {
    var it = queue.shift();
    if (!it) { showing = false; return; }
    showing = true;
    current = it;
    var meta = it.meta || {};
    var isThanks = it.kind === 'gift_thanks';
    var art = await cardHtml(meta);
    var canThank = !isThanks && !!meta.from && !meta.thanked;
    var giverName = meta.from_name || 'Someone';
    var title = isThanks ? 'Someone said thanks!' : 'You got a gift!';
    var emoji = isThanks ? '🙏' : '🎁';
    var body;
    if (isThanks) {
      body = '<p>' + ctx.esc(it.text) + '</p>';
    } else if (meta.card_name) {
      body = '<p><b>' + ctx.esc(giverName) + '</b> gifted you <b>' + ctx.esc(meta.card_name) + '</b>' +
        ctx.esc(variantLabel(meta)) + (meta.holo && !variantOf(meta) ? ' ✦ holo' : '') +
        (meta.set_name ? ' <span class="muted">(' + ctx.esc(meta.set_name) + ')</span>' : '') + '</p>';
    } else {
      body = '<p>' + ctx.esc(it.text) + '</p>';
    }
    ctx.openModal('<button class="modal-x" data-close aria-label="Close">×</button>' +
      '<div class="giftpop-wrap" style="text-align:center;padding:10px 6px 4px">' +
      '<div style="font-size:52px;line-height:1">' + emoji + '</div>' +
      '<h2>' + title + '</h2>' + body + art +
      '<div class="confirm-btns" style="justify-content:center;margin-top:10px">' +
      (canThank ? '<button class="btn primary" id="giftThanksBtn">🙏 Say Thanks</button>' : '') +
      (meta.set_id && meta.card_id ? '<button class="btn" id="giftViewBtn">View Card</button>' : '') +
      '<button class="btn' + (canThank ? '' : ' primary') + '" data-close>' + (isThanks ? 'Awesome!' : 'Close') + '</button>' +
      '</div></div>');

    var box = document.getElementById('modalBox');
    function dismiss(openCard) {
      markSeen(it.id);
      current = null;
      markRead(it.id);
      ctx.closeModal();
      showing = false;
      if (openCard) {
        ctx.openCardModal(meta.set_id, meta.card_id, !!meta.holo, variantOf(meta));
      } else if (queue.length) {
        setTimeout(function () { deliver(); }, 250);
      }
    }
    if (box) box.querySelectorAll('[data-close]').forEach(function (b) {
      b.addEventListener('click', function () { dismiss(false); });
    });
    var vb = box && box.querySelector('#giftViewBtn');
    if (vb) vb.addEventListener('click', function () { dismiss(true); });
    var tb = box && box.querySelector('#giftThanksBtn');
    if (tb) tb.addEventListener('click', async function () {
      tb.disabled = true;
      try {
        var r = await CPS.cloud.call('say_thanks', { p_notification_id: it.id });
        if (r && r.already) ctx.toast('You already thanked ' + giverName + ' for this one.', '', 3000);
        else ctx.toast('🙏 Thanks sent to ' + giverName + '!', 'good', 3000);
      } catch (e) { ctx.cloudError(e); }
      dismiss(false);
    });
    if (!isThanks && ctx.fx && ctx.fx.confetti) ctx.fx.confetti(180);
  }

  async function check() {
    try {
      if (running) {
        if (!retryTimer) retryTimer = setTimeout(function () { retryTimer = null; check(); }, 3000);
        return;
      }
      if (!ctx.isCloud() || !ctx.S.account) return;
      running = true;
      var n = null;
      /* Ride app.js's shared notification fetch when it is available
         (single-flight + cached) so the badge poll and this poller
         cost one list_notifications call per cycle, not two. */
      try { n = await (ctx.fetchNotifications ? ctx.fetchNotifications() : CPS.cloud.call('list_notifications')); } catch (e) { /* offline: retry next pass */ }
      running = false;
      if (!n || !n.items) return;
      var launch = Date.parse(LAUNCH_ISO);
      var fresh = n.items.filter(function (it) {
        return (it.kind === 'gift_card' || it.kind === 'gift' || it.kind === 'gift_thanks') &&
          !it.read && !wasSeen(it.id) &&
          Date.parse(it.created_at) >= launch;
      }).sort(function (a, b) { return Date.parse(a.created_at) - Date.parse(b.created_at); });
      fresh.slice(0, MAX_PER_PASS).forEach(function (it) {
        if (!inQueue[it.id]) { inQueue[it.id] = true; queue.push(it); }
      });
      deliver();
    } catch (e) { running = false; /* gift pops must never break the app */ }
  }

  setTimeout(check, 4000);
  /* No own interval: app.js's 60s badge tick calls check() after its
     refresh, on the same cadence this poller used (POLL_MS). The
     visibility nudge stays — the shared fetch dedupes the overlap. */
  document.addEventListener('visibilitychange', function () { if (!document.hidden) check(); });

  CPS.giftPop = { check: check };
})(window.CPS);

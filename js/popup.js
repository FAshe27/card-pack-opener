/* js/popup.js — One-off admin pop-up messages (2026-11-06).
   A notification of kind 'popup' carries a plain message in its text
   and, in meta, an optional button label (meta.button, default "OK")
   and an optional emoji (meta.emoji). This module makes it POP:
     * rides the shared notification fetch on a 60s cadence, plus on
       tab-visible and shortly after load (same pattern as giftpop);
     * any UNREAD 'popup' notification created after launch queues a
       modal — oldest first, one at a time, never stomping an open
       modal or a pack reveal (a toast announces it and the pop
       waits, same as gift pops);
     * pressing the button marks the notification read server-side,
       so it pops exactly once, on exactly one device; closing via
       the × or the backdrop counts as seen on this device only and
       leaves the bell row unread as the reminder;
     * the bell keeps the row as history either way.
   Failure is silent by design: offline or logged out just means no
   pop this pass; nothing is marked read and nothing is lost. */
(function (CPS) {
  'use strict';
  var ctx = CPS.appCtx;
  if (!ctx) return;

  /* Only notifications created after this feature was built can pop —
     earlier bell history stays bell-only. */
  var LAUNCH_ISO = '2026-11-06T15:30:00Z';
  var POLL_MS = 60000;
  var MAX_PER_PASS = 3;

  var queue = [];
  var inQueue = {};
  var running = false;
  var showing = false;
  var retryTimer = null;
  var current = null; /* the pop on screen, if any */

  function seenKey() {
    var pid = (ctx.S && ctx.S.account && ctx.S.account.id) || 'anon';
    return 'cps_popup_seen_' + pid;
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

  function deliver(toasted) {
    if (showing && !modalBusy()) {
      /* Closed without the button (backdrop tap or the × — the
         site's delegated modal handler closes it directly): seen on
         this device, bell row left unread, queue freed. */
      if (current) { markSeen(current.id); current = null; }
      showing = false;
    }
    if (!queue.length || showing) return;
    if (modalBusy() || (ctx.S && ctx.S.opening)) {
      if (!toasted) ctx.toast('📣 You have a message!', 'good', 4000);
      setTimeout(function () { deliver(true); }, 1500);
      return;
    }
    showNext();
  }

  function showNext() {
    var it = queue.shift();
    if (!it) { showing = false; return; }
    showPop(it);
  }

  function showPop(it) {
    showing = true;
    current = it;
    var meta = it.meta || {};
    var label = meta.button || 'OK';
    ctx.openModal('<button class="modal-x" data-close aria-label="Close">×</button>' +
      '<div class="giftpop-wrap" style="text-align:center;padding:10px 6px 4px">' +
      (meta.emoji ? '<div style="font-size:52px;line-height:1">' + ctx.esc(meta.emoji) + '</div>' : '') +
      '<p style="font-size:1.15rem;margin:12px 4px 4px">' + ctx.esc(it.text) + '</p>' +
      '<div class="confirm-btns" style="justify-content:center;margin-top:12px">' +
      '<button class="btn primary" id="popupBtn">' + ctx.esc(label) + '</button>' +
      '</div></div>');

    var box = document.getElementById('modalBox');
    function dismiss() {
      markSeen(it.id);
      current = null;
      markRead(it.id);
      ctx.closeModal();
      showing = false;
      if (queue.length) setTimeout(function () { deliver(); }, 250);
    }
    var btn = box && box.querySelector('#popupBtn');
    if (btn) btn.addEventListener('click', dismiss);
    if (box) box.querySelectorAll('[data-close]').forEach(function (b) {
      b.addEventListener('click', function () {
        /* The × is an escape hatch, not the joke's button: count it
           as seen here (deliver() would also catch the close), keep
           the bell row unread. openModal's own handler closes it. */
        markSeen(it.id);
        current = null;
        showing = false;
        if (queue.length) setTimeout(function () { deliver(); }, 250);
      });
    });
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
      /* Ride app.js's shared notification fetch when available
         (single-flight + cached) so the badge poll and this poller
         cost one list_notifications call per cycle, not two. */
      try { n = await (ctx.fetchNotifications ? ctx.fetchNotifications() : CPS.cloud.call('list_notifications')); } catch (e) { /* offline: retry next pass */ }
      running = false;
      if (!n || !n.items) return;
      var launch = Date.parse(LAUNCH_ISO);
      var fresh = n.items.filter(function (it) {
        return it.kind === 'popup' &&
          !it.read && !wasSeen(it.id) &&
          Date.parse(it.created_at) >= launch;
      }).sort(function (a, b) { return Date.parse(a.created_at) - Date.parse(b.created_at); });
      fresh.slice(0, MAX_PER_PASS).forEach(function (it) {
        if (!inQueue[it.id]) { inQueue[it.id] = true; queue.push(it); }
      });
      deliver();
    } catch (e) { running = false; /* pop-ups must never break the app */ }
  }

  setTimeout(check, 4000);
  setInterval(check, POLL_MS);
  document.addEventListener('visibilitychange', function () { if (!document.hidden) check(); });

  CPS.popups = { check: check };
})(window.CPS);

/* js/milestones.js — turn-in completion milestones.
   COMPLETION (Franklin's definition) = every card TURNED IN, not merely
   collected. Watches the local turned-in state after every state load:
   - a rarity fully turned in within a set  -> celebratory pop-up (local)
   - a whole set fully turned in           -> bigger pop-up + the client
     calls cps_announce_set_completion; the server verifies the
     completion, records it exactly once, and notifies every other
     player (same mechanism as chase-pull announcements).
   First run per account+device records a silent baseline — completions
   that already existed never pop or announce retroactively.
   Turn-ins are permanent, so milestones are monotonic: once earned,
   they can never un-earn or re-fire on this device. */
(function (CPS) {
  'use strict';
  var ctx = CPS.appCtx;
  var KEY = 'cps.milestones.v1.';
  var retryTimer = null;

  function compute() {
    var rar = {}, full = {};
    window.CardSets.all().forEach(function (set) {
      if (set.id === 'jumbled' || !set.cards.length) return;
      var turnedByR = {}, turnedTotal = 0;
      set.cards.forEach(function (c) {
        if (ctx.isTurned(set.id, c.id)) { turnedByR[c.rarity] = (turnedByR[c.rarity] || 0) + 1; turnedTotal++; }
      });
      ctx.R.RARITIES.forEach(function (r) {
        var pool = set.pools[r.key];
        if (pool && pool.length && (turnedByR[r.key] || 0) >= pool.length) rar[set.id + ':' + r.key] = true;
      });
      if (turnedTotal >= set.cards.length) full[set.id] = true;
    });
    return { rar: rar, full: full };
  }

  function load(key) {
    try { var raw = localStorage.getItem(key); return raw ? JSON.parse(raw) : null; } catch (e) { return null; }
  }
  function save(key, snap) {
    try { localStorage.setItem(key, JSON.stringify(snap)); } catch (e) { /* private mode etc. */ }
  }

  function modalBusy() {
    var m = document.getElementById('modal');
    return !!(m && !m.classList.contains('hidden'));
  }

  function showPopups(fresh) {
    /* fresh: [{set, rarities:[labels]}] and [{set, full:true}] */
    var item = fresh.shift();
    if (!item) return;
    var set = item.set;
    if (item.full) {
      ctx.fx.confetti(300);
      ctx.openModal('<button class="modal-x" data-close aria-label="Close">×</button>' +
        '<div style="text-align:center;padding:10px 6px 4px">' +
        '<div style="font-size:52px;line-height:1">🏆</div>' +
        '<h2>Collection Complete!</h2>' +
        '<p>You have turned in <b>every single card</b> in <b>' + ctx.esc(set.name) + '</b> — all ' + set.cards.length + ' of them.</p>' +
        '<p class="muted">That is a true completion. The other players have been notified!</p>' +
        '<div class="confirm-btns" style="justify-content:center"><button class="btn primary" data-close>Incredible!</button></div></div>');
      CPS.cloud.call('announce_set_completion', { p_set: set.id }).catch(function () { /* server dedupes; offline-safe */ });
    } else {
      ctx.fx.confetti(220);
      var names = item.rarities.map(function (l) { return '<b>' + ctx.esc(l) + '</b>'; }).join(', ');
      ctx.openModal('<button class="modal-x" data-close aria-label="Close">×</button>' +
        '<div style="text-align:center;padding:10px 6px 4px">' +
        '<div style="font-size:52px;line-height:1">🎉</div>' +
        '<h2>Rarity Complete!</h2>' +
        '<p>Every ' + names + ' card in <b>' + ctx.esc(set.name) + '</b> has been turned in.</p>' +
        '<p class="muted">Turn in the rest of the set to complete the whole collection!</p>' +
        '<div class="confirm-btns" style="justify-content:center"><button class="btn primary" data-close>Keep going!</button></div></div>');
    }
    /* wire the buttons (the modal system clones the box per open) */
    var box = document.getElementById('modalBox');
    if (box) box.querySelectorAll('[data-close]').forEach(function (b) {
      b.addEventListener('click', function () { ctx.closeModal(); if (fresh.length) setTimeout(function () { showPopups(fresh); }, 250); });
    });
  }

  function check() {
    try {
      if (!ctx.isCloud() || !ctx.S.account || !ctx.S.turnedIn) return;
      if (ctx.S.opening) { /* mid pack-reveal: check again once it settles */
        if (!retryTimer) retryTimer = setTimeout(function () { retryTimer = null; check(); }, 3000);
        return;
      }
      /* Turn-In Rewards (126): independent of the local snapshot below —
         the server dedupe table, not this device, tracks what's owed. */
      if (CPS.turninRewards) CPS.turninRewards.check();
      var key = KEY + ctx.S.account.id;
      var snap = compute();
      var prev = load(key);
      if (!prev) { save(key, snap); return; } /* silent baseline */
      var freshFull = [], freshRar = {};
      Object.keys(snap.full).forEach(function (sid) { if (!prev.full || !prev.full[sid]) freshFull.push(sid); });
      Object.keys(snap.rar).forEach(function (k) {
        if (prev.rar && prev.rar[k]) return;
        var sid = k.split(':')[0], rk = k.split(':')[1];
        if (freshFull.indexOf(sid) !== -1) return; /* the full-set pop-up subsumes its rarities */
        (freshRar[sid] = freshRar[sid] || []).push(rk);
      });
      save(key, snap); /* record first so nothing can double-fire */
      var queue = [];
      Object.keys(freshRar).forEach(function (sid) {
        var set = window.CardSets.get(sid); if (!set) return;
        queue.push({ set: set, rarities: (freshRar[sid] || []).map(function (rk) { return ctx.rarityOf(rk).label; }) });
      });
      freshFull.forEach(function (sid) {
        var set = window.CardSets.get(sid); if (!set) return;
        queue.push({ set: set, full: true });
      });
      if (!queue.length) return;
      if (modalBusy()) { /* don't stomp an open dialog; the snapshot is saved, so re-queue lightly */
        if (!retryTimer) retryTimer = setTimeout(function () { retryTimer = null; showPopups(queue); }, 4000);
        return;
      }
      showPopups(queue);
    } catch (e) { /* milestones must never break the app */ }
  }

  CPS.milestones = { check: check };
})(window.CPS);

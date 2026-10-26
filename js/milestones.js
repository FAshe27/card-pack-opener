/* js/milestones.js — turn-in completion milestones.
   COMPLETION (Franklin's definition) = every card TURNED IN, not merely
   collected:
   - a rarity fully turned in within a set  -> celebratory pop-up (local)
   - a whole set fully turned in           -> bigger pop-up + the client
     calls cps_announce_set_completion; the server verifies the
     completion, records it exactly once, and notifies every other
     player (same mechanism as chase-pull announcements).
   WHICH milestones are fresh is decided by the SERVER (migration 156,
   cps_milestone_sync): it keeps one completion snapshot per account,
   so a milestone pops exactly once per account, on whichever device
   loads first — never again on a second device. (Before 156 the
   snapshot lived in this browser's localStorage, so any device whose
   snapshot predated a crossing replayed its pop-up on the next visit.)
   The first sync for an account records a silent baseline —
   completions that already existed never pop or announce
   retroactively. If the sync call fails (RPC not live yet, offline),
   nothing pops and the server snapshot is untouched, so fresh
   milestones stay fresh for the next successful load.
   Turn-ins are permanent, so milestones are monotonic: once earned,
   they can never un-earn. */
(function (CPS) {
  'use strict';
  var ctx = CPS.appCtx;
  var retryTimer = null;
  var running = false;

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

  function deliver(queue, toasted) {
    if (!queue.length) return;
    if (modalBusy()) { /* don't stomp an open dialog — but say so at once
                          (a toast now, the pop-up when the way is clear),
                          and re-check briskly instead of every 4s */
      if (!toasted) ctx.toast('🎉 Turn-in milestone reached!', 'good', 4000);
      setTimeout(function () { deliver(queue, true); }, 1500);
      return;
    }
    showPopups(queue);
  }

  function retryLater() {
    if (!retryTimer) retryTimer = setTimeout(function () { retryTimer = null; check(); }, 3000);
  }

  async function check() {
    try {
      if (!ctx.isCloud() || !ctx.S.account || !ctx.S.turnedIn) return;
      if (ctx.S.opening) { /* mid pack-reveal: check again once it settles */
        retryLater();
        return;
      }
      /* Turn-In Rewards (126): independent of the milestone sync below —
         the server dedupe table, not this device, tracks what's owed. */
      if (CPS.turninRewards) CPS.turninRewards.check();
      if (running) { /* a sync is already in flight; its fresh list is
                        already fixed, so queue one follow-up pass */
        retryLater();
        return;
      }
      if (!window.CardSets || !window.CardSets.all().length) {
        /* Set files still streaming in (two-wave boot): a fresh
           milestone must be renderable by name, and the server marks
           it seen the moment it reports it — wait until sets exist. */
        retryLater();
        return;
      }
      running = true;
      var r = null;
      try {
        r = await CPS.cloud.call('milestone_sync', {});
      } catch (e) { /* not live yet / offline: the server snapshot is
                       untouched, so fresh milestones stay fresh and
                       pop on the next successful load */ }
      running = false;
      if (!r || r.baseline) return;
      deliver(queueFrom(r));
    } catch (e) { running = false; /* milestones must never break the app */ }
  }

  /* Build the pop-up queue from a sync-shaped result
     ({fresh_rar:[{set,rarity}], fresh_full:[setId]}). */
  function queueFrom(r) {
    var freshFull = (r.fresh_full || []).filter(function (sid) { return sid !== 'jumbled'; }); /* Jumbled Mess: no collection rewards/celebrations yet (Franklin, mig. 169) */
    var freshRar = {};
    (r.fresh_rar || []).forEach(function (fr) {
      if (!fr || !fr.set || !fr.rarity || fr.set === 'jumbled') return;
      if (freshFull.indexOf(fr.set) !== -1) return; /* the full-set pop-up subsumes its rarities */
      (freshRar[fr.set] = freshRar[fr.set] || []).push(fr.rarity);
    });
    var queue = [];
    Object.keys(freshRar).forEach(function (sid) {
      var set = window.CardSets.get(sid); if (!set) return;
      queue.push({ set: set, rarities: (freshRar[sid] || []).map(function (rk) { return ctx.rarityOf(rk).label; }) });
    });
    freshFull.forEach(function (sid) {
      var set = window.CardSets.get(sid); if (!set) return;
      queue.push({ set: set, full: true });
    });
    return queue;
  }

  /* Migration 195: the turn-in RPCs return the fresh milestones they
     just created (computed in-transaction, snapshot already advanced),
     and the turn-in flows announce them in-flow — the same pattern that
     made the turn-in % reward messages instant (migration 179). The
     ambient check()/sync remains the safety net for anything else. */
  function announce(r) {
    try {
      if (!r || r.baseline) return;
      if (!window.CardSets || !window.CardSets.all().length) return;
      deliver(queueFrom(r));
    } catch (e) { /* milestones must never break the app */ }
  }

  CPS.milestones = { check: check, announce: announce };
})(window.CPS);

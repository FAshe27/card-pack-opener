/* Turn in cards from ALL sets — the global sweep.
   Buttons live in the Collection view in their own .coll-actions row
   above the per-set one; app.js calls CPS.turninAll.refresh() from
   renderCollection so the counts stay current. Counts are the per-set
   preview rules (turnInPreview in app.js) summed across every set;
   the server does the real work and re-checks everything
   (migration 118: cps_turn_in_all_sets). Turn-ins are permanent.
   (The duplicates-only buttons were removed 2026-10-23 at Franklin's
   call — the sweep is the one turn-in path now; the dupes RPCs remain
   on the server, unused.) */
(function (CPS) {
  'use strict';
  function ctx() { return CPS.appCtx; }

  function previews() {
    var C = ctx();
    var vmap = C.variantCountMap();
    var sweep = { eligible: 0, holoOnly: 0, onlyCopy: 0, locked: 0 };
    /* State-only: eligibility needs the player's own entries (n/h/v/vh),
       the turned-in map and the variant counts — all already in state.
       Iterating the set FILES instead made the count depend on which
       sets happened to be loaded: the button opened at (90) and later
       jumped to the true (1175) once more sets had loaded. */
    Object.keys(C.S.player.sets || {}).forEach(function (sid) {
      var st = C.S.player.sets[sid]; if (!st || !st.cards) return;
      Object.keys(st.cards).forEach(function (cid) {
        if (C.isTurned(sid, cid)) return;
        var e = st.cards[cid]; if (!e || !e.n) return;
        var vn = vmap[sid + ':' + cid] || 0;
        var fung = e.n - (e.v || 0) - vn;
        var plain = (e.n - e.h) - ((e.v || 0) - (e.vh || 0));
        if (fung < 1) { sweep.locked++; return; }
        sweep.eligible++;
        if (plain < 1) sweep.holoOnly++;
        if (e.n - (e.v || 0) === 1) sweep.onlyCopy++;
      });
    });
    return { sweep: sweep };
  }

  function refresh(retried) {
    var C = ctx(); if (!C || !C.S || !C.S.player) return;
    var bA = document.getElementById('turnInAllSetsBtn');
    if (!bA) return;
    if (!C.isCloud()) { bA.classList.add('hidden'); return; }
    /* Counts are state-only now (see previews), so no set files are
       loaded here at all — the 2026-10-21 stub-scan freeze class and
       the stale partial count both lived in that loading step. The
       one remaining input is the variant list (a single small RPC):
       if it has not loaded yet, fetch it and repaint once. The
       retried flag is the same hard one-shot stop as before. */
    if (!retried && C.isCloud() && !C.S.myVariants && C.ensureVariants) {
      C.ensureVariants().then(function () { refresh(true); });
    }
    var p = previews();
    bA.classList.toggle('hidden', !p.sweep.eligible);
    bA.textContent = 'Turn in cards from all sets (' + p.sweep.eligible + ')';
  }

  async function holoPrompt(C, holoOnly) {
    if (holoOnly <= 0) return false;
    return C.confirmDialog('Holographic cards',
      '<p>Some of these cards are holographic — for <b>' + holoOnly + '</b> of them, the only copy that can be turned in is a holo.</p>' +
      '<p class="muted">Do you still want to turn these in?</p>',
      'Yes, turn in the holos too', 'Skip the holos');
  }

  async function sweepFlow() {
    var C = ctx();
    if (!C.isCloud()) return;
    await C.ensureVariants();
    if (C.ensureOwnedSets) await C.ensureOwnedSets();
    var p = previews().sweep;
    if (!p.eligible) { C.toast('Nothing to turn in — everything you own is already turned in, vaulted, or numbered.', 'warn'); return; }
    var ok = await C.confirmDialog('Turn in one of EVERY card — all sets',
      '<p>Turn in <b>one copy of every card you own</b>, across <b>every set</b> — <b>' + p.eligible + '</b> card' + (p.eligible === 1 ? '' : 's') + ' total, including cards you only have one copy of.</p>' +
      '<p class="muted">Turning in destroys a copy and marks the card <b>permanently collected</b>: it counts toward your completion forever, even if you never own it again. <b>There is no undo.</b></p>' +
      (p.onlyCopy ? '<p class="muted">' + p.onlyCopy + ' of these ' + (p.onlyCopy === 1 ? 'is' : 'are') + ' your <b>only on-hand copy</b>.</p>' : '') +
      (p.locked ? '<p class="muted">' + p.locked + ' card' + (p.locked === 1 ? '' : 's') + ' skipped — only vaulted or numbered copies on hand.</p>' : ''),
      'Turn them in');
    if (!ok) return;
    var includeHolos = await holoPrompt(C, p.holoOnly);
    if (includeHolos === null) return; /* holo dialog dismissed = abort the whole turn-in */
    try {
      var r = await CPS.cloud.call('turn_in_all_sets', { p_include_holos: includeHolos });
      await C.refreshCloud();
      if (CPS.turninRewards && r && r.turnin_rewards_by_set) {
        Object.keys(r.turnin_rewards_by_set).forEach(function (sid) {
          CPS.turninRewards.announce(sid, r.turnin_rewards_by_set[sid]);
        });
      }
      if (CPS.milestones && r) CPS.milestones.announce(r.milestones);
      C.toast('✓ Turned in ' + r.turned + ' card' + (r.turned === 1 ? '' : 's') + ' across all sets!' +
        (r.skipped_holo ? ' Skipped ' + r.skipped_holo + ' holo-only.' : '') +
        (r.skipped_locked ? ' Skipped ' + r.skipped_locked + ' locked.' : ''), 'good', 5000);
    } catch (e) { C.cloudError(e); }
  }

  function bind() {
    var bA = document.getElementById('turnInAllSetsBtn');
    if (bA) bA.addEventListener('click', sweepFlow);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', bind); else bind();

  CPS.turninAll = { refresh: refresh };
})(window.CPS = window.CPS || {});

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
    window.CardSets.all().forEach(function (sd) {
      var st = C.S.player.sets[sd.id]; if (!st) return;
      sd.cards.forEach(function (c) {
        if (C.isTurned(sd.id, c.id)) return;
        var e = st.cards[c.id]; if (!e || !e.n) return;
        var vn = vmap[sd.id + ':' + c.id] || 0;
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
    /* Lazy sets: counts need the owned sets' card lists — load any that
       are still stubs, then repaint with the full picture. */
    /* The stub scan must cover exactly the sets ensureOwnedSets() will
       load — app.js's ownedSetIds rule: state holding cards or pulls.
       Scanning every state key also caught 'jumbled', whose state never
       holds cards (its pulls land in home sets), so its stub could never
       clear and the .then below re-invoked refresh() forever — a promise
       loop that hard-froze the tab on ANY Collection open (2026-10-21,
       once the Jumbled exclusives put 'jumbled' in the registry). The
       retried flag is a hard stop on top: at most one reload round per
       render, even if a set file ever fails to load. */
    var stubOwned = Object.keys(C.S.player.sets || {}).some(function (id) {
      var st = C.S.player.sets[id];
      if (!st || !((st.cards && Object.keys(st.cards).length) || (st.stats && st.stats.pulled > 0))) return false;
      var s = window.CardSets.get(id); return s && s.stub;
    });
    if (stubOwned && !retried && C.ensureOwnedSets) C.ensureOwnedSets().then(function () { refresh(true); });
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

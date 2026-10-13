/* js/popfill.js — card modal population numbers ("Times pulled" /
   "Currently existing"), filled from public.cps_card_population.
   The fill used to live in app.js as fillPopulation(); it moved here
   because app.js is at its push-size ceiling (the kernel counts UTF-8
   bytes, and app.js is full of emoji). app.js's openCardModal calls
   CPS.popfill(box, set, card) next to fillCensus. "pulled" counts
   pack openings by real players only (migration 137) — the same
   population "total" is counted over, so the two subtract cleanly. */
(function () {
  window.CPS = window.CPS || {};
  CPS.popfill = async function (box, set, card) {
    var el = box.querySelector('#cardPop'), p2 = box.querySelector('#cardPulled');
    if (!el) return;
    var S = CPS.appCtx && CPS.appCtx.S;
    if (!S || S.mode !== 'cloud') { el.textContent = '—'; if (p2) p2.textContent = '—'; return; }
    try {
      var pop = await CPS.cloud.call('card_population', { p_set: set.id, p_card: card.id });
      if (el.isConnected) {
        el.textContent = pop.total + ' cop' + (pop.total === 1 ? 'y' : 'ies') +
          (pop.holos ? ' (' + pop.holos + ' holo)' : '');
        if (p2) p2.textContent = pop.pulled ?? '—';
      }
    } catch (e) {
      if (el.isConnected) { el.textContent = '—'; if (p2) p2.textContent = '—'; }
    }
  };
})();

/* Jumbled Mess packs: 5 cards, each from a random set. Cloud-only.
   Consumes CPS.appCtx (S, ps, beginOpening, etc.) and registers as CPS.jumbled.
   The server (cps_open_pack with p_set='jumbled') does the actual rolling;
   this module handles inventory display, the open flow, and per-set local
   state updates. Cards land in their home sets' collections. */
(function (CPS) {
  var ctx = CPS.appCtx;
  var S = ctx.S;

  function jset() {
    return {
      id: 'jumbled',
      name: 'Jumbled Mess',
      pack: { skin: 'jumbled', emblem: '\u{1F3B2}', name: 'Jumbled Mess', size: 5 },
      theme: { primary: '#a855f7', secondary: '#ec4899' },
      cards: [],
      byId: new Map(),
      numWidth: 3
    };
  }

  function jpacks() {
    var st = S.player && S.player.sets && S.player.sets['jumbled'];
    return st ? (st.packs || 0) : 0;
  }

  function renderBox() {
    var box = ctx.$('#jumbledBox');
    if (!box) return;
    var show = ctx.isCloud() && !ctx.isLocked() && jpacks() > 0;
    box.style.display = show ? '' : 'none';
    if (!show) return;
    ctx.$('#jumbledPackArt').innerHTML = CPS.cards.pack(jset(), 'mini');
    var n = jpacks();
    ctx.$('#jumbledCount').textContent = n;
    ctx.$('#jumbledCountLabel').textContent = n === 1 ? 'Jumbled Mess pack' : 'Jumbled Mess packs';
    var btn = ctx.$('#openJumbledBtn');
    var busy = S.busy || (S.opening && !S.opening.finished);
    btn.disabled = busy;
  }

  async function open() {
    if ((S.opening && !S.opening.finished) || S.busy) return;
    if (ctx.isLocked()) return;
    if (!ctx.isCloud()) { ctx.toast('Jumbled Mess packs need online play.', 'warn'); return; }
    if (jpacks() <= 0) { ctx.toast('Out of Jumbled Mess packs! Ask Franklin for more.', 'warn'); ctx.audio.error(); return; }
    S.busy = true;
    var server = null;
    try {
      server = await CPS.cloud.call('open_pack', { p_set: 'jumbled' });
    } catch (e) {
      S.busy = false;
      renderBox();
      ctx.cloudError(e);
      return;
    }
    S.busy = false;
    S.myVariants = null; S.variantCensus = null;

    var now = Date.now();
    var pulls = server.cards.map(function (c) {
      var home = window.CardSets.get(c.set_id) || null;
      var card = (home && home.byId.get(c.id)) || {
        id: c.id, num: c.id, name: 'Card ' + c.id, rarity: c.rarity, subtitle: '',
        details: '(This card is newer than your copy of the set file. Refresh the page.)', image: ''
      };
      return {
        card: card, homeSet: home, holo: !!c.holo, isNew: !!c.new,
        variant: c.variant || null, serial: c.serial || null
      };
    });

    /* Update local state: jumbled inventory + each home set's collection. */
    ctx.ps({ id: 'jumbled' }).packs = server.packs_left;
    var touched = {};
    pulls.forEach(function (p) {
      if (!p.homeSet) return;
      var st = ctx.ps(p.homeSet);
      var e = st.cards[p.card.id] = st.cards[p.card.id] || { n: 0, h: 0 };
      e.n++; if (p.holo) e.h++;
      st.stats.pulled++; if (p.holo) st.stats.holos++;
      st.stats.byRarity[p.card.rarity] = (st.stats.byRarity[p.card.rarity] || 0) + 1;
      st.recent.unshift({ id: p.card.id, holo: p.holo, at: now });
      st.recent = st.recent.slice(0, 60);
      touched[p.homeSet.id] = st;
    });
    Object.keys(touched).forEach(function (id) { touched[id].stats.opened++; });
    ctx.save();

    /* Stage the pack for tearing (mirrors startOpen's UI setup). */
    var j = jset();
    S.opening = { set: j, pulls: pulls, torn: false, revealed: pulls.map(function () { return false; }), finished: false, auto: false };
    ctx.refreshQuests();
    ctx.$('#stageIdle').classList.add('hidden');
    ctx.$('#revealGrid').classList.add('hidden'); ctx.$('#revealGrid').innerHTML = '';
    ctx.$('#stageControls').classList.add('hidden');
    var sp = ctx.$('#stagePack');
    sp.innerHTML = '<div class="pack-wrap">' + CPS.cards.pack(j, 'ready') + '</div><div class="tear-hint">Click the pack to tear it open</div>';
    sp.classList.remove('hidden');
    ctx.audio.click();
    ctx.renderPacksSide();
    renderBox();
  }

  CPS.jumbled = { open: open, renderBox: renderBox, count: jpacks, pseudoSet: jset };
})(window.CPS);

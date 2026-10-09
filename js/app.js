/* Main UI. */
(function (CPS) {
  var U = CPS.util, R = window.CPSRarities, Store = CPS.Store, audio = CPS.audio, fx = CPS.fx;
  var $ = U.$, $$ = U.$$, esc = U.esc;

  var CONFIG = {
    starterPacks: 3,   // packs a player gets the first time they open a set
    recentMax: 36      // recent pulls kept in stats
  };

  var S = {
    player: null, set: null, view: 'packs', opening: null, dev: false,
    coll: { own: 'all', rarity: '', q: '', sort: 'num' },
    loadWarnings: [],
    mode: 'locked',         // 'cloud' (logged in), 'locked' (login screen) or 'guest' (only when online play is off in js/config.js)
    account: null,          // cloud: {id, display_name, is_admin}
    onlineSets: [],         // cloud: set ids that exist on the server
    guestImported: false,
    busy: false
  };

  /* ---------------------------------------------------------- helpers */
  function rarityOf(key) { return R.RARITIES[R.INDEX[key]]; }
  function save() {
    if (S.mode === 'cloud') return Promise.resolve(); // the server is the source of truth
    return Store.savePlayer(S.player).catch(function (e) { console.warn(e); });
  }
  function isCloud() { return S.mode === 'cloud'; }
  function isLocked() { return S.mode === 'locked'; }
  /* Admin area: admin accounts (server-checked); "Sets & Settings" for everyone when online play is off. */
  function canAdminArea() { return isAdmin() || S.mode === 'guest'; }
  function devOn() { return !!S.dev && canAdminArea(); } // Dev tools only ever show for admins (or offline mode)
  function isAdmin() { return isCloud() && S.account && S.account.is_admin; }
  function ps(set) {
    set = set || S.set;
    var p = S.player, st = p.sets[set.id];
    if (!st) {
      st = p.sets[set.id] = { packs: S.mode === 'guest' ? CONFIG.starterPacks : 0, cards: {}, recent: [], created: Date.now(),
        stats: { opened: 0, pulled: 0, holos: 0, byRarity: {}, best: null } };
      save();
    }
    return st;
  }
  function ownedCount(set, st) {
    var n = 0;
    set.cards.forEach(function (c) { if (st.cards[c.id] && st.cards[c.id].n > 0) n++; });
    return n;
  }
  function toast(msg, type, ms) {
    var t = U.h('<div class="toast ' + (type || '') + '">' + esc(msg) + '</div>');
    $('#toasts').appendChild(t);
    setTimeout(function () { t.classList.add('out'); setTimeout(function () { t.remove(); }, 400); }, ms || 3200);
  }
  function loadScript(src) {
    return new Promise(function (res) {
      var s = document.createElement('script');
      s.src = src; s.onload = function () { res(true); }; s.onerror = function () { res(false); };
      document.head.appendChild(s);
    });
  }

  /* ---------------------------------------------------------- boot */
  async function boot() {
    var files = window.CardSets.manifest || [];
    for (var i = 0; i < files.length; i++) {
      var ok = await loadScript('sets/' + files[i]);
      if (!ok) S.loadWarnings.push('Could not load sets/' + files[i]);
    }
    var custom = await Store.listCustomSets();
    custom.forEach(function (raw) { window.CardSets.register(raw, 'imported'); });
    if (!window.CardSets.all().length) {
      $('main').innerHTML = '<div class="panel"><h2>No card sets found</h2><p>Add a set file to <code>sets/</code> and list it in <code>sets/manifest.js</code>.</p></div>';
      return;
    }
    S.dev = Store.getPref('dev', false) === true;
    var wantDev = /[?&]dev\b/.test(location.search);
    audio.enabled = Store.getPref('sound', true);

    await initAccount();
    var last = Store.getPref('set', null);
    S.set = window.CardSets.get(last) || window.CardSets.all()[0];
    bind();
    fillSetSelect();
    applyPrefsUI();
    var v = (location.hash || '').replace('#', '');
    showView(['packs', 'wheel', 'collection', 'players', 'stats', 'odds', 'sets', 'admin'].indexOf(v) >= 0 ? v : 'packs', true);
    renderPacksSide(); resetStage();
    S.loadWarnings.concat(window.CardSets.errors).forEach(function (w) { toast(w, 'warn', 6000); });
    document.body.classList.add('ready');
    if (isLocked()) showGate(S.gate || {});
    else if (wantDev && !S.dev && canAdminArea()) requestDevUnlock();
  }

  /* ---------------------------------------------------------- online accounts */
  async function initAccount() {
    if (!CPS.cloud.enabled) { await ensurePlayer(); S.mode = 'guest'; grantGuestDailySpin(); return; } // online play turned off in js/config.js
    setLocked();
    if (!CPS.cloud.hasToken()) { S.gate = {}; return; }
    try {
      enterCloud(await CPS.cloud.call('get_state'));
    } catch (e) {
      if (e.kind === 'auth') { CPS.cloud.clearToken(); S.gate = { msg: 'Your session ended. Please log in again.' }; }
      else S.gate = { msg: e.message, retry: e.kind === 'network' };
    }
  }

  /* Not logged in: an empty, never-saved placeholder profile behind the login screen. */
  function setLocked() {
    S.mode = 'locked'; S.account = null; S.onlineSets = [];
    S.player = { id: '', name: 'Log in', sets: {} };
  }

  /* Turn the server snapshot into the same shape the guest profile uses. */
  function enterCloud(state) {
    var sets = {};
    function get(id) {
      return sets[id] || (sets[id] = { packs: 0, cards: {}, recent: [], stats: { opened: 0, pulled: 0, holos: 0, byRarity: {}, best: null } });
    }
    Object.keys(state.inventory || {}).forEach(function (id) { get(id).packs = state.inventory[id]; });
    (state.collection || []).forEach(function (r) { get(r[0]).cards[r[1]] = { n: r[2], h: r[3] }; });
    Object.keys(state.stats || {}).forEach(function (id) {
      var x = state.stats[id], st = get(id).stats;
      st.opened = x.opened; st.pulled = x.pulled; st.holos = x.holos; st.byRarity = x.by_rarity || {};
      st.best = x.best ? { id: x.best.id, holo: !!x.best.holo, at: Date.parse(x.best.at) || Date.now() } : null;
    });
    Object.keys(state.recent || {}).forEach(function (id) {
      get(id).recent = state.recent[id].map(function (c) { return { id: c.id, holo: !!c.holo }; });
    });
    S.mode = 'cloud';
    S.account = state.account;
    S.onlineSets = state.online_sets || [];
    S.spins = state.spins || 0;
    S.wheelCfg = state.wheel || null;
    S.favorites = {};
    (state.favorites || []).forEach(function (f) { S.favorites[f[0] + ':' + f[1]] = true; });
    S.guestImported = !!state.guest_imported;
    S.player = { id: state.account.id, name: state.account.display_name, cloud: true, sets: sets };
  }

  async function refreshCloud() {
    try { enterCloud(await CPS.cloud.call('get_state')); applyPrefsUI(); renderPacksSide(); if (!S.opening) resetStage(); renderView(); refreshQuests(); }
    catch (e) { cloudError(e); }
  }

  function cloudError(e) {
    if (e && e.kind === 'auth') { lockOut(e.message || 'Please log in again.'); return; }
    toast((e && e.message) || 'Something went wrong.', e && e.kind === 'network' ? 'warn' : 'error', 5000);
    audio.error();
  }

  /* Back to the login screen (session ended or logged out). */
  function lockOut(msg) {
    CPS.cloud.clearToken();
    S.opening = null;
    setLocked();
    if (S.view === 'admin') showView('packs');
    applyPrefsUI(); resetStage(); renderView();
    showGate({ msg: msg });
  }

  async function doLogin(username, pin, remember) {
    var r = await CPS.cloud.login(username, pin, remember);
    if (!r || !r.ok) return r;
    enterCloud(await CPS.cloud.call('get_state'));
    afterEnter();
    toast('Welcome, ' + S.account.display_name + '!', 'good');
    return r;
  }

  function afterEnter() {
    S._wheelEnd = null;
    applyPrefsUI(); fillSetSelect(); renderPacksSide(); resetStage(); renderView(); refreshQuests();
  }

  /* What the server needs to know about a set: cards + the resolved pack odds. */
  function setPayload(set) {
    return {
      id: set.id, name: set.name, code: set.code,
      pack: { name: set.pack.name, holo: set.pack.holo,
              slots: set.pack.slots.map(function (s) { return { count: s.count, label: s.label, odds: s.odds }; }) },
      cards: set.cards.map(function (c) { return { id: c.id, num: typeof c.num === 'number' ? c.num : parseInt(c.num, 10) || null, name: c.name, rarity: c.rarity }; })
    };
  }

  async function ensurePlayer() {
    var id = Store.getActivePlayerId(), p = id ? await Store.loadPlayer(id) : null;
    if (!p) {
      var list = await Store.listPlayers();
      if (list.length) p = await Store.loadPlayer(list[0].id);
      if (!p) p = await Store.createPlayer('Player 1');
    }
    p.sets = p.sets || {};
    S.player = p; Store.setActivePlayerId(p.id);
  }

  function applyPrefsUI() {
    document.body.classList.toggle('dev', devOn());
    $('#adminTabBtn').textContent = S.mode === 'guest' ? 'Sets & Settings' : 'Admin';
    $('#devToggle').checked = S.dev;
    $('#soundToggle').checked = audio.enabled;
    $('#soundBtn').textContent = audio.enabled ? '🔊' : '🔇';
    $('#playerName').textContent = S.player.name;
    $('#playerAvatar').textContent = (S.player.name.trim()[0] || 'P').toUpperCase();
    document.body.classList.toggle('cloud', isCloud());
    document.body.classList.toggle('guest', S.mode === 'guest');
    document.body.classList.toggle('locked', isLocked());
    document.body.classList.toggle('online-enabled', CPS.cloud.enabled);
    document.body.classList.toggle('admin', !!isAdmin());
    $('#playerBtn').classList.toggle('online', isCloud());
    $('#playerBtn').title = isCloud() ? 'Your account' : isLocked() ? 'Log in' : 'Switch player';
    $('#modeTag').textContent = isCloud() ? (isAdmin() ? 'admin' : 'online') : isLocked() ? '' : 'local';
    updateWheelGlow();
  }

  /* Packs the player currently holds for a set. Side-effect-free (unlike ps()). */
  function packCount(set) {
    var sets = (S.player && S.player.sets) || {};
    var st = sets[set.id];
    if (st) return st.packs;
    return S.mode === 'guest' ? CONFIG.starterPacks : 0;
  }

  function fillSetSelect() {
    $('#setSelect').innerHTML = window.CardSets.all().map(function (s) {
      var n = packCount(s), cur = s.id === S.set.id, cls = (n > 0 ? 'has-packs' : '') + (cur ? ' is-current' : '');
      var mark = (cur ? '\u2192 ' : '') + (n > 0 ? '\u25CF ' : '');
      return '<option value="' + esc(s.id) + '"' + (cur ? ' selected' : '') + (cls ? ' class="' + cls.trim() + '"' : '') + '>' +
        mark + esc(s.name) + ' (' + n + ')</option>';
    }).join('');
  }

  function selectSet(id) {
    var set = window.CardSets.get(id);
    if (!set) return;
    S.set = set; Store.setPref('set', id);
    $('#setSelect').value = id;
    S.coll.rarity = '';
    resetStage(); renderPacksSide(); renderView();
  }

  /* ---------------------------------------------------------- views */
  function showView(name, quiet) {
    if (name === 'daily' && !isCloud()) name = 'packs';
    if (name === 'sets') name = 'admin'; // Sets & Settings now lives in the Admin area
    if (name === 'admin' && !canAdminArea()) name = 'packs';
    S.view = name;
    $$('.view').forEach(function (v) { v.classList.toggle('active', v.id === 'view-' + name); });
    $$('.tab').forEach(function (t) { t.classList.toggle('active', t.dataset.view === name); });
    if (location.hash !== '#' + name) history.replaceState(null, '', '#' + name);
    window.scrollTo(0, 0);
    renderView();
    if (name === 'admin' && !quiet && isAdmin() && !S.dev) requestDevUnlock();
  }
  function renderView() {
    if (S.view === 'daily') { renderDaily(); return; }
    if (S.view === 'collection') {
      renderCollection();
      if (isCloud() && !S.myVariants) ensureVariants().then(function () { if (S.view === 'collection') renderCollection(); });
    }
    else if (S.view === 'players') renderPlayers();
    else if (S.view === 'trade') renderTradeBuilder();
    else if (S.view === 'trade-history') renderTradeHistory();
    else if (S.view === 'stats') renderStats();
    else if (S.view === 'odds') renderOdds();
    else if (S.view === 'admin') renderAdminArea();
    else if (S.view === 'wheel') renderWheel();
    else renderPacksSide();
  }

  /* ---------------------------------------------------------- packs view */
  function renderPacksSide() {
    fillSetSelect(); // keep the set dropdown's pack counts live
    var set = S.set, st = ps();
    var ip = $('#invPack');
    ip.innerHTML = CPS.cards.pack(set, 'mini') + (st.packs ? '<span class="inv-badge">' + st.packs + '</span>' : '');
    ip.classList.toggle('clickable', st.packs > 0); ip.classList.toggle('empty', !st.packs);
    ip.setAttribute('role', 'button'); ip.tabIndex = 0;
    ip.title = st.packs ? 'Click to open and tear a pack' : 'No packs left';
    ip.setAttribute('aria-label', st.packs ? 'Open a ' + set.name + ' pack' : 'No packs left');
    $('#packCount').textContent = st.packs;
    $('#packCountLabel').textContent = st.packs === 1 ? 'unopened pack' : 'unopened packs';
    var busy = (S.opening && !S.opening.finished) || S.busy;
    $('#openBtn').disabled = !st.packs || busy;
    $('#openBtn').textContent = st.packs ? 'Open a pack' : 'No packs left';
    var owned = ownedCount(set, st);
    $('#miniStats').innerHTML =
      '<div><span>Packs opened</span><b>' + st.stats.opened + '</b></div>' +
      '<div><span>Collected</span><b>' + owned + ' / ' + set.cards.length + '</b></div>';
  }

  function resetStage() {
    S.opening = null;
    var set = S.set, st = ps();
    // the big pack in the middle is clickable too: one click opens + tears it (same as the sidebar pack)
    $('#stageIdle').innerHTML = '<div class="idle-pack' + (st.packs ? ' clickable' : ' empty') + '" role="button" tabindex="0" title="' +
        (st.packs ? 'Click to open and tear a pack' : 'No packs left') + '">' + CPS.cards.pack(set, 'float') + '</div>' +
      '<div class="idle-msg">' + (st.packs
        ? '<b>' + st.packs + ' pack' + (st.packs === 1 ? '' : 's') + ' ready.</b> Click the pack (or press <kbd>Space</kbd>) to open.'
        : '<b>Out of packs!</b> Win, earn, or beg for packs and redeem them!') + '</div>';
    $('#stageIdle').classList.remove('hidden');
    $('#stagePack').classList.add('hidden'); $('#stagePack').innerHTML = '';
    $('#revealGrid').classList.add('hidden'); $('#revealGrid').innerHTML = '';
    $('#stageControls').classList.add('hidden');
    renderPacksSide();
  }

  async function startOpen() {
    if ((S.opening && !S.opening.finished) || S.busy) return;
    if (isLocked()) { showGate({}); return; }
    var set = S.set, st = ps();
    if (st.packs <= 0) { toast('Out of packs! Win, earn, or beg for packs and redeem them!', 'warn'); audio.error(); return; }
    var pulls, seen = {}, now = Date.now(), server = null;
    if (isCloud()) {
      if (S.onlineSets.indexOf(set.id) < 0) { toast("This set isn't on the server yet. An admin can upload it from the Admin tab.", 'warn', 5000); return; }
      S.busy = true; $('#openBtn').disabled = true; $('#openBtn').textContent = 'Opening…';
      try { server = await CPS.cloud.call('open_pack', { p_set: set.id }); }
      catch (e) { S.busy = false; renderPacksSide(); cloudError(e); return; }
      S.busy = false;
      S.myVariants = null; S.variantCensus = null;
      pulls = server.cards.map(function (c) {
        var card = set.byId.get(c.id) || { id: c.id, num: c.id, name: 'Card ' + c.id, rarity: c.rarity, subtitle: '', details: '(This card is newer than your copy of the set file. Refresh the page.)', image: '' };
        return { card: card, holo: !!c.holo, serverNew: !!c.new, variant: c.variant || null, serial: c.serial || null };
      });
    } else {
      pulls = CPS.packs.open(set);
    }
    var bc = st.stats.best && set.byId.get(st.stats.best.id);
    var curBest = bc ? CPS.packs.score(bc, st.stats.best.holo) : -1, prevBest = curBest, bestPull = null;
    st.packs--;
    pulls.forEach(function (p) {
      var id = p.card.id, e = st.cards[id];
      p.isNew = server ? p.serverNew : (!(e && e.n) && !seen[id]); seen[id] = 1;
      e = st.cards[id] = e || { n: 0, h: 0 };
      e.n++; if (p.holo) e.h++;
      st.stats.pulled++; if (p.holo) st.stats.holos++;
      st.stats.byRarity[p.card.rarity] = (st.stats.byRarity[p.card.rarity] || 0) + 1;
      var sc = CPS.packs.score(p.card, p.holo);
      if (sc > curBest) { curBest = sc; bestPull = p; st.stats.best = { id: id, holo: p.holo, at: now }; }
      st.recent.unshift({ id: id, holo: p.holo, at: now });
    });
    if (bestPull && prevBest >= 0) bestPull.newBest = true;
    st.recent = st.recent.slice(0, CONFIG.recentMax);
    st.stats.opened++;
    if (server) {
      st.packs = server.packs_left;
      if (server.best) st.stats.best = { id: server.best.id, holo: !!server.best.holo, at: Date.parse(server.best.at) || now };
    }
    save();

    S.opening = { set: set, pulls: pulls, torn: false, revealed: pulls.map(function () { return false; }), finished: false, auto: false };
    refreshQuests();
    $('#stageIdle').classList.add('hidden');
    $('#revealGrid').classList.add('hidden'); $('#revealGrid').innerHTML = '';
    $('#stageControls').classList.add('hidden');
    var sp = $('#stagePack');
    sp.innerHTML = '<div class="pack-wrap">' + CPS.cards.pack(set, 'ready') + '</div><div class="tear-hint">Click the pack to tear it open</div>';
    sp.classList.remove('hidden');
    audio.click();
    renderPacksSide();
    // only scroll when the pack that just appeared is off screen (e.g. opened from the sidebar pack on a phone);
    // tapping the big pack / "Open next pack" leaves the page where it is
    var pr = $('#stagePack .pack').getBoundingClientRect();
    if (pr.top < 0 || pr.bottom > innerHeight) $('#stage').scrollIntoView({ behavior: 'smooth', block: 'start' });
    return true;
  }

  /* Click a pack (the big one in the middle or the one in "Your packs"): open it and tear it in one go. */
  async function openFromPack() {
    var o = S.opening;
    if (S.busy) return;
    if (o && !o.finished) { if (!o.torn) tear(); return; } // a pack is already out: tear it
    if (isLocked()) { showGate({}); return; }
    if (ps().packs <= 0) { toast('Out of packs! Win, earn, or beg for packs and redeem them!', '', 3500); return; }
    if (await startOpen()) { await U.sleep(320); if (S.opening && !S.opening.torn) tear(); }
  }

  async function tear() {
    var o = S.opening;
    if (!o || o.torn) return;
    o.torn = true;
    var pk = $('#stagePack .pack');
    pk.classList.remove('ready'); pk.classList.add('tearing');
    $('#stagePack .tear-hint').classList.add('hidden');
    audio.tear();
    await U.sleep(380);
    var top = pk.querySelector('.pack-top').getBoundingClientRect();
    fx.burst(top.left + top.width / 2, top.bottom, { count: 36, colors: ['#fff', '#ffe9a8', o.set.theme.primary], speed: 7, shape: 'star', size: 2 });
    await U.sleep(420);
    pk.classList.add('gone');
    await U.sleep(260);
    if (S.opening !== o) return;
    $('#stagePack').classList.add('hidden');
    buildGrid(o);
  }

  function buildGrid(o) {
    var grid = $('#revealGrid');
    grid.innerHTML = o.pulls.map(function (p, i) {
      var tease = R.INDEX[p.card.rarity] >= 3 ? ' tease' : '';
      return CPS.cards.render(o.set, p.card, { holo: p.holo, flippable: true, isNew: p.isNew, cls: 'deal' + tease,
        variant: p.variant ? { tier: p.variant, serial: p.serial } : null });
    }).join('');
    $$('.card', grid).forEach(function (el, i) {
      el.dataset.i = i; el.style.animationDelay = (i * 70) + 'ms';
      setTimeout(audio.deal, i * 70);
    });
    grid.classList.remove('hidden');
    $('#stageControls').classList.remove('hidden');
    $('#revealAllBtn').classList.remove('hidden');
    $('#nextPackBtn').classList.add('hidden');
    $('#doneBtn').classList.add('hidden');
    updateSummary();
  }

  function updateSummary() {
    var o = S.opening; if (!o) return;
    var n = o.revealed.filter(Boolean).length;
    if (!o.finished) { $('#stageSummary').innerHTML = 'Click a card to flip it · <b>' + n + ' / ' + o.pulls.length + '</b> revealed'; return; }
    var news = o.pulls.filter(function (p) { return p.isNew; }).length, best = o.pulls[0];
    o.pulls.forEach(function (p) { if (CPS.packs.score(p.card, p.holo) > CPS.packs.score(best.card, best.holo)) best = p; });
    var holos = o.pulls.filter(function (p) { return p.holo; }).length;
    $('#stageSummary').innerHTML = '<b>' + news + '</b> new card' + (news === 1 ? '' : 's') +
      (holos ? ' · <b>' + holos + '</b> holo' : '') +
      ' · Top pull: <b class="rt-' + best.card.rarity + '">' + esc(best.card.name) + (best.holo ? ' ✦' : '') +
      (best.variant ? ' 🌈 #' + best.serial + '/' + CPS.cards.VARIANTS[best.variant].run : '') + '</b> (' + rarityOf(best.card.rarity).label + ')';
  }

  function reveal(i) {
    var o = S.opening;
    if (!o || !o.torn || o.revealed[i]) return;
    o.revealed[i] = true;
    var el = $('#revealGrid').children[i], p = o.pulls[i];
    el.classList.remove('tease'); el.classList.add('flipped');
    audio.flip();
    setTimeout(function () { el.classList.add('glow'); audio.reveal(p.card.rarity); flair(el, p); }, 300);
    if (o.revealed.every(Boolean)) finish(o);
    else updateSummary();
  }

  function flair(el, p) {
    var c = fx.center(el), r = p.card.rarity, col = rarityOf(r).color, isVar = !!p.variant;
    if (isVar) {
      var vt = CPS.cards.VARIANTS[p.variant];
      fx.flash('rgba(255,255,255,.4)', 1000);
      fx.burst(c.x, c.y, { count: 150, colors: ['#ff5f5f', '#ffb21e', '#f7f75f', '#38c97f', '#3f8cff', '#b35cff', '#fff'], speed: 12, shape: 'star', size: 3, life: 90 });
      fx.confetti(220);
      fx.banner('🌈 ' + vt.name.toUpperCase() + ' #' + p.serial + '/' + vt.run + ' 🌈', 'variant', 3200);
      $('#stage').classList.add('shake'); setTimeout(function () { $('#stage').classList.remove('shake'); }, 700);
    }
    if (r === 'rare') fx.burst(c.x, c.y, { count: 22, colors: [col, '#fff'], speed: 5, size: 2.2 });
    else if (r === 'epic') { fx.burst(c.x, c.y, { count: 60, colors: [col, '#fff', '#e3c2ff'], speed: 8, shape: 'star', size: 2.5 }); fx.flash('rgba(179,92,255,.25)', 600); }
    else if (r === 'legendary') {
      fx.flash('rgba(255,178,30,.45)', 900);
      fx.burst(c.x, c.y, { count: 120, colors: [col, '#fff', '#ffe08a'], speed: 11, shape: 'star', size: 3, life: 80 });
      if (!isVar) fx.banner('LEGENDARY!', 'legendary');
      $('#stage').classList.add('shake'); setTimeout(function () { $('#stage').classList.remove('shake'); }, 600);
    } else if (r === 'chase') {
      fx.flash('rgba(255,79,163,.55)', 1200);
      fx.burst(c.x, c.y, { count: 160, colors: ['#ff4fa3', '#ffb21e', '#38c97f', '#3f8cff', '#b35cff', '#fff'], speed: 13, shape: 'star', size: 3.2, life: 90 });
      fx.confetti(240);
      if (!isVar) fx.banner('★ CHASE CARD ★', 'chase', 2800);
      $('#stage').classList.add('shake'); setTimeout(function () { $('#stage').classList.remove('shake'); }, 700);
    }
    if (p.holo) setTimeout(function () { fx.burst(c.x, c.y, { count: 26, colors: ['#fff', '#bff', '#fbf', '#ffb'], speed: 4, shape: 'star', size: 2, gravity: 0 }); }, 120);
    if (p.newBest && R.INDEX[r] >= 2) setTimeout(function () { toast('New best pull: ' + p.card.name + (p.holo ? ' (holo)' : '') + '!', 'good'); }, 500);
  }

  async function revealAll() {
    var o = S.opening;
    if (!o || o.auto) return;
    if (!o.torn) { await tear(); await U.sleep(500); }
    o.auto = true;
    for (var i = 0; i < o.pulls.length; i++) {
      if (S.opening !== o) return;
      if (o.revealed[i]) continue;
      var big = R.INDEX[o.pulls[i].card.rarity] >= 3;
      if (big) await U.sleep(450);
      reveal(i);
      await U.sleep(big ? 900 : 160);
    }
    o.auto = false;
  }

  function finish(o) {
    o.finished = true;
    updateSummary();
    var st = ps(o.set);
    $('#revealAllBtn').classList.add('hidden');
    var nb = $('#nextPackBtn');
    nb.classList.toggle('hidden', !st.packs);
    nb.textContent = 'Open next pack (' + st.packs + ' left)';
    $('#doneBtn').classList.remove('hidden');
    renderPacksSide();
  }

  async function redeem(e) {
    e.preventDefault();
    var input = $('#codeInput'), raw = input.value.trim();
    if (!raw) return;
    if (isLocked()) { showGate({}); return; }
    if (isCloud()) {
      var btn = $('#redeemForm button'); btn.disabled = true;
      try {
        var r = await CPS.cloud.call('redeem_code', { p_code: raw });
        var rs = window.CardSets.get(r.set_id);
        if (rs) ps(rs).packs = r.packs_now;
        input.value = ''; audio.coin();
        var otherSet = r.set_id !== S.set.id, busyOpen = S.opening && !S.opening.finished;
        toast('+' + r.packs + ' pack' + (r.packs === 1 ? '' : 's') + ' added to ' + (r.set_name || r.set_id) + '!' +
          (otherSet && rs ? (busyOpen ? ' Switch sets to open them.' : ' Switched to that set.') : ''), 'good', 4500);
        if (otherSet && rs && !busyOpen) selectSet(r.set_id);
        renderPacksSide(); if (!S.opening) resetStage();
        var cc = fx.center($('#invPack'));
        fx.burst(cc.x, cc.y, { count: 40, colors: ['#ffe08a', '#fff'], speed: 6, shape: 'star', size: 2 });
      } catch (err) {
        input.classList.add('bad'); setTimeout(function () { input.classList.remove('bad'); }, 500);
        cloudError(err);
      } finally { btn.disabled = false; }
      return;
    }
    var res = window.CPSCodes.validate(raw, window.CardSets.ids());
    if (!res) {
      toast("That code isn't valid. Check for typos.", 'error'); audio.error();
      input.classList.add('bad'); setTimeout(function () { input.classList.remove('bad'); }, 500);
      return;
    }
    if (await Store.isCodeRedeemed(res.code)) { toast('That code was already redeemed.', 'warn'); audio.error(); return; }
    var set = window.CardSets.get(res.setId);
    ps(set).packs += res.packs;
    await Store.markCodeRedeemed(res.code, S.player.id);
    await save();
    input.value = '';
    audio.coin();
    var other = set.id !== S.set.id, busy = S.opening && !S.opening.finished;
    toast('+' + res.packs + ' pack' + (res.packs === 1 ? '' : 's') + ' added to ' + set.name + '!' +
      (other ? (busy ? ' Switch sets to open them.' : ' Switched to that set.') : ''), 'good', 4500);
    if (other && !busy) selectSet(set.id);
    renderPacksSide();
    if (!S.opening) resetStage();
    var c = fx.center($('#invPack'));
    fx.burst(c.x, c.y, { count: 40, colors: ['#ffe08a', '#fff', set.theme.primary], speed: 6, shape: 'star', size: 2 });
  }

  async function addFree(n) {
    if (isLocked()) { showGate({}); return; }
    if (isCloud()) {
      if (!isAdmin()) { toast('Free packs need an admin account.', 'warn'); return; }
      if (S.onlineSets.indexOf(S.set.id) < 0) { toast("This set isn't on the server yet. Upload it from the Admin tab first.", 'warn', 5000); return; }
      try { var r = await CPS.cloud.call('admin_grant_packs', { p_set: S.set.id, p_packs: n }); ps().packs = r.packs_now; }
      catch (e) { cloudError(e); return; }
      audio.coin(); toast('+' + n + ' pack' + (n === 1 ? '' : 's') + ' (admin)', 'good', 1500);
      renderPacksSide(); if (!S.opening) resetStage();
      return;
    }
    ps().packs += n; save(); audio.coin();
    toast('+' + n + ' free pack' + (n === 1 ? '' : 's') + ' (dev)', 'good', 1500);
    renderPacksSide();
    if (!S.opening) resetStage();
  }

  /* ---------------------------------------------------------- collection */
  function renderCollection() {
    var set = S.set, st = ps(), f = S.coll;
    var owned = ownedCount(set, st), total = set.cards.length;
    var copies = 0, holoU = 0;
    set.cards.forEach(function (c) { var e = st.cards[c.id]; if (e) { copies += e.n; if (e.h) holoU++; } });
    var pct = total ? owned / total : 0;
    $('#compRing').style.setProperty('--p', (pct * 100).toFixed(1));
    $('#compPct').textContent = (pct * 100 >= 99.95 || pct === 0 ? Math.round(pct * 100) : (pct * 100).toFixed(1)) + '%';
    $('#compTitle').textContent = set.name;
    $('#compSub').textContent = owned + ' / ' + total + ' unique cards · ' + copies + ' total copies · ' + holoU + ' holo';

    $('#rarityProgress').innerHTML = R.RARITIES.filter(function (r) { return set.pools[r.key].length; }).map(function (r) {
      var pool = set.pools[r.key], have = pool.filter(function (c) { return st.cards[c.id] && st.cards[c.id].n; }).length;
      return '<button class="rp r-' + r.key + (f.rarity === r.key ? ' active' : '') + '" data-r="' + r.key + '">' +
        '<span class="rp-top"><span class="rp-name">' + r.label + '</span><span>' + have + '/' + pool.length + '</span></span>' +
        '<span class="bar"><i style="width:' + (have / pool.length * 100).toFixed(1) + '%"></i></span></button>';
    }).join('');

    var sel = $('#collRarity');
    sel.innerHTML = '<option value="">All rarities</option>' + R.RARITIES.filter(function (r) { return set.pools[r.key].length; })
      .map(function (r) { return '<option value="' + r.key + '">' + r.label + '</option>'; }).join('');
    sel.value = f.rarity;

    renderTradein(set, st);
    if (CPS.tickets) CPS.tickets.render();
    if (isCloud() && !S.myVariants) ensureVariants().then(function () {
      if (S.view === 'collection') { renderTradein(set, st); if (CPS.tickets) CPS.tickets.render(); }
    });

    var q = f.q.trim().toLowerCase();
    var numberedIds = null;
    if (f.own === 'numbered') {
      numberedIds = {};
      (S.myVariants || []).forEach(function (v) { if (v.set_id === set.id) numberedIds[v.card_id] = 1; });
    }
    var list = set.cards.filter(function (c) {
      var e = st.cards[c.id], has = e && e.n > 0;
      if (f.rarity && c.rarity !== f.rarity) return false;
      if (f.own === 'numbered' && !numberedIds[c.id]) return false;
      if (f.own === 'owned' && !has) return false;
      if (f.own === 'missing' && has) return false;
      if (f.own === 'dupes' && !(e && e.n > 1)) return false;
      if (f.own === 'holo' && !(e && e.h > 0)) return false;
      if (f.own === 'fav' && !isFav(set.id, c.id)) return false;
      if (q) {
        var hay = (has ? (c.name + ' ' + c.subtitle + ' ' + c.details) : '') + ' #' + U.pad(c.num, set.numWidth) + ' ' + c.num + ' ' + c.rarity;
        if (hay.toLowerCase().indexOf(q) < 0) return false;
      }
      return true;
    });
    var cnt = function (c) { var e = st.cards[c.id]; return e ? e.n : 0; };
    if (f.sort === 'rarity') list.sort(function (a, b) { return R.INDEX[b.rarity] - R.INDEX[a.rarity] || a.num - b.num; });
    else if (f.sort === 'count') list.sort(function (a, b) { return cnt(b) - cnt(a) || a.num - b.num; });
    else if (f.sort === 'name') list.sort(function (a, b) { return a.name.localeCompare(b.name, undefined, { numeric: true }); });

    $('#collCount').textContent = list.length + ' shown';
    $('#collGrid').innerHTML = list.length ? list.map(function (c) {
      var e = st.cards[c.id];
      return CPS.cards.collected(set, c, e ? e.n : 0, e ? e.h : 0);   // card + count pills below it
    }).join('') : '<div class="empty">No cards match these filters.</div>';
    renderVariantsSection(set);
  }

  async function renderVariantsSection(set) {
    var panel = $('#variantsPanel'), grid = $('#variantsGrid'), setId = set.id;
    if (!isCloud()) { panel.classList.add('hidden'); return; }
    var all = await ensureVariants();
    if (!S.set || S.set.id !== setId) return;
    var mine = all.filter(function (v) { return v.set_id === setId; });
    if (!mine.length) { panel.classList.add('hidden'); return; }
    panel.classList.remove('hidden');
    $('#variantsCount').textContent = mine.length + ' numbered ' + (mine.length === 1 ? 'card' : 'cards');
    grid.innerHTML = mine.map(function (v) {
      var card = set.byId.get(v.card_id);
      if (!card) return '';
      return '<div class="coll-item" data-variant-card="' + esc(v.card_id) + '">' +
        CPS.cards.render(set, card, { variant: { tier: v.tier, serial: v.serial } }) +
        '<div class="vserial-cap"><b>' + esc(CPS.cards.VARIANTS[v.tier].name) + ' #' + v.serial + '/' + CPS.cards.VARIANTS[v.tier].run + '</b></div></div>';
    }).join('');
    grid.querySelectorAll('[data-variant-card]').forEach(function (el) {
      el.addEventListener('click', function () { openCardModal(set.id, el.dataset.variantCard); });
    });
  }

  /* ---------------------------------------------------- dupe trade-in */
  var DUPE_TIERS = [
    { tier: 'common', rate: 15, label: 'Common' },
    { tier: 'uncommon', rate: 10, label: 'Uncommon' },
    { tier: 'rare', rate: 5, label: 'Rare' },
    { tier: 'epic', rate: 3, label: 'Epic+' }
  ];
  var DUPE_RARS = { common: ['common'], uncommon: ['uncommon'], rare: ['rare'], epic: ['epic', 'legendary', 'chase'] };
  /* Tradable dupes per tier: every copy beyond the first of each card. */
  /* Numbered variant copies are never tradable (cloud only; guests have none). */
  function variantCountMap() {
    var m = {};
    (S.myVariants || []).forEach(function (v) {
      var k = v.set_id + ':' + v.card_id;
      m[k] = (m[k] || 0) + 1;
    });
    return m;
  }
  function dupeCounts(set, st, vmap) {
    var out = { common: 0, uncommon: 0, rare: 0, epic: 0 };
    set.cards.forEach(function (c) {
      var e = st.cards[c.id];
      if (!e || !e.n) return;
      var t = c.rarity === 'common' ? 'common' : c.rarity === 'uncommon' ? 'uncommon' : c.rarity === 'rare' ? 'rare' : 'epic';
      var v = vmap ? (vmap[set.id + ':' + c.id] || 0) : 0;
      out[t] += Math.max(0, e.n - Math.max(1, v));
    });
    return out;
  }
  function renderTradein(set, st) {
    var counts = dupeCounts(set, st, isCloud() ? variantCountMap() : null);
    $('#tradeinRows').innerHTML = DUPE_TIERS.map(function (t) {
      var n = counts[t.tier], trades = Math.floor(n / t.rate);
      return '<div class="tradein-row">' +
        '<span class="pill r-' + (t.tier === 'epic' ? 'epic' : t.tier) + '">' + t.label + '</span>' +
        '<span class="tradein-mid"><b>' + n + '</b><span class="muted">/' + t.rate + '</span> dupes <span class="muted">&rarr;</span> <b>' + trades + '</b> pack' + (trades === 1 ? '' : 's') + '</span>' +
        '<button class="btn small" data-trade="' + t.tier + '"' + (trades < 1 ? ' disabled' : '') + '>Trade</button>' +
        '</div>';
    }).join('');
  }
  async function tradeDupes(tier) {
    var set = S.set, t = null;
    DUPE_TIERS.forEach(function (x) { if (x.tier === tier) t = x; });
    if (!t) return;
    var msg = function (used, trades) {
      toast('Traded ' + used + ' dupes for ' + trades + ' pack' + (trades === 1 ? '' : 's') + '!', 'good');
      audio.coin();
    };
    if (isCloud()) {
      try {
        var r = await CPS.cloud.call('trade_dupes', { p_set: set.id, p_tier: tier });
        msg(r.dupes_used, r.trades);
        await refreshCloud();
      } catch (e) { cloudError(e); }
      return;
    }
    var st = ps(set), trades = Math.floor(dupeCounts(set, st)[tier] / t.rate);
    if (trades < 1) { toast('Not enough duplicate cards.', 'warn'); return; }
    var need = trades * t.rate, rars = DUPE_RARS[tier];
    set.cards.forEach(function (c) {
      if (need <= 0 || rars.indexOf(c.rarity) < 0) return;
      var e = st.cards[c.id];
      if (!e || e.n <= 1) return;
      var h = e.h || 0, takeNh, takeH;
      if (h > 0) takeNh = Math.min(e.n - h, need);            /* all non-holos expendable */
      else takeNh = Math.min(Math.max(e.n - 1, 0), need);     /* keep one */
      need -= takeNh;
      takeH = h > 0 ? Math.min(h - 1, need) : 0;               /* keep one holo */
      need -= takeH;
      e.n -= (takeNh + takeH);
      e.h = h - takeH;
      if (e.n <= 0) delete st.cards[c.id];
    });
    st.packs += trades;
    await save();
    msg(trades * t.rate, trades);
    refreshQuests();
    renderCollection();
    renderPacksSide();
  }

  /* ---------------------------------------------------- collapsible panels */
  var COLLAPSE_KEY = 'cps_collapsed_panels';
  function collapsedPanels() {
    try { return JSON.parse(localStorage.getItem(COLLAPSE_KEY) || '{}'); } catch (e) { return {}; }
  }
  function saveCollapsed(s) { try { localStorage.setItem(COLLAPSE_KEY, JSON.stringify(s)); } catch (e) {} }
  function initCollapsible() {
    var saved = collapsedPanels();
    $$('.panel.collapsible').forEach(function (p) {
      if (!p.id) return;
      var h = p.querySelector('h2'); if (!h) return;
      if (h.querySelector('.collapse-btn')) return;
      h.appendChild(U.h('<button class="collapse-btn" type="button" aria-label="Collapse panel">\u25BE</button>'));
      if (saved[p.id]) p.classList.add('collapsed');
    });
  }

  /* ---------------------------------------------------------- favorites */
  var FAV_MAX = 20;
  function favKey(setId, cardId) { return setId + ':' + cardId; }
  function isFav(setId, cardId) {
    if (isCloud()) return !!(S.favorites && S.favorites[favKey(setId, cardId)]);
    var p = S.player; return !!(p && p.favs && p.favs.indexOf(favKey(setId, cardId)) >= 0);
  }
  function favCount() {
    if (isCloud()) return S.favorites ? Object.keys(S.favorites).length : 0;
    var p = S.player; return p && p.favs ? p.favs.length : 0;
  }
  async function toggleFavorite(setId, cardId, holo) {
    var k = favKey(setId, cardId), already = isFav(setId, cardId);
    if (!already && favCount() >= FAV_MAX) { toast('You can only favorite ' + FAV_MAX + ' cards.', 'warn'); return; }
    if (isCloud()) {
      try {
        var r = await CPS.cloud.call('toggle_favorite', { p_set: setId, p_card: cardId });
        if (r.favorited) S.favorites[k] = true; else delete S.favorites[k];
        toast(r.favorited ? 'Added to favorites (' + r.count + '/' + FAV_MAX + ').' : 'Removed from favorites.', 'good');
      } catch (e) { cloudError(e); return; }
    } else {
      var p = S.player; p.favs = p.favs || [];
      var ix = p.favs.indexOf(k);
      if (ix >= 0) p.favs.splice(ix, 1); else p.favs.push(k);
      await save();
      toast(ix >= 0 ? 'Removed from favorites.' : 'Added to favorites (' + p.favs.length + '/' + FAV_MAX + ').', 'good');
    }
    openCardModal(setId, cardId, holo); // re-render the modal button
    if (S.view === 'collection') renderCollection();
  }

  /* ---------------------------------------------------------- players */
  async function renderPlayers() {
    var box = $('#playerList');
    if (!isCloud()) {
      box.innerHTML = '<div class="empty">Log in to see the other players.</div>';
      $('#tradePanel').classList.add('hidden');
      return;
    }
    $('#tradePanel').classList.remove('hidden');
    box.innerHTML = '<div class="muted small">Loading…</div>';
    $('#tradeList').innerHTML = '<div class="muted small">Loading…</div>';
    try {
      var players = await CPS.cloud.call('list_players');
      var trades = await CPS.cloud.call('list_trades');
      renderTrades(trades);
      box.innerHTML = players.map(function (p) {
        return '<button class="player-card" data-player="' + esc(p.id) + '">' +
          '<span class="avatar">' + esc((p.display_name[0] || 'P').toUpperCase()) + '</span>' +
          '<span class="player-meta"><span class="player-name-row"><b>' + esc(p.display_name) + '</b>' +
          (p.is_me ? '<span class="pill pill-you">You</span>' : '') + '</span>' +
          '<span class="muted small">' + p.favorites + ' favorites · ' + p.unique_cards + ' unique cards</span></span>' +
          '<span class="player-go">›</span></button>';
      }).join('') || '<div class="empty">No players yet.</div>';
    } catch (e) { cloudError(e); }
  }
  /* ---------------------------------------------------------- notifications */
  var NOTIF_KIND_ICON = { gift_card: '🎁', gift_pack: '📦', gift_spin: '🎟️',
    trade_offer: '⇄', trade_accepted: '✅', trade_declined: '❌', variant_pull: '🌈', chase_pull: '🎯' };

  async function refreshNotifBadge() {
    if (!isCloud()) return;
    try {
      var n = await CPS.cloud.call('list_notifications');
      var b = $('#notifBadge');
      b.textContent = n.unread > 99 ? '99+' : n.unread;
      b.classList.toggle('hidden', !n.unread);
    } catch (e) { /* silent: badge just stays as-is */ }
  }

  function notifTime(iso) {
    var ms = Date.now() - new Date(iso).getTime();
    if (ms < 0) ms = 0;
    var m = Math.floor(ms / 60000);
    if (m < 1) return 'just now';
    if (m < 60) return m + 'm ago';
    var hh = Math.floor(m / 60);
    if (hh < 24) return hh + 'h ago';
    var d = Math.floor(hh / 24);
    if (d < 7) return d + 'd ago';
    try { return new Date(iso).toLocaleDateString(undefined, { month: 'short', day: 'numeric' }); }
    catch (e) { return ''; }
  }

  async function openNotifications() {
    openModal('<div class="muted" style="padding:24px">Loading…</div>');
    try {
      var n = await CPS.cloud.call('list_notifications');
      var items = n.items || [];
      openModal('<button class="modal-x" data-close aria-label="Close">×</button><div class="profile">' +
        '<h2>Notifications</h2>' +
        (items.length ? '<div class="notif-list">' + items.map(function (it) {
          return '<button class="notif' + (it.read ? '' : ' unread') + '" data-notif="' + it.id + '"' +
            (it.view ? ' data-view="' + esc(it.view) + '"' : '') + '>' +
            '<span class="notif-icon">' + (NOTIF_KIND_ICON[it.kind] || '🔔') + '</span>' +
            '<span class="notif-text">' + esc(it.text) +
            '<span class="notif-time">' + notifTime(it.created_at) + '</span></span></button>';
        }).join('') + '</div><div class="notif-actions"><button class="btn small" id="notifReadAll">Mark all read</button>' +
        (items.some(function (it) { return it.read; }) ? '<button class="btn small" id="notifClearRead">Clear read</button>' : '') + '</div>'
        : '<div class="empty">No notifications yet.</div>') +
        '</div>', function (box) {
          box.querySelectorAll('.notif').forEach(function (el) {
            el.addEventListener('click', async function () {
              var id = el.dataset.notif, view = el.dataset.view;
              try { await CPS.cloud.call('read_notifications', { p_ids: [id] }); } catch (e) {}
              el.classList.remove('unread');
              refreshNotifBadge();
              if (view) { closeModal(); showView(view); }
            });
          });
          var ra = box.querySelector('#notifReadAll');
          if (ra) ra.addEventListener('click', async function () {
            try { await CPS.cloud.call('read_notifications', {}); } catch (e) { cloudError(e); return; }
            refreshNotifBadge();
            openNotifications();
          });
          var cr = box.querySelector('#notifClearRead');
          if (cr) cr.addEventListener('click', async function () {
            try { await CPS.cloud.call('clear_notifications', {}); } catch (e) { cloudError(e); return; }
            openNotifications();
          });
        });
    } catch (e) { closeModal(true); cloudError(e); }
  }

  /* ---------------------------------------------------------- gifting */
  async function openGiftModal(setId, cardId) {
    var set = window.CardSets.get(setId), card = set && set.byId.get(cardId);
    if (!set || !card) return;
    var st = tbStateOf(set), e = st.cards[card.id];
    if (!e || !e.n) return;
    openModal('<div class="muted" style="padding:24px">Loading…</div>');
    try {
      var players = await CPS.cloud.call('list_players');
      var others = players.filter(function (p) { return !p.is_me; });
      if (!others.length) {
        openModal('<button class="modal-x" data-close aria-label="Close">×</button><div class="empty" style="padding:24px">No other players to gift to yet.</div>');
        return;
      }
      var holoOnly = e.h >= e.n;            // every owned copy is holo
      var canChoose = e.h > 0 && e.h < e.n;  // owns both kinds
      var holo = holoOnly;
      await ensureVariants();
      var serials = myVariantSerials(setId, cardId);
      var regulars = e.n - serials.length;
      function copyPickerHtml() {
        if (!serials.length) return '';
        var opts = serials.map(function (v, i) {
          var vt = CPS.cards.VARIANTS[v.tier];
          return '<label class="check"><input type="radio" name="giftCopy" value="' + v.id + '"' +
            (regulars <= 0 && i === 0 ? ' checked' : '') + '> ' + vt.name + ' #' + v.serial + '/' + vt.run + '</label>';
        }).join('');
        if (regulars > 0) opts = '<label class="check"><input type="radio" name="giftCopy" value="" checked> Regular copy</label>' + opts;
        return '<div class="gift-copies"><span class="fld-label">Which copy?</span>' + opts + '</div>';
      }
      function showForm() {
        openModal('<button class="modal-x" data-close aria-label="Close">×</button><div class="gift-modal">' +
          '<h2>🎁 Gift card</h2>' +
          '<div class="trade-card">' + CPS.cards.render(set, card, { holo: holoOnly }) +
          '<div class="trade-cap"><b>' + esc(card.name) + '</b><span class="muted small">' + esc(set.name) +
          ' · you own ' + e.n + (e.h ? ' (' + e.h + ' holo)' : '') + '</span></div></div>' +
          '<label>To<select id="giftTo">' + others.map(function (p) {
            return '<option value="' + esc(p.id) + '">' + esc(p.display_name) + '</option>';
          }).join('') + '</select></label>' +
          (canChoose ? '<label class="inline"><input type="checkbox" id="giftHolo"> Holographic copy</label>' :
           holoOnly ? '<div class="muted small">Holographic copy</div>' : '') +
          (e.n === 1 ? '<div class="warn-box">This is your last copy — you’ll no longer own this card.</div>' : '') +
          copyPickerHtml() +
          '<div class="gift-actions"><button class="btn primary" id="giftNextBtn">Continue</button></div></div>');
        var hb = $('#giftHolo');
        if (hb) hb.addEventListener('change', function () { holo = this.checked; });
        $('#giftNextBtn').addEventListener('click', function () {
          var toId = $('#giftTo').value;
          var to = others.filter(function (p) { return p.id === toId; })[0];
          var picked = box_query('input[name=giftCopy]:checked');
          var vid = picked ? picked.value || null : null;
          var vtext = null;
          if (vid) { var vv = serials.filter(function (s) { return s.id === vid; })[0];
            if (vv) vtext = CPS.cards.VARIANTS[vv.tier].name + ' #' + vv.serial + '/' + CPS.cards.VARIANTS[vv.tier].run; }
          showConfirm(toId, to ? to.display_name : '', holo, vid, vtext);
        });
        function box_query(sel) { return document.querySelector('#modal ' + sel); }
      }
      function showConfirm(toId, toName, isHolo, variantId, variantText) {
        openModal('<button class="modal-x" data-close aria-label="Close">×</button><div class="gift-modal">' +
          '<h2>Confirm gift</h2>' +
          '<p>Gift <b>' + esc(card.name) + '</b>' + (variantText ? ' (' + esc(variantText) + ')' : (isHolo ? ' ✦ holo' : '')) +
          ' to <b>' + esc(toName) + '</b>?</p>' +
          '<div class="gift-actions"><button class="btn" id="giftBackBtn">Back</button>' +
          '<button class="btn primary" id="giftConfirmBtn">Send gift</button></div></div>');
        $('#giftBackBtn').addEventListener('click', showForm);
        $('#giftConfirmBtn').addEventListener('click', async function () {
          var btn = this; btn.disabled = true;
          try {
            await CPS.cloud.call('gift_card', { p_to: toId, p_set: setId, p_card: cardId, p_holo: isHolo, p_variant_id: variantId || null });
            S.myVariants = null; refreshQuests();
            closeModal();
            toast('🎁 Gift sent to ' + toName + '!');
            if (S.view === 'collection') renderCollection();
          } catch (err) { cloudError(err); btn.disabled = false; }
        });
      }
      showForm();
    } catch (e2) { closeModal(true); cloudError(e2); }
  }

  /* ---------------------------------------------------------- variants */
  var VARIANT_ORDER = ['oneofone', 'obsidian', 'prism', 'rainbow'];

  async function ensureVariants() {
    if (!isCloud()) return [];
    if (!S.myVariants) {
      try { S.myVariants = await CPS.cloud.call('list_variants', {}); }
      catch (e) { S.myVariants = []; }
    }
    return S.myVariants;
  }
  async function ensureCensus(setId) {
    if (!isCloud()) return {};
    S.variantCensus = S.variantCensus || {};
    if (!S.variantCensus[setId]) {
      try { S.variantCensus[setId] = await CPS.cloud.call('variant_census', { p_set: setId }); }
      catch (e) { S.variantCensus[setId] = {}; }
    }
    return S.variantCensus[setId];
  }
  function myVariantSerials(setId, cardId) {
    return (S.myVariants || []).filter(function (v) { return v.set_id === setId && v.card_id === cardId; })
      .sort(function (a, b) { return a.serial - b.serial; });
  }
  async function fillCensus(box, set, card) {
    var el = box.querySelector('#vcensus');
    if (!el || !isCloud() || R.INDEX[card.rarity] < 2) return;   // variants are rare+
    var census = await ensureCensus(set.id);
    if (!box.isConnected) return;
    var c = census[card.id] || { rainbow: 0, prism: 0, obsidian: 0, oneofone: 0, oneofone_by: null };
    var rows = VARIANT_ORDER.map(function (t) {
      var vt = CPS.cards.VARIANTS[t];
      if (t === 'oneofone') {
        return '<div class="vc-row"><span>One-of-one variant</span><span class="vc-n ' + (c.oneofone_by ? 'vc-done' : '') + '">' +
          (c.oneofone_by ? 'found by <b>' + esc(c.oneofone_by) + '</b>' : 'not found') + '</span></div>';
      }
      var n = c[t] || 0;
      return '<div class="vc-row"><span>' + vt.name + ' variants</span><span class="vc-n ' + (n >= vt.run ? 'vc-done' : '') + '">' +
        n + '/' + vt.run + ' found</span></div>';
    }).join('');
    var mine = myVariantSerials(set.id, card.id);
    if (mine.length) {
      rows += '<div class="vc-row"><span>Your serials</span><span class="vc-mine">' +
        mine.map(function (v) { return CPS.cards.VARIANTS[v.tier].name + ' #' + v.serial; }).join(', ') + '</span></div>';
    }
    el.innerHTML = rows;
    el.style.display = '';
  }

  /* ---------------------------------------------------------- trading */
  var TB = null; // trade builder state

  // read-only view of my per-set state (ps() would create+save missing entries)
  function tbStateOf(set) { return S.player.sets[set.id] || { cards: {} }; }

  // my owned cards as flat [{set_id, card_id, n, h}]
  function tbMyCollection() {
    var out = [];
    window.CardSets.all().forEach(function (set) {
      var st = tbStateOf(set);
      set.cards.forEach(function (card) {
        var e = st.cards[card.id];
        if (e && e.n > 0) out.push({ set_id: set.id, card_id: card.id, n: e.n, h: e.h || 0 });
      });
    });
    return out;
  }

  // group a flat collection into [{set, cards:[{card,n,h}]}] sorted by set name
  function tbGroup(coll) {
    var bySet = {};
    coll.forEach(function (c) {
      var set = window.CardSets.get(c.set_id), card = set && set.byId.get(c.card_id);
      if (!set || !card) return;
      var g = bySet[set.id] || (bySet[set.id] = { set: set, cards: [] });
      g.cards.push({ card: card, n: c.n, h: c.h || 0 });
    });
    return Object.keys(bySet).map(function (k) { return bySet[k]; })
      .sort(function (a, b) { return a.set.name.localeCompare(b.set.name); });
  }


  function tradeMiniCard(setId, cardId, holo, qty) {
    var set = window.CardSets.get(setId), card = set && set.byId.get(cardId);
    if (!set || !card) return '<span class="muted">?</span>';
    return '<div class="trade-card">' + CPS.cards.render(set, card, { holo: !!holo }) +
      '<div class="trade-cap"><b>' + esc(card.name) + (qty > 1 ? ' \u00d7' + qty : '') + '</b>' +
      '<span class="muted small">' + esc(set.name) + (holo ? ' \u00b7 \u2726 holo' : '') + '</span></div></div>';
  }
  function tradeItemsHtml(items) {
    return '<div class="trade-items">' + (items || []).map(function (it) {
      return tradeMiniCard(it.set_id, it.card_id, it.holo, it.qty);
    }).join('') + '</div>';
  }

  function tradeTimeLeft(expiresAt) {
    var ms = new Date(expiresAt).getTime() - Date.now();
    if (ms <= 0) return 'expired';
    var d = Math.floor(ms / 864e5);
    if (d >= 1) return d + (d === 1 ? ' day' : ' days') + ' left';
    var h = Math.floor(ms / 36e5);
    return (h >= 1 ? h + 'h' : Math.max(1, Math.floor(ms / 6e4)) + 'm') + ' left';
  }

  function tradeRowHtml(t, isHistory) {
    var leftCap = t.direction === 'incoming' ? 'You get' : 'You give';
    var rightCap = t.direction === 'incoming' ? 'You give' : 'You get';
    var nGive = (t.direction === 'incoming' ? t.want_items : t.offer_items || []).reduce(function (s, it) { return s + (it.qty || 1); }, 0);
    var nGet = (t.direction === 'incoming' ? t.offer_items : t.want_items || []).reduce(function (s, it) { return s + (it.qty || 1); }, 0);
    var head = t.direction === 'incoming'
      ? '<b>' + esc(t.other_name) + '</b> offers you a trade'
      : 'You offered <b>' + esc(t.other_name) + '</b> a trade';
    head += ' <span class="muted small">\u00b7 ' + nGive + ' for ' + nGet;
    head += isHistory
      ? (t.decided_at ? ' \u00b7 ' + tradeDate(t.decided_at) : '') + '</span>'
      : ' \u00b7 ' + tradeTimeLeft(t.expires_at) + '</span>';
    var actions;
    if (!isHistory && t.status === 'pending') {
      actions = t.direction === 'incoming'
        ? '<button class="btn small primary" data-trade-accept="' + t.id + '">Accept</button>' +
          '<button class="btn small" data-trade-decline="' + t.id + '">Decline</button>'
        : '<button class="btn small" data-trade-cancel="' + t.id + '">Cancel offer</button>';
    } else {
      actions = '<span class="pill st-' + t.status + '">' + esc(t.status) + '</span>';
    }
    return '<div class="trade-row"><div class="trade-head">' + head + '</div>' +
      '<div class="trade-cards"><div class="trade-side"><span class="trade-cap-top">' + leftCap + '</span>' +
      tradeItemsHtml(t.offer_items) + '</div>' +
      '<span class="trade-swap">\u21c4</span><div class="trade-side"><span class="trade-cap-top">' + rightCap + '</span>' +
      tradeItemsHtml(t.want_items) + '</div></div>' +
      '<div class="trade-actions">' + actions + '</div></div>';
  }

  function tradeDate(iso) {
    try { return new Date(iso).toLocaleDateString(undefined, { month: 'short', day: 'numeric' }); }
    catch (e) { return ''; }
  }

  function renderTrades(trades) {
    S.trades = trades;
    var pending = trades.filter(function (t) { return t.status === 'pending'; });
    var decided = trades.filter(function (t) { return t.status !== 'pending'; });
    var incoming = pending.filter(function (t) { return t.direction === 'incoming'; }).length;
    var badge = $('#playersBadge');
    badge.textContent = incoming;
    badge.classList.toggle('hidden', !incoming);
    $('#tradeList').innerHTML = pending.length
      ? pending.map(function (t) { return tradeRowHtml(t, false); }).join('')
      : '<div class="empty">No pending offers.</div>';
    var hb = $('#tradeHistBtn');
    hb.innerHTML = 'Trade history' + (decided.length ? ' (' + decided.length + ')' : '');
  }

  function renderTradeHistory() {
    var decided = (S.trades || []).filter(function (t) { return t.status !== 'pending'; });
    $('#tradeHistList').innerHTML = decided.length
      ? decided.map(function (t) { return tradeRowHtml(t, true); }).join('')
      : '<div class="empty">No trade history yet.</div>';
    window.scrollTo(0, 0);
  }

  async function respondTrade(id, accept) {
    try {
      await CPS.cloud.call('respond_trade', { p_offer: id, p_accept: accept });
      S.myVariants = null; refreshQuests();
      toast(accept ? 'Trade complete! Cards swapped.' : 'Offer declined.');
      renderPlayers();
    } catch (e) { cloudError(e); }
  }

  async function cancelTrade(id) {
    if (!confirm('Cancel this trade offer?')) return;
    try {
      await CPS.cloud.call('cancel_trade', { p_offer: id });
      toast('Offer cancelled.');
      renderPlayers();
    } catch (e) { cloudError(e); }
  }

  /* ------------------------------------------------- trade builder view */
  async function openTradeBuilder(prefillTo) {
    if (!isCloud()) return;
    openModal('<div class="muted" style="padding:24px">Loading…</div>');
    try {
      var players = await CPS.cloud.call('list_players');
      var others = players.filter(function (p) { return !p.is_me; });
      if (!others.length) {
        openModal('<button class="modal-x" data-close aria-label="Close">\u00d7</button><div class="empty" style="padding:24px">No other players to trade with yet.</div>');
        return;
      }
      var to = prefillTo && others.some(function (p) { return p.id === prefillTo; }) ? prefillTo : others[0].id;
      TB = { to: to, step: 1, their: [], toName: '', setId: '', q: '', rarity: '',
             picks: [], offer: [], want: [], myColl: tbMyCollection() };
      await ensureVariants();
      $('#tradeWithSel').innerHTML = others.map(function (p) {
        return '<option value="' + esc(p.id) + '"' + (p.id === to ? ' selected' : '') + '>' + esc(p.display_name) + '</option>';
      }).join('');
      $('#tradeRarity').innerHTML = '<option value="">All rarities</option>' + R.RARITIES.map(function (r) {
        return '<option value="' + r.key + '">' + r.label + '</option>';
      }).join('');
      $('#tradeSearch').value = '';
      closeModal();
      await tbLoadTheir();
      showView('trade');
    } catch (e) { closeModal(true); cloudError(e); }
  }

  async function tbLoadTheir() {
    try {
      var p = await CPS.cloud.call('get_profile', { p_account: TB.to });
      TB.their = p.collection || [];
      TB.toName = p.display_name;
    } catch (e) { TB.their = []; TB.toName = ''; cloudError(e); }
    TB.step = 1; TB.picks = []; TB.offer = []; TB.want = [];
    TB.setId = ''; TB.q = ''; TB.rarity = '';
    $('#tradeSearch').value = '';
    renderTradeBuilder();
  }

  function renderTradeBuilder() {
    if (!TB) return;
    var steps = ['Your offer', TB.toName ? 'Pick from ' + TB.toName : 'Their card', 'Review'];
    $('#tradeSteps').innerHTML = steps.map(function (s, i) {
      var n = i + 1;
      return '<span class="tstep' + (n === TB.step ? ' active' : n < TB.step ? ' done' : '') + '">' + n + '. ' + esc(s) + '</span>';
    }).join('');
    $('#tradeTitle').textContent = TB.step === 1 ? 'Choose your offer' : TB.step === 2 ? 'Choose what you want' : 'Review trade';
    $('#tradeReview').classList.add('hidden');
    $('#tradeGrid').classList.remove('hidden');
    if (TB.step === 3) {
      renderTradeReview();
      return;
    }
    $('#tradeFilters').classList.remove('hidden');
    var groups = TB.step === 1 ? tbGroup(TB.myColl) : tbGroup(TB.their);
    $('#tradeSetSel').innerHTML = '<option value="">All sets</option>' + groups.map(function (g) {
      return '<option value="' + esc(g.set.id) + '"' + (g.set.id === TB.setId ? ' selected' : '') + '>' +
        esc(g.set.name) + ' (' + g.cards.length + ')</option>';
    }).join('');
    tbRenderGrid(groups);
  }

  function tbRenderGrid(groups) {
    groups = groups || (TB.step === 1 ? tbGroup(TB.myColl) : tbGroup(TB.their));
    var q = TB.q.trim().toLowerCase(), list = [];
    groups.forEach(function (g) {
      if (TB.setId && g.set.id !== TB.setId) return;
      g.cards.forEach(function (c) {
        if (TB.rarity && c.card.rarity !== TB.rarity) return;
        if (q) {
          var hay = '#' + U.pad(c.card.num, g.set.numWidth) + ' ' + c.card.num + ' ' + c.card.name + ' ' + (c.card.subtitle || '');
          if (hay.toLowerCase().indexOf(q) < 0) return;
        }
        list.push({ set: g.set, card: c.card, n: c.n, h: c.h });
      });
    });
    list.sort(function (a, b) {
      return a.set.name < b.set.name ? -1 : a.set.name > b.set.name ? 1 : a.card.num - b.card.num;
    });
    $('#tradeCount').textContent = list.length + ' shown';
    $('#tradeGrid').innerHTML = list.length ? list.map(function (it) {
      var sel = TB.picks.some(function (p) { return p.setId === it.set.id && p.cardId === it.card.id; });
      return '<button class="trade-pick' + (sel ? ' selected' : '') + '" data-set="' + esc(it.set.id) +
        '" data-card="' + esc(it.card.id) + '">' + CPS.cards.collected(it.set, it.card, it.n, it.h) + '</button>';
    }).join('') : '<div class="empty">' + (TB.step === 1 ? 'You don\'t own any cards yet.' : esc(TB.toName) + ' doesn\'t own any cards yet.') + '</div>';
    tbRenderDock();
  }

  function pickTravelVariant(p) {
    var s = myVariantSerials(p.setId, p.cardId);
    return s.length ? { tier: s[0].tier, serial: s[0].serial } : null;
  }
  function tbRenderDock() {
    var dock = $('#tradeDock');
    if (TB.step === 3 || !TB.picks.length) { dock.classList.add('hidden'); return; }
    dock.classList.remove('hidden');
    $('#tradeChips').innerHTML = TB.picks.map(function (p, i) {
      var set = window.CardSets.get(p.setId), card = set && set.byId.get(p.cardId);
      if (!set || !card) return '';
      var tv = TB.step === 1 ? pickTravelVariant(p) : null;
      return '<span class="trade-chip"><b>' + esc(card.name) + '</b>' +
        (tv ? '<span class="chip-variant" title="' + esc(CPS.cards.variantLabel(tv.tier, tv.serial)) + ' travels with this card">' + RB + ' #' + tv.serial + '</span>' : '') +
        (p.h > 0 ? '<button class="chip-holo' + (p.holo ? ' on' : '') + '" data-chip-holo="' + i + '" title="Toggle holographic">\u2726</button>' : '') +
        '<button class="chip-x" data-chip-x="' + i + '" title="Remove">\u00d7</button></span>';
    }).join('');
    $('#tradeContinueBtn').innerHTML = (TB.step === 1 ? 'Continue \u2192 pick their card' : 'Continue \u2192 review') +
      ' (' + TB.picks.length + '/10)';
  }

  function tbContinue() {
    if (!TB || !TB.picks.length || TB.step === 3) return;
    if (TB.step === 1) { TB.offer = TB.picks; TB.step = 2; } else { TB.want = TB.picks; TB.step = 3; }
    TB.picks = []; TB.setId = ''; TB.q = ''; TB.rarity = '';
    $('#tradeSearch').value = '';
    renderTradeBuilder();
    window.scrollTo(0, 0);
  }

  function renderTradeReview() {
    $('#tradeFilters').classList.add('hidden');
    $('#tradeGrid').classList.add('hidden');
    $('#tradeDock').classList.add('hidden');
    function cardsHtml(picks, mine) {
      return '<div class="trade-review-cards">' + picks.map(function (p) {
        var set = window.CardSets.get(p.setId), card = set && set.byId.get(p.cardId);
        if (!set || !card) return '';
        var tv = mine ? pickTravelVariant(p) : null;
        return '<div class="trade-card">' + CPS.cards.render(set, card, { holo: p.holo, variant: tv }) +
          '<div class="trade-cap"><b>' + esc(card.name) + '</b><span class="muted small">' + esc(set.name) +
          (p.holo ? ' \u00b7 \u2726 holo' : '') +
          (tv ? ' \u00b7 ' + RB + ' #' + tv.serial + '/' + CPS.cards.VARIANTS[tv.tier].run : '') + '</span></div></div>';
      }).join('') + '</div>';
    }
    var box = $('#tradeReview');
    box.classList.remove('hidden');
    box.innerHTML = '<div class="trade-review-group"><span class="trade-cap-top">You give (' + TB.offer.length + ')</span>' +
      cardsHtml(TB.offer, true) + '</div>' +
      '<div class="trade-review-swap">\u21c4</div>' +
      '<div class="trade-review-group"><span class="trade-cap-top">You get (' + TB.want.length + ')</span>' +
      cardsHtml(TB.want) + '</div>' +
      '<div class="trade-review-actions"><button class="btn" id="tradeStartOver">Start over</button>' +
      '<button class="btn primary" id="tradeSendBtn">Send offer to ' + esc(TB.toName) + '</button></div>';
    $('#tradeStartOver').addEventListener('click', function () {
      TB.step = 1; TB.offer = []; TB.want = []; TB.picks = [];
      renderTradeBuilder(); window.scrollTo(0, 0);
    });
    $('#tradeSendBtn').addEventListener('click', async function () {
      var btn = this; btn.disabled = true;
      try {
        await CPS.cloud.call('propose_trade', {
          p_to: TB.to,
          p_offer: TB.offer.map(function (p) { return { set: p.setId, card: p.cardId, holo: p.holo }; }),
          p_want: TB.want.map(function (p) { return { set: p.setId, card: p.cardId, holo: p.holo }; })
        });
        toast('Trade offer sent to ' + TB.toName + '!');
        showView('players');
      } catch (e) { cloudError(e); btn.disabled = false; }
    });
  }


  async function openProfile(accountId) {
    openModal('<div class="muted" style="padding:24px">Loading…</div>');
    try {
      var p = await CPS.cloud.call('get_profile', { p_account: accountId });
      var favs = (p.favorites || []).map(function (f) {
        var set = window.CardSets.get(f.set_id), card = set && set.byId.get(f.card_id);
        if (!set || !card) return '';
        return '<div class="prof-fav">' + CPS.cards.render(set, card, { holo: !!f.holo }) +
          '<div class="prof-fav-cap"><b>' + esc(card.name) + '</b>' +
          '<span class="muted small">' + esc(set.name) + ' · ' + rarityOf(card.rarity).label + '</span></div></div>';
      }).join('');
      var sets = (p.sets || []).map(function (s) {
        var pct = s.total ? (s.unique / s.total * 100) : 0;
        return '<div class="prof-set" data-pset="' + esc(s.set_id) + '"><div class="prof-set-top"><span>' + esc(s.set_name) + '</span>' +
          '<span class="muted small">' + s.unique + '/' + s.total + '</span></div>' +
          '<span class="bar"><i style="width:' + pct.toFixed(1) + '%"></i></span></div>';
      }).join('');
      openModal('<button class="modal-x" data-close aria-label="Close">×</button><div class="profile">' +
        '<div class="prof-head"><span class="avatar big">' + esc((p.display_name[0] || 'P').toUpperCase()) + '</span>' +
        '<div><h2>' + esc(p.display_name) + '</h2>' + (p.is_me ? '<span class="pill pill-you">You</span>' : '<button class="btn small" id="profTradeBtn">Propose trade</button>') + '</div></div>' +
        '<h3>★ Favorites (' + (p.favorites || []).length + '/' + FAV_MAX + ')</h3>' +
        (favs ? '<div class="prof-favs">' + favs + '</div>' : '<div class="empty">No favorites yet.</div>') +
        '<h3>Collection</h3><div class="prof-sets">' + (sets || '<div class="empty">—</div>') + '</div>' +
        '</div>', function (box) {
        box.querySelectorAll('.prof-set').forEach(function (el) {
          el.addEventListener('click', function () {
            openPlayerSet(accountId, p.display_name, el.dataset.pset, p.collection || []);
          });
        });
        var ptb = box.querySelector('#profTradeBtn');
        if (ptb) ptb.addEventListener('click', function () { openTradeBuilder(accountId); });
      });
    } catch (e) { closeModal(true); cloudError(e); }
  }

  function openPlayerSet(accountId, displayName, setId, collection) {
    var set = window.CardSets.get(setId);
    if (!set) return;
    var owned = {};
    (collection || []).forEach(function (c) { if (c.set_id === setId) owned[c.card_id] = c; });
    var cards = set.cards.filter(function (card) { return owned[card.id]; });
    openModal('<button class="modal-x" data-close aria-label="Close">\u00d7</button><div class="profile">' +
      '<button class="btn small" id="pcBackBtn">\u2190 Back</button>' +
      '<h2>' + esc(displayName) + '</h2>' +
      '<div class="muted">' + esc(set.name) + ' \u00b7 ' + cards.length + ' / ' + set.cards.length + ' unique</div>' +
      (cards.length ? '<div class="prof-favs">' + cards.map(function (card) {
        var e = owned[card.id];
        return '<div class="prof-fav">' + CPS.cards.render(set, card, { holo: e.h > 0 }) +
          '<div class="prof-fav-cap"><b>' + esc(card.name) + '</b>' +
          '<span class="muted small">#' + U.pad(card.num, set.numWidth) + ' \u00b7 ' + rarityOf(card.rarity).label +
          (e.h > 0 ? ' \u00b7 \u2726 holo' : '') + ' \u00b7 \u00d7' + e.n + '</span></div></div>';
      }).join('') + '</div>' : '<div class="empty">No cards in this set yet.</div>') +
      '</div>', function (box) {
        box.querySelector('#pcBackBtn').addEventListener('click', function () { openProfile(accountId); });
      });
  }

  function openCardModal(setId, cardId, forceHolo) {
    var set = window.CardSets.get(setId); if (!set) return;
    var card = set.byId.get(cardId); if (!card) return;
    var st = ps(set), e = st.cards[card.id], owned = e && e.n > 0, r = rarityOf(card.rarity);
    var row = window.CardSets.oddsTable(set).filter(function (x) { return x.rarity.key === card.rarity; })[0];
    var holo = forceHolo != null ? forceHolo : !!(e && e.h);
    var html = '<button class="modal-x" data-close aria-label="Close">×</button><div class="zoom">' +
      '<div class="zoom-card">' + (owned ? CPS.cards.render(set, card, { holo: holo }) : CPS.cards.silhouette(set, card)) + '</div>' +
      '<div class="zoom-info"><div class="pill r-' + card.rarity + '">' + r.label + '</div>' +
      '<h3>' + (owned ? esc(card.name) : 'Not collected yet') + '</h3>' +
      (owned && card.subtitle ? '<div class="muted">' + esc(card.subtitle) + '</div>' : '') +
      '<dl><dt>Number</dt><dd>#' + U.pad(card.num, set.numWidth) + ' of ' + set.cards.length + '</dd>' +
      '<dt>Set</dt><dd>' + esc(set.name) + '</dd>' +
      '<dt>You own</dt><dd>' + (owned ? e.n + (e.h ? ' (' + e.h + ' holo)' : '') : '0') + '</dd>' +
      '<dt>Odds</dt><dd>' + (row ? U.oneIn(row.perCard) + ' packs' : '—') + '</dd></dl>' +
      '<div class="variant-census" id="vcensus" style="display:none"></div>' +
      (owned && card.details ? '<div class="zoom-details">' + esc(card.details) + '</div>' : '') +
      (owned && e.h && e.n > e.h ? '<button class="btn small" data-toggle-holo="' + (holo ? 0 : 1) + '">Show ' + (holo ? 'regular' : 'holo') + ' version</button>' : '') +
      (owned ? '<button class="btn small fav-btn' + (isFav(set.id, card.id) ? ' active' : '') + '" data-fav>' + (isFav(set.id, card.id) ? '★' : '☆') + ' Favorite <span class="muted">' + favCount() + '/' + FAV_MAX + '</span></button>' : '') +
      (owned && isCloud() ? '<button class="btn small" data-gift>🎁 Gift</button>' : '') +
      '</div></div>';
    openModal(html, function (box) {
      var t = box.querySelector('[data-toggle-holo]');
      if (t) t.addEventListener('click', function () { openCardModal(setId, cardId, t.dataset.toggleHolo === '1'); });
      var f = box.querySelector('[data-fav]');
      if (f) f.addEventListener('click', function () { toggleFavorite(setId, cardId, holo); });
      var g = box.querySelector('[data-gift]');
      if (g) g.addEventListener('click', function () { openGiftModal(setId, cardId); });
      fillCensus(box, set, card);
    });
  }

  /* ---------------------------------------------------------- stats */
  function renderStats() {
    var set = S.set, st = ps(), s = st.stats, owned = ownedCount(set, st);
    $('#statsSetName').textContent = '· ' + set.name;
    var epicPlus = (s.byRarity.epic || 0) + (s.byRarity.legendary || 0) + (s.byRarity.chase || 0);
    var tiles = [
      ['Packs opened', s.opened], ['Cards pulled', s.pulled], ['Unique cards', owned + ' / ' + set.cards.length],
      ['Completion', U.pct(owned / set.cards.length)], ['Holo pulls', s.holos], ['Epic or better', epicPlus],
      ['Chase pulls', s.byRarity.chase || 0], ['Packs on hand', st.packs]
    ];
    $('#statTiles').innerHTML = tiles.map(function (t) { return '<div class="tile"><span>' + t[0] + '</span><b>' + t[1] + '</b></div>'; }).join('');
    var max = Math.max.apply(null, R.RARITIES.map(function (r) { return s.byRarity[r.key] || 0; }).concat([1]));
    $('#rarityBars').innerHTML = R.RARITIES.filter(function (r) { return set.pools[r.key].length; }).map(function (r) {
      var n = s.byRarity[r.key] || 0;
      return '<div class="barrow r-' + r.key + '"><span class="bl">' + r.label + '</span><span class="bar"><i style="width:' + (n / max * 100).toFixed(1) + '%"></i></span><span class="bn">' + n + (s.pulled ? ' <em>' + U.pct(n / s.pulled) + '</em>' : '') + '</span></div>';
    }).join('');
    var best = s.best && set.byId.get(s.best.id);
    $('#bestPull').innerHTML = best
      ? CPS.cards.render(set, best, { holo: s.best.holo }) + '<div class="best-cap"><b class="rt-' + best.rarity + '">' + esc(best.name) + (s.best.holo ? ' (holo)' : '') + '</b><span>' + rarityOf(best.rarity).label + ' · ' + new Date(s.best.at).toLocaleDateString() + '</span></div>'
      : '<div class="empty">Open a pack to get started.</div>';
    $('#recentPulls').innerHTML = st.recent.length ? st.recent.map(function (x) {
      var c = set.byId.get(x.id); return c ? CPS.cards.render(set, c, { holo: x.holo }) : '';
    }).join('') : '<div class="empty">Nothing yet.</div>';
    if (CPS.globalStats) CPS.globalStats.render();
  }

  /* ---------------------------------------------------------- odds */
  function renderOdds() {
    var set = S.set, rows = window.CardSets.oddsTable(set);
    $('#oddsSetName').textContent = '· ' + set.name;
    $('#oddsIntro').textContent = set.cards.length + ' cards in this set. Each ' + set.pack.name.toLowerCase() + ' has ' + set.pack.size + ' cards, including at least one Rare or better.' +
      (set.description ? ' ' + set.description : '');
    $('#oddsTable').innerHTML = '<thead><tr><th>Rarity</th><th>Cards in set</th><th>At least one per pack</th><th>Avg per pack</th><th>Specific card</th><th>Holo chance</th></tr></thead><tbody>' +
      rows.map(function (r) {
        return '<tr class="r-' + r.rarity.key + '"><td><span class="dot"></span>' + r.rarity.label + '</td><td>' + r.count + '</td>' +
          '<td>' + U.pct(r.perPack) + ' <em>(' + U.oneIn(r.perPack) + ')</em></td><td>' + r.expected.toFixed(r.expected < 0.1 ? 3 : 2) + '</td>' +
          '<td>' + U.oneIn(r.perCard) + ' packs</td><td>' + U.pct(r.holo) + '</td></tr>';
      }).join('') + '</tbody>';
    $('#slotList').innerHTML = set.pack.slots.map(function (s) {
      var odds = R.RARITIES.filter(function (r) { return s.odds[r.key]; }).map(function (r) {
        return '<span class="pill r-' + r.key + '">' + r.label + ' ' + U.pct(s.odds[r.key], 1) + '</span>';
      }).join(' ');
      return '<div class="slot"><b>' + s.count + '×</b> <span>' + esc(s.label || 'Slot') + '</span><div>' + odds + '</div></div>';
    }).join('');
  }

  /* ---------------------------------------------------------- sets & settings */
  function fillGenSet() {
    var sel = $('#genSet'), keep = sel.value;
    sel.innerHTML = window.CardSets.all().map(function (s) {
      return '<option value="' + esc(s.id) + '">' + esc(s.name) + (s.source === 'imported' ? ' (imported)' : '') + '</option>';
    }).join('');
    sel.value = window.CardSets.get(keep) && S.genSetTouched ? keep : S.set.id;
  }

  function renderSets() {
    fillGenSet();
    $('#setList').innerHTML = window.CardSets.all().map(function (s) {
      var st = S.player.sets[s.id], owned = st ? ownedCount(s, st) : 0;
      return '<div class="set-item' + (s.id === S.set.id ? ' current' : '') + '">' +
        CPS.cards.swatch(s) +
        '<div class="set-meta"><b>' + esc(s.name) + '</b><span>' + s.cards.length + ' cards · ' + (s.source === 'imported' ? 'imported in this browser' : 'sets/ file') +
        ' · you have ' + owned + '</span></div>' +
        '<div class="set-actions">' + (s.id === S.set.id ? '<span class="pill">Selected</span>' : '<button class="btn small" data-use="' + esc(s.id) + '">Use</button>') +
        (s.source === 'imported' ? '<button class="btn small ghost" data-remove="' + esc(s.id) + '">Remove</button>' : '') + '</div></div>';
    }).join('') + (window.CardSets.errors.length || S.loadWarnings.length
      ? '<div class="warn-box">' + S.loadWarnings.concat(window.CardSets.errors).map(esc).join('<br>') + '</div>' : '');
  }

  function importBuild() {
    var text = $('#impText').value;
    var name = $('#impName').value.trim() || 'My Set';
    var res = window.CPSCsv.toSet(text, { name: name, code: $('#impCode').value.trim(), primary: $('#impC1').value, secondary: $('#impC2').value });
    if (res.set) {
      var existing = window.CardSets.get(res.set.id);
      if (existing && existing.source !== 'imported') res.set.id += '-custom';
      try { res.preview = window.CardSets.validate(res.set); } catch (e) { res.errors.push(e.message); res.preview = null; }
      // a browser can't read files off your disk: point out paths that look local
      var local = /^(\/|[A-Za-z]:[\\/]|file:|~)/, bad = 0;
      res.set.cards.forEach(function (c) { ['image', 'logo'].forEach(function (k) { if (c[k] && local.test(c[k])) bad++; }); });
      if (bad) res.errors.push(bad + ' image/logo path' + (bad === 1 ? ' looks' : 's look') + ' like a file on your computer, which a website can\'t load. Use web addresses or paths inside the site, or convert the CSV with tools/csv-to-set.js, which copies those files into the site for you.');
    }
    return res;
  }
  function importPreview() {
    var res = importBuild(), out = $('#impResult');
    if (!res.set || !res.set.cards.length) { out.innerHTML = '<div class="warn-box">' + res.errors.map(esc).join('<br>') + '</div>'; return null; }
    var counts = R.RARITIES.filter(function (r) { return res.counts[r.key]; }).map(function (r) {
      return '<span class="pill r-' + r.key + '">' + r.label + ': ' + res.counts[r.key] + '</span>';
    }).join(' ');
    var missing = R.RARITIES.filter(function (r) { return !res.counts[r.key]; }).map(function (r) { return r.label; });
    out.innerHTML = '<div><b>' + res.set.cards.length + ' cards</b> · id <code>' + esc(res.set.id) + '</code></div><div class="pills">' + counts + '</div>' +
      (missing.length ? '<div class="muted small">No ' + missing.join(' / ') + ' cards: those pack slots fall back to the nearest rarity you do have.</div>' : '') +
      (res.errors.length ? '<div class="warn-box">' + res.errors.slice(0, 12).map(esc).join('<br>') + (res.errors.length > 12 ? '<br>…and ' + (res.errors.length - 12) + ' more' : '') + '</div>' : '') +
      (res.preview ? '<div class="imp-cards">' + res.preview.cards.slice(0, 3).map(function (c) { return CPS.cards.render(res.preview, c, {}); }).join('') + '</div>' : '');
    return res;
  }

  function openPlayerModal() {
    if (isCloud()) return openAccountModal();
    if (isLocked()) return showGate({});
    Store.listPlayers().then(function (list) {
      var html = '<button class="modal-x" data-close aria-label="Close">×</button>' +
        '<h2>Players on this device</h2>' +
        '<p class="muted small">Online play is turned off, so collections stay in this browser. Each player has their own packs and cards.</p>' +
        '<div class="player-list">' + list.map(function (p) {
          var cur = p.id === S.player.id;
          return '<div class="player-row' + (cur ? ' current' : '') + '"><span class="avatar">' + esc((p.name[0] || 'P').toUpperCase()) + '</span><b>' + esc(p.name) + '</b>' +
            (cur ? '<span class="pill">Playing</span>' : '<button class="btn small" data-switch="' + esc(p.id) + '">Switch</button><button class="btn small ghost" data-del="' + esc(p.id) + '">Delete</button>') + '</div>';
        }).join('') + '</div>' +
        '<form class="row" id="renameForm"><input id="renameInput" value="' + esc(S.player.name) + '" maxlength="24" aria-label="Your name"><button class="btn small">Rename me</button></form>' +
        '<form class="row" id="newPlayerForm"><input id="newPlayerInput" placeholder="New player name" maxlength="24"><button class="btn small">Add player</button></form>';
      openModal(html, function (box) {
        box.addEventListener('click', async function (e) {
          var sw = e.target.closest('[data-switch]'), del = e.target.closest('[data-del]');
          if (sw) { await switchPlayer(sw.dataset.switch); closeModal(); }
          if (del && confirm('Delete this player and their collection?')) { await Store.deletePlayer(del.dataset.del); openPlayerModal(); }
        });
        $('#renameForm', box).addEventListener('submit', async function (e) {
          e.preventDefault(); var v = $('#renameInput', box).value.trim(); if (!v) return;
          S.player.name = v; await save(); applyPrefsUI(); openPlayerModal();
        });
        $('#newPlayerForm', box).addEventListener('submit', async function (e) {
          e.preventDefault(); var v = $('#newPlayerInput', box).value.trim(); if (!v) return;
          var p = await Store.createPlayer(v); await switchPlayer(p.id); closeModal(); toast('Welcome, ' + v + '!', 'good');
        });
      });
    });
  }

  /* The login screen. It can't be dismissed: the site is accounts-only. */
  function showGate(opts) {
    opts = opts || {};
    var html = '<div class="login-box gate">' +
      '<h2>Log in</h2>' +
      '<p class="muted small">Use the username and 4-digit PIN the site owner gave you.</p>' +
      '<form id="loginForm" class="login-form" autocomplete="on">' +
      '<label class="field">Username <input id="loginUser" type="text" autocomplete="username" autocapitalize="none" spellcheck="false" placeholder="Username" maxlength="32"></label>' +
      '<label class="field">PIN <input id="loginPin" type="password" inputmode="numeric" pattern="[0-9]{4}" maxlength="4" autocomplete="current-password" placeholder="••••"></label>' +
      '<div class="row wrap"><label class="inline"><input type="checkbox" id="loginShow"> Show PIN</label>' +
      '<label class="inline"><input type="checkbox" id="loginRemember" checked> Remember me</label>' +
      '<button class="btn primary" id="loginBtn" type="submit">Log in</button></div></form>' +
      '<div id="loginMsg" class="login-msg' + (opts.msg ? ' bad' : '') + '">' + esc(opts.msg || '') + '</div>' +
      (opts.retry ? '<button class="btn small" id="gateRetry" type="button">Try again</button>' : '') +
      '<p class="muted small">No username yet? Ask the site owner to make you an account.</p></div>';
    openModal(html, function (box) {
      S.gateOpen = true;
      var u = $('#loginUser', box), pin = $('#loginPin', box), msg = $('#loginMsg', box);
      var lastUser = Store.getPref('lastUser', '');
      if (lastUser) u.value = lastUser;
      setTimeout(function () { (lastUser ? pin : u).focus(); }, 30);
      $('#loginShow', box).addEventListener('change', function (e) { pin.type = e.target.checked ? 'text' : 'password'; });
      pin.addEventListener('input', function () { pin.value = pin.value.replace(/[^0-9]/g, '').slice(0, 4); });
      function fail(text) { msg.textContent = text; msg.className = 'login-msg bad'; audio.error(); }
      if (opts.retry) $('#gateRetry', box).addEventListener('click', async function (e) {
        var b = e.target; b.disabled = true; b.textContent = 'Trying…'; msg.textContent = ''; msg.className = 'login-msg';
        try { enterCloud(await CPS.cloud.call('get_state')); closeModal(true); afterEnter(); toast('Welcome back, ' + S.account.display_name + '!', 'good'); }
        catch (err) {
          if (err.kind === 'auth') { CPS.cloud.clearToken(); b.remove(); fail('Your session ended. Please log in again.'); }
          else { fail(err.message); b.disabled = false; b.textContent = 'Try again'; }
        }
      });
      $('#loginForm', box).addEventListener('submit', async function (e) {
        e.preventDefault();
        var name = u.value.trim(), code = pin.value.trim(), btn = $('#loginBtn', box);
        if (!name) { u.focus(); return; }
        if (!validPin(code)) { fail('Enter your 4-digit PIN.'); pin.focus(); return; }
        btn.disabled = true; btn.textContent = 'Logging in…'; msg.textContent = ''; msg.className = 'login-msg';
        try {
          var r = await doLogin(name, code, $('#loginRemember', box).checked);
          if (r && r.ok) { Store.setPref('lastUser', name); closeModal(true); return; }
          var t = (r && r.error) || 'Login failed.';
          if (r && !r.locked && r.remaining != null && r.remaining <= 3) t += ' ' + r.remaining + (r.remaining === 1 ? ' try' : ' tries') + ' left before a lockout.';
          fail(t); pin.value = ''; pin.focus();
        } catch (err) { fail(err.message); }
        finally { btn.disabled = false; btn.textContent = 'Log in'; }
      });
    });
  }

  function openAccountModal() {
    var a = S.account;
    var html = '<button class="modal-x" data-close aria-label="Close">×</button>' +
      '<h2>Your account</h2>' +
      '<div class="player-row current"><span class="avatar">' + esc((a.display_name[0] || 'P').toUpperCase()) + '</span><b>' + esc(a.display_name) + '</b>' +
      (a.is_admin ? '<span class="pill r-legendary">Admin</span>' : '') + '<span class="pill r-uncommon">Online</span></div>' +
      '<p class="muted small">Your packs, cards and stats are saved on the server, so they follow you to any device where you log in with your username.</p>' +
      '<form class="row" id="dnForm"><input id="dnInput" value="' + esc(a.display_name) + '" maxlength="32" aria-label="Display name"><button class="btn small">Change display name</button></form>' +
      '<div class="row wrap acct-actions"><button class="btn" id="logoutBtn">Log out</button><button class="btn ghost" id="acctExport" type="button">Export my collection</button></div>';
    openModal(html, function (box) {
      $('#dnForm', box).addEventListener('submit', async function (e) {
        e.preventDefault(); var v = $('#dnInput', box).value.trim(); if (!v) return;
        try { var r = await CPS.cloud.call('set_display_name', { p_name: v }); S.account.display_name = r.display_name; S.player.name = r.display_name; applyPrefsUI(); toast('Name updated.', 'good'); openAccountModal(); }
        catch (err) { cloudError(err); }
      });
      $('#acctExport', box).addEventListener('click', exportData);
      $('#logoutBtn', box).addEventListener('click', async function () {
        await CPS.cloud.logout(); closeModal(true); lockOut('You are logged out.');
      });
    });
  }

  /* ---------------------------------------------------------- admin (online) */
  async function generateServerCodes(gset, packs, n, uses) {
    if (!isAdmin()) { toast('Prize codes for online accounts need an admin login.', 'warn'); return; }
    if (S.onlineSets.indexOf(gset.id) < 0) { toast('"' + gset.name + '" isn\'t on the server yet. Upload it from the Admin tab first.', 'warn', 5000); return; }
    try {
      var codes = await CPS.cloud.call('admin_generate_codes', { p_set: gset.id, p_packs: packs, p_count: n, p_max_uses: uses, p_note: $('#genNote').value.trim() || null });
      $('#genOut').value = '# ' + codes.length + ' server code' + (codes.length === 1 ? '' : 's') + ' for ' + gset.name + ' (' + packs + ' pack' + (packs === 1 ? '' : 's') + ' each, ' +
        (uses === 1 ? 'single use' : 'up to ' + uses + ' players') + ')\n' + codes.join('\n');
      toast('Generated ' + codes.length + ' code' + (codes.length === 1 ? '' : 's') + '.', 'good');
    } catch (e) { cloudError(e); }
  }

  /* Usernames aren't secret any more: suggest one from the display name. */
  function suggestUsername(name) {
    return String(name || '').replace(/[^A-Za-z0-9_.-]+/g, '').slice(0, 32) || 'Player' + (1 + Math.floor(Math.random() * 99));
  }
  function randomPin() {
    var b = new Uint32Array(1); crypto.getRandomValues(b);
    return String(b[0] % 10000).padStart(4, '0');
  }
  function validPin(p) { return /^[0-9]{4}$/.test(p); }

  function renderAdminArea() {
    var guest = S.mode === 'guest', unlocked = isAdmin() && !!S.dev;
    $('#adminGate').classList.toggle('hidden', guest || unlocked || !isAdmin());
    $('#adminBody').classList.toggle('hidden', !unlocked);
    $('#setsArea').classList.toggle('hidden', !(guest || unlocked));
    if (unlocked) renderAdmin();
    if (guest || unlocked) renderSets();
  }

  async function renderAdmin() {
    if (!isAdmin() || !S.dev) return;
    var setOpts = window.CardSets.all().filter(function (x) { return S.onlineSets.indexOf(x.id) >= 0; })
      .map(function (x) { return '<option value="' + esc(x.id) + '"' + (x.id === S.set.id ? ' selected' : '') + '>' + esc(x.name) + '</option>'; }).join('');
    $('#naSets').innerHTML = window.CardSets.all().filter(function (x) { return S.onlineSets.indexOf(x.id) >= 0; })
      .map(function (x) { return '<label class="check"><input type="checkbox" value="' + esc(x.id) + '"' +
        (x.id === S.set.id ? ' checked' : '') + '> ' + esc(x.name) + '</label>'; }).join('') ||
      '<span class="muted small">(upload a set first)</span>';
    $('#serverSets').innerHTML = window.CardSets.all().map(function (x) {
      var on = S.onlineSets.indexOf(x.id) >= 0;
      return '<div class="set-item">' + CPS.cards.swatch(x) +
        '<div class="set-meta"><b>' + esc(x.name) + '</b><span>' + x.cards.length + ' cards · ' + (on ? 'on the server' : 'not on the server yet') + '</span></div>' +
        '<div class="set-actions"><button class="btn small' + (on ? ' ghost' : ' primary') + '" data-sync="' + esc(x.id) + '">' + (on ? 'Re-sync' : 'Upload') + '</button></div></div>';
    }).join('');
    $('#gaAllSet').innerHTML = setOpts || '<option value="">(upload a set first)</option>';
    $('#acctList').innerHTML = '<div class="muted small">Loading…</div>';
    $('#codeList').innerHTML = '<div class="muted small">Loading…</div>';
    try {
      var res = await Promise.all([CPS.cloud.call('admin_list_accounts'), CPS.cloud.call('admin_list_codes', { p_limit: 60 })]);
      var accts = res[0], codes = res[1];
      $('#acctList').innerHTML = accts.map(function (x) {
        var packs = Object.keys(x.packs || {}).map(function (k) { var st = window.CardSets.get(k); return (st ? st.code : k) + ' ' + x.packs[k]; }).join(', ') || '0';
        return '<div class="acct-row' + (x.disabled ? ' disabled' : '') + '" data-acct="' + esc(x.id) + '" data-name="' + esc(x.display_name) + '">' +
          '<div class="acct-main"><span class="avatar">' + esc((x.display_name[0] || 'P').toUpperCase()) + '</span><div><b>' + esc(x.display_name) + '</b>' +
          (x.is_admin ? ' <span class="pill r-legendary">Admin</span>' : '') + (x.disabled ? ' <span class="pill r-chase">Disabled</span>' : '') +
          (x.locked ? ' <span class="pill r-epic" title="Too many wrong PINs. Reset the PIN to unlock now.">Locked</span>' : '') +
          (x.has_pin === false ? ' <span class="pill r-chase">No PIN</span>' : '') + (x.is_me ? ' <span class="pill">You</span>' : '') +
          '<div class="muted small">username <b class="acct-user">' + esc(x.username || x.hint) + '</b> · packs ' + esc(packs) + ' · ' + (x.spins || 0) + ' spins (' + (x.spins_done || 0) + ' used) · ' + x.opened + ' opened · ' + x.unique_cards + ' unique · last login ' +
          (x.last_login_at ? new Date(x.last_login_at).toLocaleDateString() : 'never') + '</div></div></div>' +
          '<div class="acct-actions row wrap"><select class="ga-set">' + setOpts + '</select><input class="ga-n" type="number" value="3" min="-99" max="999" aria-label="Packs">' +
          '<button class="btn small" data-act="grant">Give packs</button>' +
          '<input class="ga-sp" type="number" value="1" min="-99" max="999" aria-label="Spins">' +
          '<button class="btn small" data-act="grantspins">Give spins</button>' +
          '<button class="btn small ghost" data-act="rename">Rename</button>' +
          '<button class="btn small ghost" data-act="reuser">Change username</button>' +
          '<button class="btn small ghost" data-act="pin">Reset PIN</button>' +
          (x.is_me ? '' : '<button class="btn small ghost" data-act="' + (x.disabled ? 'enable' : 'disable') + '">' + (x.disabled ? 'Enable' : 'Disable') + '</button>' +
            '<button class="btn small ghost danger-text" data-act="delete">Delete</button>') + '</div></div>';
      }).join('') || '<div class="empty">No accounts yet.</div>';
      $('#codeList').innerHTML = codes.length ? '<div class="table-wrap"><table class="odds-table codes-table"><thead><tr><th>Code</th><th>Set</th><th>Packs</th><th>Used</th><th>Redeemed by</th><th>Note</th><th>Created</th></tr></thead><tbody>' +
        codes.map(function (c) {
          var st = window.CardSets.get(c.set_id);
          return '<tr><td><code>' + esc(c.code) + '</code></td><td>' + esc(st ? st.name : c.set_id) + '</td><td>' + c.packs + '</td><td>' + c.uses + ' / ' + c.max_uses + '</td><td>' +
            esc((c.redeemed_by || []).join(', ') || '—') + '</td><td>' + esc(c.note || '') + '</td><td>' + new Date(c.created_at).toLocaleDateString() + '</td></tr>';
        }).join('') + '</tbody></table></div>' : '<div class="empty">No codes yet. Make some in Sets &amp; Settings → Prize code generator.</div>';
    } catch (e) { cloudError(e); }
  }

  async function adminAction(e) {
    var b = e.target.closest('[data-act]'); if (!b) return;
    var row = b.closest('[data-acct]'), id = row.dataset.acct, name = row.dataset.name, act = b.dataset.act, r;
    try {
      if (act === 'grant') {
        var sid = $('.ga-set', row).value, n = parseInt($('.ga-n', row).value, 10);
        if (!sid || !n) { toast('Pick a set and a number of packs.', 'warn'); return; }
        r = await CPS.cloud.call('admin_grant_packs', { p_set: sid, p_packs: n, p_account: id });
        toast((n > 0 ? 'Gave ' : 'Removed ') + Math.abs(n) + ' pack' + (Math.abs(n) === 1 ? '' : 's') + (n > 0 ? ' to ' : ' from ') + name + ' (now ' + r.packs_now + ').', 'good');
        if (id === S.account.id) { var st = window.CardSets.get(sid); if (st) ps(st).packs = r.packs_now; renderPacksSide(); }
      } else if (act === 'grantspins') {
        var sn = parseInt($('.ga-sp', row).value, 10);
        if (!sn) { toast('Enter a number of spins.', 'warn'); return; }
        r = await CPS.cloud.call('admin_grant_spins', { p_account: id, p_spins: sn });
        toast((sn > 0 ? 'Gave ' : 'Removed ') + Math.abs(sn) + ' spin' + (Math.abs(sn) === 1 ? '' : 's') + (sn > 0 ? ' to ' : ' from ') + name + ' (now ' + r.spins_now + ').', 'good');
        if (id === S.account.id) { S.spins = r.spins_now; updateWheelGlow(); if (S.view === 'wheel') renderWheel(); }
        renderAdmin();
      } else if (act === 'rename') {
        var nn = prompt('New display name for ' + name + ':', name); if (!nn || !nn.trim()) return;
        await CPS.cloud.call('admin_update_account', { p_account: id, p_display_name: nn.trim() });
        if (id === S.account.id) { S.account.display_name = nn.trim(); S.player.name = nn.trim(); applyPrefsUI(); }
      } else if (act === 'reuser') {
        var nu = prompt('New username for ' + name + ' (2–32 characters, not case-sensitive). Their PIN stays the same.', $('.acct-user', row).textContent);
        if (!nu || !nu.trim()) return;
        await CPS.cloud.call('admin_update_account', { p_account: id, p_new_username: nu.trim() });
        if (id === S.account.id) S.account.username = nu.trim();
        toast(name + "'s username is now " + nu.trim() + '.', 'good');
      } else if (act === 'pin') {
        var np = prompt('New 4-digit PIN for ' + name + '. This also unlocks the account and logs out their other devices.', randomPin());
        if (np === null) return; np = np.trim();
        if (!validPin(np)) { toast('A PIN is exactly 4 digits.', 'warn'); return; }
        await CPS.cloud.call('admin_update_account', { p_account: id, p_pin: np });
        showCreated(name, $('.acct-user', row).textContent, np, 'PIN reset');
      } else if (act === 'disable' || act === 'enable') {
        if (act === 'disable' && !confirm('Disable ' + name + '? They will be logged out and can\'t log in until you enable them.')) return;
        await CPS.cloud.call('admin_update_account', { p_account: id, p_disabled: act === 'disable' });
      } else if (act === 'delete') {
        if (!confirm('Delete ' + name + ' and ALL their cards, packs and stats? This cannot be undone.')) return;
        await CPS.cloud.call('admin_delete_account', { p_account: id });
        toast('Deleted ' + name + '.', 'warn');
      }
      renderAdmin();
    } catch (err) { cloudError(err); }
  }

  function showCreated(display, username, pin, title) {
    var text = 'Username: ' + username + '\nPIN: ' + pin + '\nSite: ' + (CPS.cloud.config.siteUrl || location.href);
    $('#naResult').innerHTML = '<div class="created-box"><div class="dev-title">' + esc(title || 'Account created') + '</div>' +
      '<p>Send <b>' + esc(display) + '</b> their login. Keep the PIN private: it won\'t be shown again (you can reset it any time).</p>' +
      '<div class="login-pair"><span>Username</span><code class="big-code" id="createdUser">' + esc(username) + '</code>' +
      '<span>PIN</span><code class="big-code" id="createdPin">' + esc(pin) + '</code></div>' +
      '<div class="row"><button class="btn small" id="copyUser" type="button">Copy both</button></div>' +
      '<p class="muted small">They log in at ' + esc((CPS.cloud.config.siteUrl || location.href)) + '.</p></div>';
    $('#copyUser').addEventListener('click', function () {
      (navigator.clipboard ? navigator.clipboard.writeText(text) : Promise.reject()).then(function () { toast('Copied.', 'good', 1200); }, function () { toast('Select and copy it manually.', 'warn'); });
    });
  }

  async function createAccount(e) {
    e.preventDefault();
    var display = $('#naName').value.trim(), user = $('#naUser').value.trim(), pin = $('#naPin').value.trim(), btn = $('#newAcctForm button[type=submit]');
    if (!display || user.length < 2) { toast('Enter a display name and a username (2+ characters).', 'warn'); return; }
    if (!validPin(pin)) { toast('Enter a 4-digit PIN (or press Random).', 'warn'); $('#naPin').focus(); return; }
    btn.disabled = true;
    try {
      var setIds = Array.prototype.filter.call(document.querySelectorAll('#naSets input[type=checkbox]'),
        function (c) { return c.checked; }).map(function (c) { return c.value; });
      var r = await CPS.cloud.call('admin_create_account', { p_username: user, p_display_name: display, p_pin: pin,
        p_start_packs: Math.max(0, parseInt($('#naPacks').value, 10) || 0), p_sets: setIds.length ? setIds : null, p_is_admin: $('#naAdmin').checked });
      showCreated(r.display_name, r.username || user, pin);
      toast('Created ' + r.display_name + ' with ' + r.packs + ' pack' + (r.packs === 1 ? '' : 's') +
        ' of ' + (r.set_ids || []).length + ' set' + ((r.set_ids || []).length === 1 ? '' : 's') + '.', 'good');
      $('#naName').value = ''; $('#naUser').value = ''; $('#naPin').value = ''; $('#naAdmin').checked = false;
      renderAdmin();
    } catch (err) { cloudError(err); }
    finally { btn.disabled = false; }
  }

  async function switchPlayer(id) {
    var p = await Store.loadPlayer(id); if (!p) return;
    p.sets = p.sets || {};
    S.player = p; Store.setActivePlayerId(id); applyPrefsUI(); resetStage(); renderView();
  }

  function exportData() {
    var data = { app: 'card-pack-sim', version: 1, exported: new Date().toISOString(), player: S.player };
    U.download('collection-' + S.player.name.replace(/\W+/g, '_') + '.json', JSON.stringify(data, null, 2), 'application/json');
  }
  function importData(file) {
    if (S.mode !== 'guest') { toast('Importing a backup only works when online play is turned off.', 'warn', 5000); return; }
    var fr = new FileReader();
    fr.onload = async function () {
      try {
        var data = JSON.parse(fr.result), p = data.player;
        if (!p || !p.id || typeof p.sets !== 'object') throw new Error('Not a collection export');
        var exists = await Store.loadPlayer(p.id);
        if (exists && !confirm('Replace the existing "' + exists.name + '" on this device with the imported data?')) return;
        await Store.savePlayer(p); await switchPlayer(p.id); toast('Imported ' + p.name + "'s collection.", 'good');
      } catch (e) { toast('Import failed: ' + e.message, 'error'); }
    };
    fr.readAsText(file);
  }

  /* ---------------------------------------------------------- dev mode lock */
  function requestDevUnlock() {
    var html = '<button class="modal-x" data-close aria-label="Close">×</button><h2>🔒 Unlock dev mode</h2>' +
      '<p class="muted small">Dev mode adds free packs and the prize code generator. Enter the password to turn it on in this browser.</p>' +
      '<form class="row" id="devForm" autocomplete="off"><input id="devPass" type="password" placeholder="Password" aria-label="Dev mode password">' +
      '<button class="btn primary small" type="submit">Unlock</button></form>';
    openModal(html, function (box) {
      var input = $('#devPass', box);
      setTimeout(function () { input.focus(); }, 30);
      $('#devForm', box).addEventListener('submit', async function (e) {
        e.preventDefault();
        var ok = await CPS.devlock.check(input.value);
        if (ok) {
          S.dev = true; Store.setPref('dev', true); applyPrefsUI(); closeModal(); if (S.view === 'admin') renderView();
          audio.coin(); toast('Dev mode unlocked.', 'good');
        } else {
          input.value = ''; input.classList.add('bad'); setTimeout(function () { input.classList.remove('bad'); }, 500);
          audio.error(); toast("That's not the password. Dev mode stays off.", 'warn');
        }
      });
    });
  }

  /* ---------------------------------------------------------- modal */
  function openModal(html, after) {
    S.gateOpen = false;
    var m = $('#modal'), box = $('#modalBox');
    var fresh = box.cloneNode(false); box.replaceWith(fresh); // drop old listeners
    fresh.innerHTML = html; m.classList.remove('hidden');
    if (after) after(fresh);
  }
  function closeModal(force) {
    if (S.gateOpen && !force) return; // the login screen stays until you log in
    S.gateOpen = false;
    $('#modal').classList.add('hidden'); $('#modalBox').innerHTML = '';
  }

  /* ---------------------------------------------------------- tilt */
  var tiltEl = null;
  function onTilt(e) {
    var el = e.target.closest && e.target.closest('#revealGrid .card.flipped, .zoom-card .card, .best-pull .card');
    if (tiltEl && tiltEl !== el) { tiltEl.style.removeProperty('--rx'); tiltEl.style.removeProperty('--ry'); tiltEl.style.removeProperty('--mx'); tiltEl = null; }
    if (!el) return;
    tiltEl = el;
    var r = el.getBoundingClientRect(), x = (e.clientX - r.left) / r.width, y = (e.clientY - r.top) / r.height;
    el.style.setProperty('--ry', ((x - 0.5) * 18).toFixed(1) + 'deg');
    el.style.setProperty('--rx', ((0.5 - y) * 18).toFixed(1) + 'deg');
    el.style.setProperty('--mx', (x * 100).toFixed(1) + '%');
  }


  /* ---------------------------------------------------------- prize wheel */
  function chicagoToday() {
    try { return new Date().toLocaleDateString('en-CA', { timeZone: 'America/Chicago' }); }
    catch (e) { return new Date().toDateString(); }
  }
  /* Guest mode: one free spin per America/Chicago day, stored on the player. */
  function grantGuestDailySpin() {
    var p = S.player;
    if (!p) return;
    var today = chicagoToday();
    if (p.lastDailySpin !== today && (p.spins || 0) < 10) {
      p.lastDailySpin = today;
      p.spins = (p.spins || 0) + 1;
      save();
    }
  }
  function spinCount() {
    return isCloud() ? (S.spins || 0) : ((S.player && S.player.spins) || 0);
  }
  /* The wheel tab lights up while the player holds at least one spin. */
  function updateWheelGlow() {
    var b = $('#wheelTabBtn');
    if (b) b.classList.toggle('has-spins', !isLocked() && spinCount() > 0);
  }
  async function refreshQuests() {
    if (!isCloud()) { S.quests = null; updateDailyGlow(); return; }
    try { S.quests = await CPS.cloud.call('list_quests', {}); }
    catch (e) { S.quests = []; }
    updateDailyGlow();
  }
  function updateDailyGlow() {
    var b = $('#dailyTabBtn');
    var has = (S.quests || []).some(function (q) { return q.done && !q.claimed; });
    if (b) b.classList.toggle('has-claimable', !isLocked() && has);
  }
  function questHtml(q) {
    var pct = Math.min(100, Math.round(q.progress / q.target * 100));
    return '<div class="quest tier-' + q.tier + (q.done && !q.claimed ? ' claimable' : '') + '">' +
      '<div class="quest-top"><div><b>' + esc(q.title) + '</b>' +
      '<span class="quest-tier">' + q.tier + ' &middot; &#x1F39F;&#xFE0F;' + q.tickets + '</span></div>' +
      (q.claimed ? '<span class="quest-done">Claimed &#x2713;</span>' :
       q.done ? '<button class="btn small primary" data-claim="' + esc(q.key) + '">Claim</button>' :
       '<span class="quest-prog">' + q.progress + '/' + q.target + '</span>') +
      '</div><div class="bar quest-bar"><i style="width:' + pct + '%"></i></div></div>';
  }
  async function renderDaily() {
    var list = $('#questList');
    if (!list) return;
    list.innerHTML = '<div class="muted">Loading&hellip;</div>';
    await refreshQuests();
    if (S.view !== 'daily') return;
    var all = S.quests || [];
    var qs = all.filter(function (q) { return !q.claimed; });
    list.innerHTML = qs.length ? qs.map(questHtml).join('') :
      (all.length ? '<div class="empty">All quests complete &mdash; fresh ones at midnight CST.</div>' :
       '<div class="empty">No quests today &mdash; check back tomorrow.</div>');
  }
  function wheelConfig() {
    if (isCloud()) return S.wheelCfg ? CPS.wheel.enrich(S.wheelCfg) : null;
    return CPS.wheel.localConfig();
  }
  function renderWheel() {
    var cfg = wheelConfig();
    var btn = $('#spinBtn'), res = $('#wheelResult');
    if (!cfg || !cfg.wheels.length) {
      $('#wheelName').textContent = 'Prize Wheel';
      $('#wheelSpins').textContent = '0';
      $('#wheelSpinsLabel').textContent = 'spins';
      btn.disabled = true;
      btn.textContent = 'Unavailable';
      res.classList.remove('hidden');
      res.innerHTML = 'The wheel isn\'t ready yet — the server needs an update. Check back soon.';
      updateWheelGlow();
      return;
    }
    var n = spinCount();
    $('#wheelSpins').textContent = n;
    $('#wheelSpinsLabel').textContent = n === 1 ? 'spin ticket' : 'spin tickets';
    var end = S._wheelEnd;
    if (end && !S.spinning) {
      var w = null;
      for (var i = 0; i < cfg.wheels.length; i++) if (cfg.wheels[i].id === end.wheelId) w = cfg.wheels[i];
      w = w || cfg.wheels[0];
      $('#wheelName').textContent = w.name;
      CPS.wheel.draw($('#wheelCanvas'), w, end.rot, end.key);
      res.classList.remove('hidden');
      res.innerHTML = end.resultHtml;
    } else {
      var w0 = cfg.wheels[0];
      $('#wheelName').textContent = w0.name;
      res.classList.add('hidden');
      res.innerHTML = '';
      if (!S.spinning) CPS.wheel.draw($('#wheelCanvas'), w0, 0);
    }
    S._wheelCfg = cfg;
    btn.disabled = S.spinning || isLocked() || n < 1;
    btn.textContent = isLocked() ? 'Log in to spin' : (n < 1 ? 'No spin tickets left' : 'SPIN');
    updateWheelGlow();
  }
  async function startWheelSpin() {
    if (S.spinning || isLocked()) return;
    if (spinCount() < 1) { toast('No spin tickets left. Come back tomorrow for your daily spin!', 'warn'); audio.error(); return; }
    var cfg = S._wheelCfg || wheelConfig();
    if (!cfg || !cfg.wheels.length) { toast('The wheel isn\'t ready yet.', 'warn'); return; }
    S.spinning = true;
    S._wheelEnd = null;
    CPS.wheel.draw($('#wheelCanvas'), cfg.wheels[0], 0);
    $('#wheelName').textContent = cfg.wheels[0].name;
    renderWheel();
    var canvas = $('#wheelCanvas'), out = null;
    try {
      if (isCloud()) {
        out = await CPS.cloud.call('spin_wheel', {});
        S.spins = out.spins_left;
        refreshQuests();
      } else {
        out = CPS.wheel.rollLocal(cfg);
        S.player.spins = Math.max(0, (S.player.spins || 1) - 1);
        var gset = out.prize && window.CardSets.get(out.prize.set_id);
        if (gset) { ps(gset).packs += out.prize.packs; out.packs_now = ps(gset).packs; }
        await save();
      }
    } catch (e) {
      S.spinning = false;
      renderWheel();
      cloudError(e);
      return;
    }
    /* The outcome was rolled above; the animation below is just theater. */
    var endState = await CPS.wheel.playHops(canvas, cfg, out.hops || []);
    var pset = out.prize && window.CardSets.get(out.prize.set_id);
    if (isCloud() && pset) ps(pset).packs = out.packs_now;
    if (!isCloud()) renderPacksSide();
    var pname = pset ? pset.name : (out.prize ? out.prize.set_id : 'packs');
    var pwon = out.prize ? out.prize.packs : 0;
    if (endState) {
      S._wheelEnd = {
        wheelId: endState.wheelId, key: endState.key, rot: endState.rotation,
        resultHtml: '🎉 You won <b>' + pwon + ' ' + esc(pname) + ' pack' + (pwon === 1 ? '' : 's') + '</b>!'
      };
    }
    try {
      var c = fx.center(canvas);
      fx.burst(c.x, c.y, { count: 60, colors: ['#ffe08a', '#ffffff', '#ffb21e'], speed: 7, shape: 'star', size: 2 });
    } catch (e2) {}
    audio.coin();
    S.spinning = false;
    renderWheel();
    renderPacksSide();
  }

  /* ---------------------------------------------------------- events */
  function bind() {
    $$('.tab').forEach(function (t) { t.addEventListener('click', function () { showView(t.dataset.view); }); });
    // logo = "Open Packs" tab. Only switches the view: a pack being opened/revealed stays exactly as it was
    // (its cards are already saved), so coming back mid-reveal is safe.
    $('#brandHome').addEventListener('click', function (e) { e.preventDefault(); if (!isLocked()) showView('packs'); });
    window.addEventListener('hashchange', function () { var v = location.hash.slice(1); if (v && v !== S.view && $('#view-' + v)) showView(v); });
    $('#setSelect').addEventListener('change', function (e) { selectSet(e.target.value); });
    $('#openBtn').addEventListener('click', startOpen);
    $('#spinBtn').addEventListener('click', startWheelSpin);
    $('#nextPackBtn').addEventListener('click', startOpen);
    $('#doneBtn').addEventListener('click', resetStage);
    $('#revealAllBtn').addEventListener('click', revealAll);
    $('#stagePack').addEventListener('click', function (e) { if (e.target.closest('.pack')) tear(); });
    $('#stageIdle').addEventListener('click', function (e) { if (e.target.closest('.idle-pack')) openFromPack(); });
    $('#stageIdle').addEventListener('keydown', function (e) {
      if ((e.key === 'Enter' || e.key === ' ') && e.target.closest('.idle-pack')) { e.preventDefault(); e.stopPropagation(); openFromPack(); }
    });
    $('#revealGrid').addEventListener('click', function (e) {
      var c = e.target.closest('.card'); if (!c) return;
      if (!c.classList.contains('flipped')) reveal(+c.dataset.i);
      else openCardModal(c.dataset.set, c.dataset.card, c.classList.contains('holo'));
    });
    $('#redeemForm').addEventListener('submit', redeem);
    $('#freePackBtn').addEventListener('click', function () { addFree(1); });
    $('#adminUnlockBtn').addEventListener('click', requestDevUnlock);
    $('#invPack').addEventListener('click', openFromPack);
    $('#invPack').addEventListener('keydown', function (e) { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); e.stopPropagation(); openFromPack(); } });
    $('#free10Btn').addEventListener('click', function () { addFree(10); });

    // collection
    $('#collSearch').addEventListener('input', function (e) { S.coll.q = e.target.value; renderCollection(); });
    $('#collRarity').addEventListener('change', function (e) { S.coll.rarity = e.target.value; renderCollection(); });
    $('#collSort').addEventListener('change', function (e) { S.coll.sort = e.target.value; renderCollection(); });
    $('#tradeinRows').addEventListener('click', function (e) {
      var b = e.target.closest('[data-trade]');
      if (b && !b.disabled) tradeDupes(b.dataset.trade);
    });
    $('#playerList').addEventListener('click', function (e) {
      var b = e.target.closest('[data-player]');
      if (b) openProfile(b.dataset.player);
    });
    $('#newTradeBtn').addEventListener('click', function () { openTradeBuilder(null); });
    $('#tradeBackBtn').addEventListener('click', function () { showView('players'); });
    $('#tradeHistBtn').addEventListener('click', function () { showView('trade-history'); });
    $('#tradeHistBackBtn').addEventListener('click', function () { showView('players'); });
    $('#tradeWithSel').addEventListener('change', function () { if (TB) { TB.to = this.value; tbLoadTheir(); } });
    $('#tradeSearch').addEventListener('input', function () { if (TB) { TB.q = this.value; tbRenderGrid(); } });
    $('#tradeSetSel').addEventListener('change', function () { if (TB) { TB.setId = this.value; tbRenderGrid(); } });
    $('#tradeRarity').addEventListener('change', function () { if (TB) { TB.rarity = this.value; tbRenderGrid(); } });
    $('#tradeContinueBtn').addEventListener('click', tbContinue);
    $('#tradeGrid').addEventListener('click', function (e) {
      if (!TB || TB.step === 3) return;
      var b = e.target.closest('.trade-pick');
      if (!b) return;
      var setId = b.dataset.set, cardId = b.dataset.card;
      var idx = TB.picks.findIndex(function (p) { return p.setId === setId && p.cardId === cardId; });
      if (idx >= 0) { TB.picks.splice(idx, 1); }
      else {
        if (TB.picks.length >= 10) { toast('Up to 10 cards per side.'); return; }
        var coll = TB.step === 1 ? TB.myColl : TB.their;
        var found = coll.filter(function (c) { return c.set_id === setId && c.card_id === cardId; })[0];
        if (!found) return;
        TB.picks.push({ setId: setId, cardId: cardId, holo: false, h: found.h || 0 });
      }
      b.classList.toggle('selected', idx < 0);
      tbRenderDock();
    });
    $('#tradeChips').addEventListener('click', function (e) {
      if (!TB) return;
      var h = e.target.closest('[data-chip-holo]'), x = e.target.closest('[data-chip-x]');
      if (h) {
        var p = TB.picks[+h.dataset.chipHolo];
        if (p && p.h > 0) { p.holo = !p.holo; tbRenderDock(); }
      } else if (x) {
        TB.picks.splice(+x.dataset.chipX, 1);
        tbRenderGrid();
      }
    });
    $('#tradeList').addEventListener('click', function (e) {
      var a = e.target.closest('[data-trade-accept]');
      if (a) { respondTrade(a.dataset.tradeAccept, true); return; }
      var d = e.target.closest('[data-trade-decline]');
      if (d) { respondTrade(d.dataset.tradeDecline, false); return; }
      var c = e.target.closest('[data-trade-cancel]');
      if (c) cancelTrade(c.dataset.tradeCancel);
    });
    $('#collOwn').addEventListener('click', function (e) {
      var b = e.target.closest('button'); if (!b) return;
      S.coll.own = b.dataset.own;
      $$('#collOwn button').forEach(function (x) { x.classList.toggle('active', x === b); });
      if (b.dataset.own === 'numbered') ensureVariants().then(function () { renderCollection(); });
      else renderCollection();
    });
    $('#questList').addEventListener('click', function (e) {
      var b = e.target.closest('[data-claim]'); if (!b || b.disabled) return;
      b.disabled = true;
      (async function () {
        try {
          var r = await CPS.cloud.call('claim_quest', { p_key: b.dataset.claim });
          S.spins = r.spins_now; updateWheelGlow();
          fx.confetti(120);
          toast('+' + r.tickets + ' spin ticket' + (r.tickets === 1 ? '' : 's') + '!', 'good');
          await refreshQuests();
          if (S.view === 'daily') renderDaily();
        } catch (err) { cloudError(err); b.disabled = false; }
      })();
    });
    $('#rarityProgress').addEventListener('click', function (e) {
      var b = e.target.closest('[data-r]'); if (!b) return;
      S.coll.rarity = S.coll.rarity === b.dataset.r ? '' : b.dataset.r; renderCollection();
    });
    ['#collGrid', '#recentPulls', '#bestPull'].forEach(function (sel) {
      $(sel).addEventListener('click', function (e) {
        var it = e.target.closest('.coll-item'), c = e.target.closest('.card') || (it && it.querySelector('.card'));
        if (c) openCardModal(c.dataset.set, c.dataset.card, c.classList.contains('holo'));
      });
    });

    // sets & settings
    $('#setList').addEventListener('click', async function (e) {
      var u = e.target.closest('[data-use]'), rm = e.target.closest('[data-remove]');
      if (u) { selectSet(u.dataset.use); renderSets(); }
      if (rm && confirm('Remove this imported set from this browser? (Your pulled cards stay saved.)')) {
        await Store.deleteCustomSet(rm.dataset.remove); window.CardSets.unregister(rm.dataset.remove);
        if (S.set.id === rm.dataset.remove) S.set = window.CardSets.all()[0];
        fillSetSelect(); selectSet(S.set.id); renderSets();
      }
    });
    $('#impFile').addEventListener('change', function (e) {
      var f = e.target.files[0]; if (!f) return;
      var fr = new FileReader();
      fr.onload = function () {
        $('#impText').value = fr.result;
        if (!$('#impName').value.trim()) $('#impName').value = f.name.replace(/\.[^.]+$/, '').replace(/[_-]+/g, ' ');
        importPreview();
      };
      fr.readAsText(f);
    });
    $('#impPreview').addEventListener('click', importPreview);
    $('#impAdd').addEventListener('click', async function () {
      var res = importPreview(); if (!res || !res.preview) return;
      await Store.saveCustomSet(res.set);
      window.CardSets.register(res.set, 'imported');
      fillSetSelect(); selectSet(res.set.id); renderSets();
      toast('Added "' + res.set.name + '" (' + res.set.cards.length + ' cards).', 'good');
    });
    $('#impDownload').addEventListener('click', function () {
      var res = importPreview(); if (!res || !res.preview) return;
      U.download(res.set.id + '.js', window.CPSCsv.toJsFile(res.set), 'text/javascript');
      toast('Saved ' + res.set.id + '.js. Put it in sets/ and add it to sets/manifest.js.', 'good', 6000);
    });
    $('#soundToggle').addEventListener('change', function (e) { audio.enabled = e.target.checked; Store.setPref('sound', audio.enabled); applyPrefsUI(); });
    $('#soundBtn').addEventListener('click', function () { audio.enabled = !audio.enabled; Store.setPref('sound', audio.enabled); applyPrefsUI(); if (audio.enabled) audio.click(); });
    $('#notifBtn').addEventListener('click', openNotifications);
    refreshNotifBadge();
    setInterval(function () { if (!document.hidden) refreshNotifBadge(); }, 60000);
    document.addEventListener('visibilitychange', function () { if (!document.hidden) refreshNotifBadge(); });
    $('#devToggle').addEventListener('change', function (e) {
      if (e.target.checked) { e.target.checked = S.dev; if (!S.dev) requestDevUnlock(); return; }
      S.dev = false; Store.setPref('dev', false); applyPrefsUI(); if (S.view === 'admin') renderView(); toast('Dev mode off. The password is needed to turn it back on.', '', 2500);
    });
    $('#exportBtn').addEventListener('click', exportData);
    $('#importDataFile').addEventListener('change', function (e) { if (e.target.files[0]) importData(e.target.files[0]); e.target.value = ''; });
    $('#genBtn').addEventListener('click', function () {
      var n = Math.min(100, Math.max(1, +$('#genCount').value || 1)), packs = Math.min(99, Math.max(1, +$('#genPacks').value || 1)), out = [];
      var gset = window.CardSets.get($('#genSet').value) || S.set;
      if (isCloud()) { generateServerCodes(gset, packs, n, Math.max(1, +$('#genUses').value || 1)); return; }
      for (var i = 0; i < n; i++) out.push(window.CPSCodes.make(gset.id, packs));
      $('#genOut').value = '# ' + n + ' code' + (n === 1 ? '' : 's') + ' for ' + gset.name + ' (' + packs + ' pack' + (packs === 1 ? '' : 's') + ' each)\n' + out.join('\n');
    });
    $('#resetSetBtn').addEventListener('click', function () {
      if (isCloud()) { toast('Online progress can\'t be reset from here.', 'warn'); return; }
      if (!confirm('Reset all your packs, cards and stats in "' + S.set.name + '"?')) return;
      delete S.player.sets[S.set.id]; save(); resetStage(); renderView(); toast('Progress reset.', 'warn');
    });
    $('#genSet').addEventListener('change', function () { S.genSetTouched = true; });
    $('#playerBtn').addEventListener('click', openPlayerModal);
    $('#newAcctForm').addEventListener('submit', createAccount);
    $('#naSuggest').addEventListener('click', function () { $('#naUser').value = suggestUsername($('#naName').value); });
    $('#naPinRandom').addEventListener('click', function () { $('#naPin').value = randomPin(); });
    $('#acctList').addEventListener('click', adminAction);
    $('#adminRefresh').addEventListener('click', function () { refreshCloud().then(renderAdmin); });
    $('#gaSpinAllBtn').addEventListener('click', async function () {
      var n = parseInt($('#gaSpinAllN').value, 10);
      if (!(n >= 1)) { toast('Pick a number of spin tickets.', 'warn'); return; }
      if (!confirm('Give ' + n + ' spin ticket' + (n === 1 ? '' : 's') + ' to every non-admin player?')) return;
      var btn = this; btn.disabled = true;
      try {
        var r = await CPS.cloud.call('admin_grant_spins_all', { p_spins: n });
        toast('Gave ' + n + ' spin ticket' + (n === 1 ? '' : 's') + ' to ' + r.players + ' player' + (r.players === 1 ? '' : 's') + '.', 'good');
        renderAdmin();
      } catch (e) { cloudError(e); btn.disabled = false; }
    });
    $('#gaAllBtn').addEventListener('click', async function () {
      var sid = $('#gaAllSet').value, n = parseInt($('#gaAllN').value, 10);
      if (!sid || !(n >= 1)) { toast('Pick a set and a number of packs.', 'warn'); return; }
      var setName = (window.CardSets.get(sid) || {}).name || sid;
      if (!confirm('Give ' + n + ' ' + setName + ' pack' + (n === 1 ? '' : 's') + ' to every non-admin player?')) return;
      var btn = this; btn.disabled = true;
      try {
        var r = await CPS.cloud.call('admin_grant_packs_all', { p_set: sid, p_packs: n });
        toast('Gave ' + n + ' pack' + (n === 1 ? '' : 's') + ' to ' + r.players + ' player' + (r.players === 1 ? '' : 's') + '.', 'good');
        renderAdmin();
      } catch (e) { cloudError(e); btn.disabled = false; }
    });
    initCollapsible();
    document.addEventListener('click', function (e) {
      var b = e.target.closest('.collapse-btn'); if (!b) return;
      var p = b.closest('.panel'); if (!p || !p.id) return;
      p.classList.toggle('collapsed');
      var s = collapsedPanels(); s[p.id] = p.classList.contains('collapsed'); saveCollapsed(s);
      e.stopPropagation();
    });
    $('#serverSets').addEventListener('click', async function (e) {
      var b = e.target.closest('[data-sync]'); if (!b) return;
      var set = window.CardSets.get(b.dataset.sync); if (!set) return;
      b.disabled = true; b.textContent = 'Uploading…';
      try {
        var r = await CPS.cloud.call('admin_upsert_set', { p_set: setPayload(set) });
        if (S.onlineSets.indexOf(set.id) < 0) S.onlineSets.push(set.id);
        toast('"' + set.name + '" is on the server (' + r.cards + ' cards).', 'good');
        renderAdmin();
      } catch (err) { cloudError(err); b.disabled = false; b.textContent = 'Retry'; }
    });

    // modal
    $('#modal').addEventListener('click', function (e) { if (e.target.id === 'modal' || e.target.closest('[data-close]')) closeModal(); });

    // keyboard
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') { closeModal(); return; }
      var t = e.target;
      if (t.closest('input, textarea, select') || !$('#modal').classList.contains('hidden')) return;
      if (t.closest('button, label') && t.offsetParent !== null && !t.disabled) return; // let visible buttons work normally
      if (S.view !== 'packs' || (e.key !== ' ' && e.key !== 'Enter')) return;
      e.preventDefault();
      var o = S.opening;
      if (!o) startOpen();
      else if (!o.torn) tear();
      else if (!o.finished) { var i = o.revealed.indexOf(false); if (i >= 0) reveal(i); }
      else if (ps().packs) startOpen();
      else resetStage();
    });

    document.addEventListener('pointermove', onTilt, { passive: true });
    // broken image path -> fall back to placeholder art
    document.addEventListener('error', function (e) {
      var img = e.target;
      if (!img || img.tagName !== 'IMG') return;
      var lg = img.closest('.cf-logo');
      if (lg) { lg.classList.add('broken'); return; } // missing logo file: just hide it
      if (!img.closest('.cf-art')) return;
      var el = img.closest('.card'), set = window.CardSets.get(el.dataset.set), c = set && set.byId.get(el.dataset.card);
      if (c) img.outerHTML = CPS.cards.art(set, c);
    }, true);
  }

  CPS.app = { state: S, config: CONFIG, openPack: startOpen, tear: tear, revealAll: revealAll, showView: showView, selectSet: selectSet };
  /* Shared context for split-out modules (js/tickets.js). */
  CPS.appCtx = { S: S, U: U, R: R, Store: Store, audio: audio, fx: fx,
    $: $, $$: $$, esc: esc, save: save, isCloud: isCloud, isLocked: isLocked, isAdmin: isAdmin,
    toast: toast, cloudError: cloudError, refreshCloud: refreshCloud, renderView: renderView,
    renderCollection: renderCollection, renderPacksSide: renderPacksSide,
    updateWheelGlow: updateWheelGlow, spinCount: spinCount, refreshQuests: refreshQuests,
    dupeCounts: dupeCounts, DUPE_RARS: DUPE_RARS, variantCountMap: variantCountMap,
    ensureVariants: ensureVariants, rarityOf: rarityOf };
  boot().catch(function (e) { console.error(e); toast('Something went wrong starting the app: ' + e.message, 'error', 10000); });
})(window.CPS);

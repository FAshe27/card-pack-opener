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
    mode: 'guest',          // 'guest' (this browser only) or 'cloud' (online account)
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
  function isAdmin() { return isCloud() && S.account && S.account.is_admin; }
  function ps(set) {
    set = set || S.set;
    var p = S.player, st = p.sets[set.id];
    if (!st) {
      st = p.sets[set.id] = { packs: isCloud() ? 0 : CONFIG.starterPacks, cards: {}, recent: [], created: Date.now(),
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
    showView(['packs', 'collection', 'stats', 'odds', 'sets', 'admin'].indexOf(v) >= 0 ? v : 'packs');
    renderPacksSide(); resetStage();
    S.loadWarnings.concat(window.CardSets.errors).forEach(function (w) { toast(w, 'warn', 6000); });
    document.body.classList.add('ready');
    if (wantDev && !S.dev) requestDevUnlock();
    else if (S.askLogin) openPlayerModal();
  }

  /* ---------------------------------------------------------- online accounts */
  async function initAccount() {
    if (CPS.cloud.enabled && CPS.cloud.hasToken()) {
      try {
        enterCloud(await CPS.cloud.call('get_state'));
        return;
      } catch (e) {
        if (e.kind === 'auth') { CPS.cloud.clearToken(); S.loadWarnings.push('Your session ended. Please log in again.'); S.askLogin = true; }
        else S.loadWarnings.push((e.kind === 'network' ? "Couldn't reach the server" : e.message) + ' Playing offline as a guest for now.');
      }
    }
    await ensurePlayer();
    S.mode = 'guest';
    if (CPS.cloud.enabled && !CPS.cloud.hasToken() && !Store.getPref('guestChosen', false)) S.askLogin = true;
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
    S.guestImported = !!state.guest_imported;
    S.player = { id: state.account.id, name: state.account.display_name, cloud: true, sets: sets };
  }

  async function refreshCloud() {
    try { enterCloud(await CPS.cloud.call('get_state')); applyPrefsUI(); renderPacksSide(); if (!S.opening) resetStage(); renderView(); }
    catch (e) { cloudError(e); }
  }

  function cloudError(e) {
    if (e && e.kind === 'auth') {
      toast(e.message || 'Please log in again.', 'warn', 5000);
      goGuest(true);
      return;
    }
    toast((e && e.message) || 'Something went wrong.', e && e.kind === 'network' ? 'warn' : 'error', 5000);
    audio.error();
  }

  async function goGuest(openLogin) {
    CPS.cloud.clearToken();
    S.mode = 'guest'; S.account = null; S.onlineSets = [];
    await ensurePlayer();
    applyPrefsUI(); resetStage(); renderView();
    if (S.view === 'admin') showView('packs');
    if (openLogin) openPlayerModal();
  }

  async function doLogin(username, remember) {
    var r = await CPS.cloud.login(username, remember);
    if (!r || !r.ok) return r;
    var guestP = S.mode === 'guest' ? S.player : null;
    enterCloud(await CPS.cloud.call('get_state'));
    applyPrefsUI(); fillSetSelect(); resetStage(); renderView();
    toast('Welcome, ' + S.account.display_name + '!', 'good');
    if (guestP && !S.guestImported && guestHasData(guestP)) {
      setTimeout(function () { toast('Tip: you can upload your guest collection once from the account menu.', '', 6000); }, 1200);
    }
    return r;
  }

  function guestHasData(p) {
    return !!p && Object.keys(p.sets || {}).some(function (k) { var st = p.sets[k]; return st && Object.keys(st.cards || {}).length; });
  }

  async function guestPlayerForUpload() {
    var id = Store.getActivePlayerId(), p = id ? await Store.loadPlayer(id) : null;
    return p && guestHasData(p) ? p : null;
  }

  async function uploadGuest() {
    var p = await guestPlayerForUpload();
    if (!p) { toast('No guest collection on this device to upload.', 'warn'); return; }
    var data = {}, cards = 0;
    Object.keys(p.sets).forEach(function (sid) {
      var st = p.sets[sid]; data[sid] = { packs: st.packs || 0, cards: st.cards || {} };
      Object.keys(st.cards || {}).forEach(function (c) { cards += st.cards[c].n || 0; });
    });
    if (!confirm('Upload "' + p.name + '" (' + cards + ' cards) from this device into your account?\n\nThis can only be done once per account. Only sets that are on the server are included, and leftover unopened packs are capped.')) return;
    try {
      var r = await CPS.cloud.call('import_guest', { p_data: data });
      toast('Uploaded ' + r.cards + ' cards and ' + r.packs + ' packs.', 'good', 5000);
      closeModal(); await refreshCloud();
    } catch (e) { cloudError(e); }
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
    document.body.classList.toggle('dev', S.dev);
    $('#devToggle').checked = S.dev;
    $('#soundToggle').checked = audio.enabled;
    $('#soundBtn').textContent = audio.enabled ? '🔊' : '🔇';
    $('#playerName').textContent = S.player.name;
    $('#playerAvatar').textContent = (S.player.name.trim()[0] || 'P').toUpperCase();
    document.body.classList.toggle('cloud', isCloud());
    document.body.classList.toggle('guest', !isCloud());
    document.body.classList.toggle('online-enabled', CPS.cloud.enabled);
    document.body.classList.toggle('admin', !!isAdmin());
    $('#playerBtn').classList.toggle('online', isCloud());
    $('#playerBtn').title = isCloud() ? 'Your account' : (CPS.cloud.enabled ? 'Log in / switch player' : 'Switch player');
    $('#modeTag').textContent = isCloud() ? (isAdmin() ? 'admin' : 'online') : 'guest';
  }

  function fillSetSelect() {
    $('#setSelect').innerHTML = window.CardSets.all().map(function (s) {
      return '<option value="' + esc(s.id) + '"' + (s.id === S.set.id ? ' selected' : '') + '>' + esc(s.name) + ' (' + s.cards.length + ')</option>';
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
  function showView(name) {
    if (name === 'admin' && !(isAdmin() && S.dev)) name = 'packs';
    S.view = name;
    $$('.view').forEach(function (v) { v.classList.toggle('active', v.id === 'view-' + name); });
    $$('.tab').forEach(function (t) { t.classList.toggle('active', t.dataset.view === name); });
    if (location.hash !== '#' + name) history.replaceState(null, '', '#' + name);
    window.scrollTo(0, 0);
    renderView();
  }
  function renderView() {
    if (S.view === 'collection') renderCollection();
    else if (S.view === 'stats') renderStats();
    else if (S.view === 'odds') renderOdds();
    else if (S.view === 'sets') renderSets();
    else if (S.view === 'admin') renderAdmin();
    else renderPacksSide();
  }

  /* ---------------------------------------------------------- packs view */
  function renderPacksSide() {
    var set = S.set, st = ps();
    $('#invPack').innerHTML = CPS.cards.pack(set, 'mini') + (st.packs ? '<span class="inv-badge">' + st.packs + '</span>' : '');
    $('#packCount').textContent = st.packs;
    $('#packCountLabel').textContent = st.packs === 1 ? 'unopened pack' : 'unopened packs';
    var busy = (S.opening && !S.opening.finished) || S.busy;
    $('#openBtn').disabled = !st.packs || busy;
    $('#openBtn').textContent = st.packs ? 'Open a pack' : 'No packs left';
    var owned = ownedCount(set, st), best = st.stats.best && set.byId.get(st.stats.best.id);
    $('#miniStats').innerHTML =
      '<div><span>Packs opened</span><b>' + st.stats.opened + '</b></div>' +
      '<div><span>Collected</span><b>' + owned + ' / ' + set.cards.length + '</b></div>' +
      '<div><span>Best pull</span><b class="' + (best ? 'rt-' + best.rarity : '') + '">' +
      (best ? esc(best.name) + (st.stats.best.holo ? ' ✦' : '') + ' <em>' + rarityOf(best.rarity).label + '</em>' : '—') + '</b></div>';
  }

  function resetStage() {
    S.opening = null;
    var set = S.set, st = ps();
    $('#stageIdle').innerHTML = '<div class="idle-pack">' + CPS.cards.pack(set, 'float') + '</div>' +
      '<div class="idle-msg">' + (st.packs
        ? '<b>' + st.packs + ' pack' + (st.packs === 1 ? '' : 's') + ' ready.</b> Hit <kbd>Open a pack</kbd> or press <kbd>Space</kbd>.'
        : '<b>Out of packs!</b> Win some at game night and redeem the prize code on the left.') + '</div>';
    $('#stageIdle').classList.remove('hidden');
    $('#stagePack').classList.add('hidden'); $('#stagePack').innerHTML = '';
    $('#revealGrid').classList.add('hidden'); $('#revealGrid').innerHTML = '';
    $('#stageControls').classList.add('hidden');
    renderPacksSide();
  }

  async function startOpen() {
    if ((S.opening && !S.opening.finished) || S.busy) return;
    var set = S.set, st = ps();
    if (st.packs <= 0) { toast('No packs left. Redeem a prize code to get more.', 'warn'); audio.error(); return; }
    var pulls, seen = {}, now = Date.now(), server = null;
    if (isCloud()) {
      if (S.onlineSets.indexOf(set.id) < 0) { toast("This set isn't on the server yet. An admin can upload it from the Admin tab.", 'warn', 5000); return; }
      S.busy = true; $('#openBtn').disabled = true; $('#openBtn').textContent = 'Opening…';
      try { server = await CPS.cloud.call('open_pack', { p_set: set.id }); }
      catch (e) { S.busy = false; renderPacksSide(); cloudError(e); return; }
      S.busy = false;
      pulls = server.cards.map(function (c) {
        var card = set.byId.get(c.id) || { id: c.id, num: c.id, name: 'Card ' + c.id, rarity: c.rarity, subtitle: '', details: '(This card is newer than your copy of the set file. Refresh the page.)', image: '' };
        return { card: card, holo: !!c.holo, serverNew: !!c.new };
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
    $('#stageIdle').classList.add('hidden');
    $('#revealGrid').classList.add('hidden'); $('#revealGrid').innerHTML = '';
    $('#stageControls').classList.add('hidden');
    var sp = $('#stagePack');
    sp.innerHTML = '<div class="pack-wrap">' + CPS.cards.pack(set, 'ready') + '</div><div class="tear-hint">Click the pack to tear it open</div>';
    sp.classList.remove('hidden');
    audio.click();
    renderPacksSide();
    var sr = $('#stage').getBoundingClientRect();
    if (sr.top > innerHeight * 0.5 || sr.top < 0) $('#stage').scrollIntoView({ behavior: 'smooth', block: 'start' });
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
      return CPS.cards.render(o.set, p.card, { holo: p.holo, flippable: true, isNew: p.isNew, cls: 'deal' + tease });
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
      ' · Top pull: <b class="rt-' + best.card.rarity + '">' + esc(best.card.name) + (best.holo ? ' ✦' : '') + '</b> (' + rarityOf(best.card.rarity).label + ')';
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
    var c = fx.center(el), r = p.card.rarity, col = rarityOf(r).color;
    if (r === 'rare') fx.burst(c.x, c.y, { count: 22, colors: [col, '#fff'], speed: 5, size: 2.2 });
    else if (r === 'epic') { fx.burst(c.x, c.y, { count: 60, colors: [col, '#fff', '#e3c2ff'], speed: 8, shape: 'star', size: 2.5 }); fx.flash('rgba(179,92,255,.25)', 600); }
    else if (r === 'legendary') {
      fx.flash('rgba(255,178,30,.45)', 900);
      fx.burst(c.x, c.y, { count: 120, colors: [col, '#fff', '#ffe08a'], speed: 11, shape: 'star', size: 3, life: 80 });
      fx.banner('LEGENDARY!', 'legendary');
      $('#stage').classList.add('shake'); setTimeout(function () { $('#stage').classList.remove('shake'); }, 600);
    } else if (r === 'chase') {
      fx.flash('rgba(255,79,163,.55)', 1200);
      fx.burst(c.x, c.y, { count: 160, colors: ['#ff4fa3', '#ffb21e', '#38c97f', '#3f8cff', '#b35cff', '#fff'], speed: 13, shape: 'star', size: 3.2, life: 90 });
      fx.confetti(240);
      fx.banner('★ CHASE CARD ★', 'chase', 2800);
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

    var q = f.q.trim().toLowerCase();
    var list = set.cards.filter(function (c) {
      var e = st.cards[c.id], has = e && e.n > 0;
      if (f.rarity && c.rarity !== f.rarity) return false;
      if (f.own === 'owned' && !has) return false;
      if (f.own === 'missing' && has) return false;
      if (f.own === 'dupes' && !(e && e.n > 1)) return false;
      if (f.own === 'holo' && !(e && e.h > 0)) return false;
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
      if (!e || !e.n) return CPS.cards.silhouette(set, c);
      return CPS.cards.render(set, c, { holo: e.h > 0, count: e.n, holoCount: e.h });
    }).join('') : '<div class="empty">No cards match these filters.</div>';
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
      (owned && card.details ? '<div class="zoom-details">' + esc(card.details) + '</div>' : '') +
      (owned && e.h && e.n > e.h ? '<button class="btn small" data-toggle-holo="' + (holo ? 0 : 1) + '">Show ' + (holo ? 'regular' : 'holo') + ' version</button>' : '') +
      '</div></div>';
    openModal(html, function (box) {
      var t = box.querySelector('[data-toggle-holo]');
      if (t) t.addEventListener('click', function () { openCardModal(setId, cardId, t.dataset.toggleHolo === '1'); });
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
        '<div class="swatch" style="' + CPS.cards.themeStyle(s) + '">' + esc(s.code) + '</div>' +
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
    Store.listPlayers().then(function (list) {
      var login = CPS.cloud.enabled
        ? '<div class="login-box"><h2>Log in</h2>' +
          '<p class="muted small">Use the username your host gave you. Keep it private: it works like a password.</p>' +
          '<form id="loginForm" class="login-form" autocomplete="on">' +
          '<input id="loginUser" type="password" autocomplete="current-password" placeholder="Your username" aria-label="Username" maxlength="64">' +
          '<div class="row wrap"><label class="inline"><input type="checkbox" id="loginShow"> Show</label>' +
          '<label class="inline"><input type="checkbox" id="loginRemember" checked> Remember me</label>' +
          '<button class="btn primary" id="loginBtn" type="submit">Log in</button></div></form>' +
          '<div id="loginMsg" class="login-msg"></div>' +
          '<button class="btn ghost small" id="playGuest" type="button">Play as guest instead (saved on this device only)</button></div>'
        : '';
      var html = '<button class="modal-x" data-close aria-label="Close">×</button>' + login +
        '<h2 class="' + (login ? 'guest-head' : '') + '">' + (login ? 'Guest players on this device' : 'Players on this device') + '</h2>' +
        '<p class="muted small">Guest collections stay in this browser. Each guest has their own packs and cards.</p>' +
        '<div class="player-list">' + list.map(function (p) {
          var cur = p.id === S.player.id;
          return '<div class="player-row' + (cur ? ' current' : '') + '"><span class="avatar">' + esc((p.name[0] || 'P').toUpperCase()) + '</span><b>' + esc(p.name) + '</b>' +
            (cur ? '<span class="pill">Playing</span>' : '<button class="btn small" data-switch="' + esc(p.id) + '">Switch</button><button class="btn small ghost" data-del="' + esc(p.id) + '">Delete</button>') + '</div>';
        }).join('') + '</div>' +
        '<form class="row" id="renameForm"><input id="renameInput" value="' + esc(S.player.name) + '" maxlength="24" aria-label="Your name"><button class="btn small">Rename me</button></form>' +
        '<form class="row" id="newPlayerForm"><input id="newPlayerInput" placeholder="New guest name" maxlength="24"><button class="btn small">Add guest</button></form>';
      openModal(html, function (box) {
        box.addEventListener('click', async function (e) {
          var sw = e.target.closest('[data-switch]'), del = e.target.closest('[data-del]');
          if (sw) { await switchPlayer(sw.dataset.switch); closeModal(); }
          if (del && confirm('Delete this guest and their collection?')) { await Store.deletePlayer(del.dataset.del); openPlayerModal(); }
        });
        $('#renameForm', box).addEventListener('submit', async function (e) {
          e.preventDefault(); var v = $('#renameInput', box).value.trim(); if (!v) return;
          S.player.name = v; await save(); applyPrefsUI(); openPlayerModal();
        });
        $('#newPlayerForm', box).addEventListener('submit', async function (e) {
          e.preventDefault(); var v = $('#newPlayerInput', box).value.trim(); if (!v) return;
          var p = await Store.createPlayer(v); await switchPlayer(p.id); closeModal(); toast('Welcome, ' + v + '!', 'good');
        });
        if (!login) return;
        var u = $('#loginUser', box);
        setTimeout(function () { u.focus(); }, 30);
        $('#loginShow', box).addEventListener('change', function (e) { u.type = e.target.checked ? 'text' : 'password'; });
        $('#playGuest', box).addEventListener('click', function () { Store.setPref('guestChosen', true); closeModal(); });
        $('#loginForm', box).addEventListener('submit', async function (e) {
          e.preventDefault();
          var name = u.value.trim(), msg = $('#loginMsg', box), btn = $('#loginBtn', box);
          if (!name) { u.focus(); return; }
          btn.disabled = true; btn.textContent = 'Logging in…'; msg.textContent = ''; msg.className = 'login-msg';
          try {
            var r = await doLogin(name, $('#loginRemember', box).checked);
            if (r && r.ok) { closeModal(); return; }
            msg.textContent = (r && r.error) || 'Login failed.';
            if (r && r.remaining != null && r.remaining <= 3) msg.textContent += ' ' + r.remaining + ' tries left before a short lockout.';
            msg.classList.add('bad'); u.select(); audio.error();
          } catch (err) {
            msg.textContent = err.message; msg.classList.add('bad'); audio.error();
          } finally { btn.disabled = false; btn.textContent = 'Log in'; }
        });
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
      '<div id="guestUp"></div>' +
      '<div class="row wrap acct-actions"><button class="btn" id="logoutBtn">Log out</button></div>';
    openModal(html, function (box) {
      $('#dnForm', box).addEventListener('submit', async function (e) {
        e.preventDefault(); var v = $('#dnInput', box).value.trim(); if (!v) return;
        try { var r = await CPS.cloud.call('set_display_name', { p_name: v }); S.account.display_name = r.display_name; S.player.name = r.display_name; applyPrefsUI(); toast('Name updated.', 'good'); openAccountModal(); }
        catch (err) { cloudError(err); }
      });
      $('#logoutBtn', box).addEventListener('click', async function () {
        await CPS.cloud.logout(); closeModal(); toast('Logged out.', ''); Store.setPref('guestChosen', true); goGuest(false);
      });
      if (!S.guestImported) guestPlayerForUpload().then(function (p) {
        if (!p) return;
        $('#guestUp', box).innerHTML = '<div class="dev-box upload-box"><div class="dev-title">Guest collection found</div>' +
          '<p class="muted small">This device has a guest collection ("' + esc(p.name) + '"). You can copy it into your account once.</p>' +
          '<button class="btn small" id="uploadGuestBtn">Upload guest collection</button></div>';
        $('#uploadGuestBtn', box).addEventListener('click', uploadGuest);
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

  var ALPH = '23456789abcdefghjkmnpqrstuvwxyz';
  function suggestUsername(name) {
    var base = String(name || 'player').toLowerCase().replace(/[^a-z0-9]+/g, '').slice(0, 12) || 'player';
    var b = new Uint32Array(7); crypto.getRandomValues(b);
    return base + '-' + Array.prototype.map.call(b, function (x) { return ALPH[x % ALPH.length]; }).join('');
  }

  async function renderAdmin() {
    if (!isAdmin() || !S.dev) { $('#adminBody').innerHTML = '<div class="panel"><p>Log in with an admin account and unlock Dev mode to see this page.</p></div>'; return; }
    var setOpts = window.CardSets.all().filter(function (x) { return S.onlineSets.indexOf(x.id) >= 0; })
      .map(function (x) { return '<option value="' + esc(x.id) + '"' + (x.id === S.set.id ? ' selected' : '') + '>' + esc(x.name) + '</option>'; }).join('');
    $('#naSet').innerHTML = setOpts || '<option value="">(upload a set first)</option>';
    $('#serverSets').innerHTML = window.CardSets.all().map(function (x) {
      var on = S.onlineSets.indexOf(x.id) >= 0;
      return '<div class="set-item"><div class="swatch" style="' + CPS.cards.themeStyle(x) + '">' + esc(x.code) + '</div>' +
        '<div class="set-meta"><b>' + esc(x.name) + '</b><span>' + x.cards.length + ' cards · ' + (on ? 'on the server' : 'not on the server yet') + '</span></div>' +
        '<div class="set-actions"><button class="btn small' + (on ? ' ghost' : ' primary') + '" data-sync="' + esc(x.id) + '">' + (on ? 'Re-sync' : 'Upload') + '</button></div></div>';
    }).join('');
    $('#acctList').innerHTML = '<div class="muted small">Loading…</div>';
    $('#codeList').innerHTML = '<div class="muted small">Loading…</div>';
    try {
      var res = await Promise.all([CPS.cloud.call('admin_list_accounts'), CPS.cloud.call('admin_list_codes', { p_limit: 60 })]);
      var accts = res[0], codes = res[1];
      $('#acctList').innerHTML = accts.map(function (x) {
        var packs = Object.keys(x.packs || {}).map(function (k) { var st = window.CardSets.get(k); return (st ? st.code : k) + ' ' + x.packs[k]; }).join(', ') || '0';
        return '<div class="acct-row' + (x.disabled ? ' disabled' : '') + '" data-acct="' + esc(x.id) + '" data-name="' + esc(x.display_name) + '">' +
          '<div class="acct-main"><span class="avatar">' + esc((x.display_name[0] || 'P').toUpperCase()) + '</span><div><b>' + esc(x.display_name) + '</b>' +
          (x.is_admin ? ' <span class="pill r-legendary">Admin</span>' : '') + (x.disabled ? ' <span class="pill r-chase">Disabled</span>' : '') + (x.is_me ? ' <span class="pill">You</span>' : '') +
          '<div class="muted small">username ' + esc(x.hint) + ' · packs ' + esc(packs) + ' · ' + x.opened + ' opened · ' + x.unique_cards + ' unique · last login ' +
          (x.last_login_at ? new Date(x.last_login_at).toLocaleDateString() : 'never') + '</div></div></div>' +
          '<div class="acct-actions row wrap"><select class="ga-set">' + setOpts + '</select><input class="ga-n" type="number" value="3" min="-99" max="999" aria-label="Packs">' +
          '<button class="btn small" data-act="grant">Give packs</button>' +
          '<button class="btn small ghost" data-act="rename">Rename</button>' +
          '<button class="btn small ghost" data-act="reuser">New username</button>' +
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
      } else if (act === 'rename') {
        var nn = prompt('New display name for ' + name + ':', name); if (!nn || !nn.trim()) return;
        await CPS.cloud.call('admin_update_account', { p_account: id, p_display_name: nn.trim() });
        if (id === S.account.id) { S.account.display_name = nn.trim(); S.player.name = nn.trim(); applyPrefsUI(); }
      } else if (act === 'reuser') {
        var nu = prompt('New secret username for ' + name + ' (at least 6 characters). Their other devices will be logged out.', suggestUsername(name));
        if (!nu || !nu.trim()) return;
        await CPS.cloud.call('admin_update_account', { p_account: id, p_new_username: nu.trim() });
        showCreated(name, nu.trim(), 'Username changed');
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

  function showCreated(display, username, title) {
    $('#naResult').innerHTML = '<div class="created-box"><div class="dev-title">' + esc(title || 'Account created') + '</div>' +
      '<p>Send <b>' + esc(display) + '</b> this username privately. It\'s their login (like a password) and won\'t be shown again:</p>' +
      '<div class="row"><code class="big-code" id="createdUser">' + esc(username) + '</code><button class="btn small" id="copyUser" type="button">Copy</button></div>' +
      '<p class="muted small">They log in at ' + esc((CPS.cloud.config.siteUrl || location.href)) + ' via the player button (top right).</p></div>';
    $('#copyUser').addEventListener('click', function () {
      (navigator.clipboard ? navigator.clipboard.writeText(username) : Promise.reject()).then(function () { toast('Copied.', 'good', 1200); }, function () { toast('Select and copy it manually.', 'warn'); });
    });
  }

  async function createAccount(e) {
    e.preventDefault();
    var display = $('#naName').value.trim(), user = $('#naUser').value.trim(), btn = $('#newAcctForm button[type=submit]');
    if (!display || user.length < 6) { toast('Enter a display name and a username of at least 6 characters.', 'warn'); return; }
    btn.disabled = true;
    try {
      var r = await CPS.cloud.call('admin_create_account', { p_username: user, p_display_name: display,
        p_start_packs: Math.max(0, parseInt($('#naPacks').value, 10) || 0), p_set: $('#naSet').value || null, p_is_admin: $('#naAdmin').checked });
      showCreated(r.display_name, user);
      toast('Created ' + r.display_name + ' with ' + r.packs + ' pack' + (r.packs === 1 ? '' : 's') + '.', 'good');
      $('#naName').value = ''; $('#naUser').value = ''; $('#naAdmin').checked = false;
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
    if (isCloud()) { toast('Log out to import a guest backup. Online accounts can upload a guest collection from the account menu.', 'warn', 5000); return; }
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
          S.dev = true; Store.setPref('dev', true); applyPrefsUI(); closeModal();
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
    var m = $('#modal'), box = $('#modalBox');
    var fresh = box.cloneNode(false); box.replaceWith(fresh); // drop old listeners
    fresh.innerHTML = html; m.classList.remove('hidden');
    if (after) after(fresh);
  }
  function closeModal() { $('#modal').classList.add('hidden'); $('#modalBox').innerHTML = ''; }

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

  /* ---------------------------------------------------------- events */
  function bind() {
    $$('.tab').forEach(function (t) { t.addEventListener('click', function () { showView(t.dataset.view); }); });
    window.addEventListener('hashchange', function () { var v = location.hash.slice(1); if (v && v !== S.view && $('#view-' + v)) showView(v); });
    $('#setSelect').addEventListener('change', function (e) { selectSet(e.target.value); });
    $('#openBtn').addEventListener('click', startOpen);
    $('#nextPackBtn').addEventListener('click', startOpen);
    $('#doneBtn').addEventListener('click', resetStage);
    $('#revealAllBtn').addEventListener('click', revealAll);
    $('#stagePack').addEventListener('click', function (e) { if (e.target.closest('.pack')) tear(); });
    $('#revealGrid').addEventListener('click', function (e) {
      var c = e.target.closest('.card'); if (!c) return;
      if (!c.classList.contains('flipped')) reveal(+c.dataset.i);
      else openCardModal(c.dataset.set, c.dataset.card, c.classList.contains('holo'));
    });
    $('#redeemForm').addEventListener('submit', redeem);
    $('#freePackBtn').addEventListener('click', function () { addFree(1); });
    $('#free10Btn').addEventListener('click', function () { addFree(10); });

    // collection
    $('#collSearch').addEventListener('input', function (e) { S.coll.q = e.target.value; renderCollection(); });
    $('#collRarity').addEventListener('change', function (e) { S.coll.rarity = e.target.value; renderCollection(); });
    $('#collSort').addEventListener('change', function (e) { S.coll.sort = e.target.value; renderCollection(); });
    $('#collOwn').addEventListener('click', function (e) {
      var b = e.target.closest('button'); if (!b) return;
      S.coll.own = b.dataset.own;
      $$('#collOwn button').forEach(function (x) { x.classList.toggle('active', x === b); });
      renderCollection();
    });
    $('#rarityProgress').addEventListener('click', function (e) {
      var b = e.target.closest('[data-r]'); if (!b) return;
      S.coll.rarity = S.coll.rarity === b.dataset.r ? '' : b.dataset.r; renderCollection();
    });
    ['#collGrid', '#recentPulls', '#bestPull'].forEach(function (sel) {
      $(sel).addEventListener('click', function (e) {
        var c = e.target.closest('.card'); if (c) openCardModal(c.dataset.set, c.dataset.card, c.classList.contains('holo'));
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
    $('#devToggle').addEventListener('change', function (e) {
      if (e.target.checked) { e.target.checked = S.dev; if (!S.dev) requestDevUnlock(); return; }
      S.dev = false; Store.setPref('dev', false); applyPrefsUI(); if (S.view === 'admin') showView('packs'); toast('Dev mode off. The password is needed to turn it back on.', '', 2500);
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
    $('#acctList').addEventListener('click', adminAction);
    $('#adminRefresh').addEventListener('click', function () { refreshCloud().then(renderAdmin); });
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
      if (!img || img.tagName !== 'IMG' || !img.closest('.cf-art')) return;
      var el = img.closest('.card'), set = window.CardSets.get(el.dataset.set), c = set && set.byId.get(el.dataset.card);
      if (c) img.outerHTML = CPS.cards.art(set, c);
    }, true);
  }

  CPS.app = { state: S, config: CONFIG, openPack: startOpen, tear: tear, revealAll: revealAll, showView: showView, selectSet: selectSet };
  boot().catch(function (e) { console.error(e); toast('Something went wrong starting the app: ' + e.message, 'error', 10000); });
})(window.CPS);

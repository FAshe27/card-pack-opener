/* Main UI. */
(function (CPS) {
  var U = CPS.util, R = window.CPSRarities, Store = CPS.Store, audio = CPS.audio, fx = CPS.fx;
  var $ = U.$, $$ = U.$$, esc = U.esc;

  var CONFIG = {
    recentMax: 36      // recent pulls kept in stats
  };

  var S = {
    player: null, set: null, view: 'packs', opening: null, dev: false,
    coll: { own: 'all', rarity: '', q: '', sort: 'rarity' },
    loadWarnings: [],
    mode: 'locked',         // 'cloud' (logged in) or 'locked' (login screen) — the site is online-only
    account: null,          // cloud: {id, display_name, is_admin}
    onlineSets: [],         // cloud: set ids that exist on the server
    busy: false
  };

  /* --- helpers */
  function rarityOf(key) { return R.RARITIES[R.INDEX[key]]; }
  function save() {
    return Promise.resolve(); // online-only: the server is the source of truth
  }
  function isCloud() { return S.mode === 'cloud'; }
  function isLocked() { return S.mode === 'locked'; }
  
  function canAdminArea() { return isAdmin(); }
  function devOn() { return !!S.dev && canAdminArea(); } // Dev tools only ever show for admins
  function isAdmin() { return isCloud() && S.account && S.account.is_admin; }
  function ps(set) {
    set = set || S.set;
    var p = S.player, st = p.sets[set.id];
    if (!st) {
      st = p.sets[set.id] = { packs: 0, cards: {}, recent: [], created: Date.now(),
        stats: { opened: 0, pulled: 0, holos: 0, byRarity: {}, best: null } };
      save();
    }
    return st;
  }
  function ownedCount(set, st) {
    var n = 0;
    set.cards.forEach(function (c) { if ((st.cards[c.id] && st.cards[c.id].n > 0) || isTurned(set.id, c.id)) n++; });
    return n;
  }
  function toast(msg, type, ms) {
    var t = U.h('<div class="toast ' + (type || '') + '">' + esc(msg) + '</div>');
    $('#toasts').appendChild(t);
    setTimeout(function () { t.classList.add('out'); setTimeout(function () { t.remove(); }, 400); }, ms || 3200);
  }
  /* Two-wave boot: the login gate renders on core scripts alone;
     setsReadyP (below) resolves when the set registry is usable. */
  var setsReadyP = null;
  function loadScript(src) {
    return new Promise(function (res) {
      var s = document.createElement('script');
      s.src = src; s.async = false; s.onload = function () { res(true); }; s.onerror = function () { res(false); };
      document.head.appendChild(s);
    });
  }

  /* --- boot */
  async function boot() {
    var es = null;
    if (CPS.cloud && CPS.cloud.enabled && CPS.cloud.hasToken()) { es = CPS.cloud.call('get_state'); es.catch(function () {}); }
    var files = window.CardSets.manifest || [];
    setsReadyP = (async function () {
      try {
        var CS = window.CardSets;
        if (CS.installBootIndex && CS.bootIndex) {
          /* Lazy boot: stubs carry every set's display metadata; only
             the landing set's full file loads now, the rest on demand. */
          CS.installBootIndex(CS.bootIndex);
          var last0 = Store.getPref('set', null);
          await CS.load(last0 && CS.bootIndex.sets[last0] ? last0 : CS.bootIndex.order[0]);
        } else {
          var oks = await Promise.all(files.map(function (f) { return loadScript('sets/' + f); }));
          oks.forEach(function (ok, i) { if (!ok) S.loadWarnings.push('Could not load sets/' + files[i]); });
          if (CS.enableAllCss) CS.enableAllCss(); /* eager fallback: every set loaded, so every set sheet applies */
        }
        var custom = await Store.listCustomSets();
        custom.forEach(function (raw) { window.CardSets.register(raw, 'imported'); });
      } catch (e) { /* the count below reports whatever did load */ }
      return window.CardSets.all().length;
    })();
    S.dev = Store.getPref('dev', false) === true;
    var wantDev = /[?&]dev\b/.test(location.search);
    audio.enabled = Store.getPref('sound', true);

    await initAccount(es);
    var gateEarly = false;
    if (isLocked()) {
      /* Wave 1: a logged-out (or expired-session) visitor gets the login
         gate as soon as the core scripts are in — the sets keep loading
         behind it and the login submit awaits them (see doLogin). */
      document.body.classList.add('ready');
      showGate(S.gate || {});
      gateEarly = true;
    }
    if (!await setsReadyP) {
      $('main').innerHTML = '<div class="panel"><h2>No card sets found</h2><p>Add a set file to <code>sets/</code> and list it in <code>sets/manifest.js</code>.</p></div>';
      return;
    }
    var last = Store.getPref('set', null);
    S.set = window.CardSets.get(last) ||
      (last === 'jumbled' && typeof CPS !== 'undefined' && CPS.jumbled ? CPS.jumbled.pseudoSet() : null) ||
      window.CardSets.all()[0];
    if (S.set && S.set.stub) { var realSet = await window.CardSets.load(S.set.id); if (realSet) S.set = realSet; }
    bind();
    fillSetSelect();
    applyPrefsUI();
    var v = (location.hash || '').replace('#', '');
    showView(['packs', 'wheel', 'collection', 'players', 'stats', 'odds', 'arcade', 'market', 'sets', 'admin', 'daily', 'faq', 'donate'].indexOf(v) >= 0 || (CPS.sandbox && CPS.sandbox.PUBLIC[v]) ? v : 'packs', true);
    renderPacksSide(); resetStage();
    S.loadWarnings.concat(window.CardSets.errors).forEach(function (w) { toast(w, 'warn', 6000); });
    document.body.classList.add('ready');
    if (isLocked()) { if (!gateEarly) showGate(S.gate || {}); }
    else if (wantDev && !S.dev && canAdminArea()) requestDevUnlock();
  }

  /* --- online accounts */
  async function initAccount(es) {
    if (!CPS.cloud.enabled) { setLocked(); S.gate = { msg: "Can't reach the server right now. Please try again later.", retry: true }; return; }
    setLocked();
    if (!CPS.cloud.hasToken()) { S.gate = {}; return; }
    try {
      enterCloud(await (es || CPS.cloud.call('get_state')));
    } catch (e) {
      if (e.kind === 'auth') { CPS.cloud.clearToken(); S.gate = { msg: 'Your session ended. Please log in again.' }; }
      else S.gate = { msg: e.message, retry: e.kind === 'network' };
    }
  }

  
  function setLocked() {
    S.mode = 'locked'; S.account = null; S.onlineSets = [];
    S.player = { id: '', name: 'Log in', sets: {} };
  }

  
  function enterCloud(state) {
    // Delta bookkeeping (186): remember the last full state object and
    // its server versions so refreshCloud can ask for changed blocks
    // only. Guarded to full-state shapes; anything else just ingests.
    if (state && state.account && state.collection) {
      S.rawState = state; S.stateVer = state.ver || 0; S.stateGVer = state.gver || 0;
    }
    var sets = {};
    function get(id) {
      return sets[id] || (sets[id] = { packs: 0, cards: {}, recent: [], stats: { opened: 0, pulled: 0, holos: 0, byRarity: {}, best: null } });
    }
    Object.keys(state.inventory || {}).forEach(function (id) { get(id).packs = state.inventory[id]; });
    (state.collection || []).forEach(function (r) { get(r[0]).cards[r[1]] = { n: r[2], h: r[3], v: r[4] || 0, vh: r[5] || 0 }; });
    Object.keys(state.stats || {}).forEach(function (id) {
      var x = state.stats[id], st = get(id).stats;
      st.opened = x.opened; st.pulled = x.pulled; st.holos = x.holos; st.byRarity = x.by_rarity || {};
      st.best = x.best ? { id: x.best.id, holo: !!x.best.holo, at: Date.parse(x.best.at) || Date.now() } : null;
    });
    Object.keys(state.recent || {}).forEach(function (id) {
      get(id).recent = state.recent[id].map(function (c) { return { id: c.id, holo: !!c.holo, at: c.at || 0 }; });
    });
    S.mode = 'cloud';
    S.account = state.account;
    S.onlineSets = state.online_sets || [];
    S.spins = state.spins || 0;
    S.gameTokens = state.game_tokens || 0;
    S.wheelCfg = state.wheel || null;
    S.favorites = {};
    (state.favorites || []).forEach(function (f) { S.favorites[f[0] + ':' + f[1]] = true; });
    S.turnedIn = {};
    // turn_ins arrives as [set, card] pairs (pre-183) or, since
    // migration 183, as a per-set map {set: [card, ...]} — accept both
    // so a cached client and a fresh payload never disagree.
    var ti = state.turn_ins;
    if (Array.isArray(ti)) {
      ti.forEach(function (f) { S.turnedIn[f[0] + ':' + f[1]] = true; });
    } else if (ti) {
      Object.keys(ti).forEach(function (sid) {
        (ti[sid] || []).forEach(function (cid) { S.turnedIn[sid + ':' + cid] = true; });
      });
    }
    S.player = { id: state.account.id, name: state.account.display_name, cloud: true, sets: sets };
    if (CPS.milestones) CPS.milestones.check();
    if (CPS.online) CPS.online.start();
  }

  /* Single-flight with a trailing re-run: bursts of refreshCloud()
     (28 call sites — nearly every action ends in one) used to stack
     full get_state pulls. A call that lands mid-flight now queues ONE
     trailing run and resolves after it, so awaiters still see state at
     least as fresh as their own action. */
  var _cloudFlight = null, _cloudTrail = null;
  /* Delta fetch (186): with a known version, ask the server for just
     the state blocks that changed; merge them onto the remembered raw
     state and ingest that. Returns null when nothing changed. ANY
     surprise (missing RPC, odd shape) falls back to a full get_state,
     which is also the path for first loads and pre-delta sessions. */
  async function fetchStateSmart() {
    if (!S.stateVer || !S.rawState) return CPS.cloud.call('get_state');
    try {
      var d = await CPS.cloud.call('get_state_delta', { p_ver: S.stateVer, p_gver: S.stateGVer || 0 });
      if (d && d.unchanged) return null;
      if (d && d.blocks) {
        var m = Object.assign({}, S.rawState, d.blocks);
        m.ver = d.ver; m.gver = d.gver; m.game_tokens = d.game_tokens;
        return m;
      }
      if (d && d.account) return d;
      return CPS.cloud.call('get_state');
    } catch (e) { return CPS.cloud.call('get_state'); }
  }
  async function _refreshCloudOnce() {
    try { var st = await fetchStateSmart(); if (st) enterCloud(st); applyPrefsUI(); renderPacksSide(); if (!S.opening) resetStage(); renderView(); refreshQuests(); refreshNotifBadge(); }
    catch (e) { cloudError(e); }
  }
  function refreshCloud() {
    if (_cloudFlight) {
      if (!_cloudTrail) {
        _cloudTrail = _cloudFlight.then(async function () {
          _cloudTrail = null; _cloudFlight = null;
          return refreshCloud();
        });
      }
      return _cloudTrail;
    }
    _cloudFlight = _refreshCloudOnce();
    return _cloudFlight;
  }

  function cloudError(e) {
    if (e && e.kind === 'auth') { lockOut(e.message || 'Please log in again.'); return; }
    toast((e && e.message) || 'Something went wrong.', e && e.kind === 'network' ? 'warn' : 'error', 5000);
    audio.error();
  }

  
  function lockOut(msg) {
    CPS.cloud.clearToken();
    S.opening = null;
    setLocked();
    if (S.gateOpen) return; // gate already up: re-rendering the view behind it re-fails auth and rebuilds the login box forever
    if (S.view === 'admin') showView('packs');
    applyPrefsUI(); resetStage(); renderView();
    showGate({ msg: msg });
  }

  async function doLogin(username, pin, remember) {
    var r = await CPS.cloud.login(username, pin, remember);
    if (!r || !r.ok) return r;
    enterCloud(await CPS.cloud.call('get_state'));
    if (setsReadyP) await setsReadyP;
    afterEnter();
    toast('Welcome, ' + S.account.display_name + '!', 'good');
    return r;
  }

  function afterEnter() {
    S._wheelEnd = null;
    applyPrefsUI(); fillSetSelect(); renderPacksSide(); resetStage(); renderView(); refreshQuests(); refreshNotifBadge();
  }

  
  function setPayload(set) {
    return {
      id: set.id, name: set.name, code: set.code,
      pack: { name: set.pack.name, holo: set.pack.holo,
              slots: set.pack.slots.map(function (s) { return { count: s.count, label: s.label, odds: s.odds }; }) },
      cards: set.cards.map(function (c) { return { id: c.id, num: typeof c.num === 'number' ? c.num : parseInt(c.num, 10) || null, name: c.name, rarity: c.rarity }; })
    };
  }

  function applyPrefsUI() {
    document.body.classList.toggle('dev', devOn());
    $('#adminTabBtn').textContent = 'Admin';
    var dt = $('#devToggle'); if (dt) dt.checked = S.dev;
    var st = $('#soundToggle'); if (st) st.checked = audio.enabled;
    $('#soundBtn').textContent = audio.enabled ? '🔊' : '🔇';
    $('#playerName').textContent = S.player.name;
    $('#playerAvatar').textContent = (S.player.name.trim()[0] || 'P').toUpperCase();
    document.body.classList.toggle('cloud', isCloud());
    document.body.classList.toggle('locked', isLocked());
    document.body.classList.toggle('online-enabled', CPS.cloud.enabled);
    document.body.classList.toggle('admin', !!isAdmin());
    $('#playerBtn').classList.toggle('online', isCloud());
    $('#playerBtn').title = isCloud() ? 'Your account' : isLocked() ? 'Log in' : 'Switch player';
    var mt = $('#modeTag');
    mt.textContent = isCloud() ? (isAdmin() ? 'admin' : '') : isLocked() ? '' : 'local';
    mt.classList.toggle('hidden', !mt.textContent);
    updateWheelBadge();
    if (typeof CPS !== 'undefined' && CPS.games) CPS.games.updateBadge();
    if (typeof CPS !== 'undefined' && CPS.bounties) CPS.bounties.navBadge();
  }

  
  function packCount(set) {
    var sets = (S.player && S.player.sets) || {};
    var st = sets[set.id];
    if (st) return st.packs;
    return 0;
  }

  function fillSetSelect() {
    var sets = window.CardSets.all().slice();
    if (typeof CPS !== 'undefined' && CPS.jumbled && !window.CardSets.get('jumbled')) sets.push(CPS.jumbled.pseudoSet()); /* Jumbled Mess is always listed, packs or not (Franklin) */
    sets.sort(function (a, b) {
      return a.name < b.name ? -1 : a.name > b.name ? 1 : 0;
    });
    function item(s) {
      var n = packCount(s), cur = s.id === S.set.id;
      return '<button type="button" class="set-dd-item' + (cur ? ' is-current' : '') + (n > 0 ? ' has-packs' : '') + '" role="option" aria-selected="' + cur + '" data-set-id="' + esc(s.id) + '">' +
        '<span class="set-dd-name">' + (cur ? '\u2192 ' : '') + esc(s.name) + '</span>' +
        (n > 0 ? '<span class="set-dd-count">\u25CF ' + n + '</span>' : '') + '</button>';
    }
    var withPacks = sets.filter(function (s) { return packCount(s) > 0; });
    var without = sets.filter(function (s) { return packCount(s) <= 0; });
    var html = '';
    if (withPacks.length) html += '<div class="set-dd-group">Available Packs</div>' + withPacks.map(item).join('');
    if (without.length) html += '<div class="set-dd-group">No packs</div>' + without.map(item).join('');
    if (!html) html = sets.map(item).join('');
    var list = $('#setDDList'); if (list) list.innerHTML = html;
    prefetchSetDD();
    var lbl = $('#setDDLabel');
    if (lbl && S.set) {
      var cn = packCount(S.set);
      lbl.textContent = S.set.name + (cn > 0 ? ' (' + cn + ')' : '');
    }
  }

  function prefetchSetDD() {
    var list = $('#setDDList'); if (!list || list._pf) return; list._pf = 1;
    list.addEventListener('mouseover', function (e) {
      var b = e.target.closest ? e.target.closest('[data-set-id]') : null;
      if (b && window.CardSets.load) window.CardSets.load(b.getAttribute('data-set-id'));
    });
  }
  function closeSetDD() {
    var list = $('#setDDList'), btn = $('#setDDBtn');
    if (list) list.classList.add('hidden');
    if (btn) btn.setAttribute('aria-expanded', 'false');
  }
  function toggleSetDD() {
    var list = $('#setDDList'), btn = $('#setDDBtn');
    if (!list || !btn) return;
    var opening = list.classList.contains('hidden');
    if (opening) {
      fillSetSelect(); // fresh counts, always rendered from the top
      // Portal to <body> and pin under the button: inside the sticky header the
      // list is trapped in the header's stacking context (z 20), so page content
      // (pack art, progress rings) paints over it. Fixed at root level it can't be.
      if (list.parentNode !== document.body) document.body.appendChild(list);
      var r = btn.getBoundingClientRect();
      var w = Math.max(r.width, 264); if (w > window.innerWidth - 16) w = window.innerWidth - 16;
      list.style.width = w + 'px';
      list.style.left = Math.max(8, Math.min(r.left, window.innerWidth - w - 8)) + 'px';
      list.style.top = (r.bottom + 6) + 'px';
      list.classList.remove('hidden');
      list.scrollTop = 0;
      btn.setAttribute('aria-expanded', 'true');
      var cur = list.querySelector('.set-dd-item.is-current');
      if (cur) { cur.focus({ preventScroll: true }); list.scrollTop = 0; }
    } else closeSetDD();
  }

  function selectSet(id) {
    var set = id === 'jumbled' && typeof CPS !== 'undefined' && CPS.jumbled ? CPS.jumbled.pseudoSet() : window.CardSets.get(id);
    if (!set) return;
    if (set.stub) {
      closeSetDD();
      window.CardSets.load(id).then(function (s2) {
        if (s2) selectSet(id);
        else toast('Could not load that set — check your connection and try again.', 'warn', 5000);
      });
      return;
    }
    if (S.opening && !S.opening.finished) { toast('Finish this pack first — its cards are already in your collection.', 'warn'); return; }
    S.set = set; Store.setPref('set', id);
    closeSetDD();
    S.coll.rarity = '';
    resetStage(); renderPacksSide(); renderView();
  }

  /* --- views */
  function showView(name, quiet) {
    if (S.view && S.view !== name) S.prevView = S.view;
    if (name === 'daily' && !isCloud()) name = 'packs';
    if (name === 'bounties' || name === 'trading') name = 'market';
    if (name === 'sets') name = 'admin'; // Sets & Settings now lives in the Admin area
    if ((name === 'admin' || name === 'sandbox') && !canAdminArea()) name = 'packs';
    S.view = name;
    $$('.view').forEach(function (v) { v.classList.toggle('active', v.id === 'view-' + name); });
    $$('.tab').forEach(function (t) { t.classList.toggle('active', t.dataset.view === name); });
    if (name === 'packs' && S.opening && S.opening.torn) {
      var rg = $('#revealGrid');
      if (rg && !rg.classList.contains('hidden')) {
        /* Re-showing the packs view (display:none -> block) restarts the reveal
           cards' deal animation and re-runs the flip transitions, leaving the
           revealed cards invisible or frozen mid-flip for a second or more.
           Suppress animation/transition on the grid for the re-entry frame so
           the finished reveal is simply there when the view paints. */
        rg.classList.add('no-anim');
        requestAnimationFrame(function () { requestAnimationFrame(function () { rg.classList.remove('no-anim'); }); });
      }
    }
    if (location.hash !== '#' + name) history.replaceState(null, '', '#' + name);
    window.scrollTo(0, 0);
    renderView();
    if (name === 'admin' && !quiet && isAdmin() && !S.dev) requestDevUnlock();
  }
  function goBack(fallback) { showView(S.prevView || fallback || 'packs'); }
  function renderView() {
    if (S.view === 'daily') { renderDaily(); return; }
    if (S.view === 'collection') {
      renderCollection();
      if (isCloud() && !S.myVariants) ensureVariants().then(function () {
        if (S.view !== 'collection') return;
        // Variants arrived: update the variants panel directly.
        // Only rebuild the 500-card grid if the numbered filter needs the data.
        if (S.coll.own === 'numbered') renderCollection();
        else renderVariantsSection(S.set);
      });
    }
    else if (S.view === 'players') renderPlayers();
    else if (S.view === 'trade') renderTradeBuilder();
    else if (S.view === 'trade-history') renderTradeHistory();
    else if (S.view === 'stats') renderStatsLazy();
    else if (S.view === 'odds') renderOdds();
    else if (S.view === 'admin') renderAdminArea();
    else if (S.view === 'arcade') { if (typeof CPS !== 'undefined' && CPS.games) CPS.games.render(); }
    else if (S.view === 'market' && CPS.market) CPS.market.render();
    else if (CPS.sandbox && CPS.sandbox.PUBLIC[S.view]) { CPS.sandbox.render(S.view); }
    else if (S.view === 'wheel') renderWheel();
    else renderPacksSide();
  }



  /* --- packs view */
  function renderPacksSide() {
    fillSetSelect(); // keep the set dropdown's pack counts live
    var set = S.set, st = ps();
    var busy = (S.opening && !S.opening.finished) || S.busy;
    $('#openBtn').disabled = !st.packs || busy;
    $('#openBtn').textContent = st.packs ? (set.id === 'jumbled' ? 'Open Jumbled Mess' : (S.opening && S.opening.finished && S.opening.set.id === set.id ? 'Open next pack (' + st.packs + ' left)' : 'Open a pack')) : 'No packs left';
    var qb = $('#quickOpenBtn'); if (qb) qb.disabled = !st.packs || busy;
    if (CPS.jumbled) CPS.jumbled.renderBox();
    if (CPS.packsBadge) CPS.packsBadge.update();
  }

  function resetStage() {
    S.opening = null;
    var set = S.set, st = ps();
    $('#stageIdle').innerHTML = '<div class="idle-pack' + (st.packs ? ' clickable' : ' empty') + '" role="button" tabindex="0" title="' +
        (st.packs ? 'Click to open and tear a pack' : 'No packs left') + '">' + CPS.cards.pack(set, 'float') + (st.packs ? '<span class="inv-badge stage-badge">' + st.packs + '</span>' : '') + '</div>' +
      '<div class="idle-msg">' + (st.packs
        ? '<b>' + st.packs + ' pack' + (st.packs === 1 ? '' : 's') + ' ready.</b> Click the pack (or press <kbd>Space</kbd>) to open.'
        : '<b>Out of ' + esc(set.name) + ' packs!</b>' + (function () {
            var others = 0;
            if (S.player && S.player.sets) Object.keys(S.player.sets).forEach(function (id) {
              var s2 = S.player.sets[id];
              if (id !== set.id && s2 && s2.packs > 0) others++;
            });
            return others
              ? ' You have packs in ' + others + ' other set' + (others === 1 ? '' : 's') + ' — pick one from the set menu above.'
              : ' Win or earn more packs!';
          })()) + '</div>';
    $('#stageIdle').classList.remove('hidden');
    $('#stagePack').classList.add('hidden'); $('#stagePack').innerHTML = '';
    $('#revealGrid').classList.add('hidden'); $('#revealGrid').innerHTML = '';
    $('#stageControls').classList.add('hidden');
    $('#stage').style.minHeight = ''; $('#revealGrid').style.removeProperty('--cardw'); $('#revealGrid').style.maxWidth = '';
    renderPacksSide();
  }

  async function startOpen() {
    if ((S.opening && !S.opening.finished) || S.busy) return;
    if (S.set.id === 'jumbled') { if (typeof CPS !== 'undefined' && CPS.jumbled) CPS.jumbled.open(); return; }
    if (isLocked()) { showGate({}); return; }
    var set = S.set, st = ps();
    if (st.packs <= 0) { toast('Out of packs! Win or earn more packs!', 'warn'); audio.error(); return; }
    var pulls, seen = {}, now = Date.now(), server = null;
    if (isCloud()) {
      if (S.onlineSets.indexOf(set.id) < 0) { toast("This set isn't on the server yet. An admin can upload it from the Admin tab.", 'warn', 5000); return; }
      S.busy = true; $('#openBtn').disabled = true; $('#openBtn').textContent = 'Opening…';
      try { server = await CPS.cloud.call('open_pack', { p_set: set.id }); }
      catch (e) { S.busy = false; renderPacksSide(); cloudError(e); return; }
      S.busy = false;
      S.myVariants = null; S.variantCensus = null; S.variantMisprints = null;
      pulls = server.cards.map(function (c) {
        if (c.ticket || c.tokens || c.credit) return { ticket: !!c.ticket, tokens: c.tokens || 0, credit: c.credit || 0 };
        var card = set.byId.get(c.id) || { id: c.id, num: c.id, name: 'Card ' + c.id, rarity: c.rarity, subtitle: '', details: '(This card is newer than your copy of the set file. Refresh the page.)', image: '' };
        return { card: card, holo: !!c.holo, serverNew: !!c.new, variant: c.variant || null, serial: c.serial || null };
      });
    }
    var bc = st.stats.best && set.byId.get(st.stats.best.id);
    var curBest = bc ? CPS.packs.score(bc, st.stats.best.holo) : -1, prevBest = curBest, bestPull = null;
    st.packs--;
    pulls.forEach(function (p) {
      if (CPS.slips.isSlip(p)) return;
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

    S.opening = { set: set, pulls: pulls, torn: false, revealed: pulls.map(function () { return false; }), finished: false, auto: false, hero: !!(server && server.hero), stuffed: !!(server && server.stuffed), stuffedHero: !!(server && server.stuffed_hero) };
    refreshQuests();
    $('#stageIdle').classList.add('hidden');
    $('#revealGrid').classList.add('hidden'); $('#revealGrid').innerHTML = '';
    $('#stageControls').classList.add('hidden');
    var sp = $('#stagePack');
    sp.innerHTML = '<div class="pack-wrap">' + CPS.cards.pack(set, 'ready') + '</div><div class="tear-hint">Click the pack to tear it open</div>';
    sp.classList.remove('hidden');
    fitStagePre(set, pulls.length);
    audio.click();
    renderPacksSide();
    var pr = $('#stagePack .pack').getBoundingClientRect();
    if (pr.top < 0 || pr.bottom > innerHeight) $('#stage').scrollIntoView({ behavior: 'smooth', block: 'start' });
    return true;
  }

  
  async function openFromPack() {
    var o = S.opening;
    if (S.busy) return;
    if (o && !o.finished) { if (!o.torn) tear(); return; } // a pack is already out: tear it
    if (isLocked()) { showGate({}); return; }
    if (ps().packs <= 0) { toast('Out of packs! Win or earn more packs!', '', 3500); return; }
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
    if (o.stuffedHero) fx.banner('STUFFED HERO PACK!', 'hero');
    else if (o.hero) fx.banner('HERO PACK!', 'hero');
    else if (o.stuffed) fx.banner('STUFFED PACK!', 'hero');
    $('#stagePack').classList.add('hidden');
    buildGrid(o);
  }

  /* ============ FIT-TO-WINDOW REVEAL SIZING (staged prototype) ============
     Sizes the reveal cards FROM the space actually available, instead of
     fixed card widths + the stage reservation constants in style.css:
       - budget: on <=900px, the whole page must fit the window with no
         scroll (desktop >900px: fit inside the stage box, min-height
         700px) — minus the packs control strip, stage padding/gaps and
         the summary + Reveal All block;
       - columns: BALANCED grids first (3..5 phone/tablet, 3..6 desktop):
         a column count that divides the card count evenly wins over a
         marginally wider orphan layout (9 renders 3x3 on phone/tablet, 5+4 on desktop; 12 takes
         the widest of 3/4/6, 15 the widest of 3/5); with no divisor in
         range, the layout with the smallest last-row orphan wins. A
         non-balanced layout is chosen only when no balanced one fits
         the budget at/above the readability floor;
       - cap: today's card width for this grid/viewport — cards can shrink
         to fit, never grow past the approved size;
       - floor: if the strict no-scroll budget would crush phone cards
         under FIT_MINW, use the "stage at the top of the window" budget
         instead (top bar scrolled away by the scroll startOpen already
         performs) so cards stay readable; the grid records which budget
         won in data-fit-mode.
     The width is written to --cardw on #revealGrid (style.css falls back
     to today's widths when unset) and, on <=900px, the stage's inline
     min-height becomes the exact fitted content height, replacing the
     reservation constants for the reveal. fitStagePre() applies the same
     height the moment the pack is staged, so the control strip does not
     move between tear and reveal. FIT-BEGIN */
  var FIT_SCH_EST = 76;   /* summary + Reveal All height while hidden (measured 76px in the rig); buildGrid re-fits with the real height */
  var FIT_MINW = 80;      /* phone readability floor for the strict no-scroll budget */

  function fitScH() {
    var sc = $('#stageControls');
    return (sc && !sc.classList.contains('hidden')) ? sc.getBoundingClientRect().height : FIT_SCH_EST;
  }
  function fitTodayW(playing, gridW) {
    if (playing) {
      if (window.innerWidth <= 560) return gridW * 0.333 - 8;
      return (Math.min(gridW, 584) - 32) / 3;
    }
    if (window.innerWidth <= 560) return gridW * 0.333 - 8;
    return Math.max(108, Math.min(184, (gridW - 64) / 5));
  }
  function fitBudget() {
    var stage = $('#stage'); if (!stage) return { strict: 0, scrolled: 0, padT: 0, padB: 0, gapY: 22, scH: 0 };
    var st = getComputedStyle(stage);
    var padT = parseFloat(st.paddingTop) || 0, padB = parseFloat(st.paddingBottom) || 0;
    var gapY = parseFloat(st.rowGap); if (isNaN(gapY)) gapY = parseFloat(st.gap) || 22;
    var scH = fitScH();
    if (window.innerWidth > 900) {
      var mh = parseFloat(st.minHeight) || 700;
      return { strict: mh - padT - padB - gapY - scH, scrolled: 0, padT: padT, padB: padB, gapY: gapY, scH: scH };
    }
    var controls = document.querySelector('.packs-controls');
    var cH = controls ? controls.getBoundingClientRect().height : 0;
    var stageTopDoc = stage.getBoundingClientRect().top + window.scrollY;
    /* strict: the whole page (top bar included) fits the window, no scroll at all.
       scrolled: the stage is scrolled to the top of the window the way startOpen
       already scrolls it — 84px (the stage's scroll-margin-top) stays visible
       above it, then stage + control strip must fill the rest exactly. */
    /* Phone budgets no longer reserve scH (the summary + Reveal All row):
       that row may sit a touch below the fold so the cards themselves stay
       ~105px instead of ~88 (Franklin's call, 2026-10-20). pick.total still
       counts scH, so the stage keeps its full fitted height. */
    var strict = window.innerHeight - 14 - cH - padT - gapY - padB - stageTopDoc;
    var scrolled = window.innerHeight - 84 - cH - padT - gapY - padB;
    return { strict: strict, scrolled: scrolled, padT: padT, padB: padB, gapY: gapY, scH: scH };
  }
  function fitPick(n, gridW, ratio, gap, cap, budgetH) {
    var maxCols = window.innerWidth <= 900 ? 5 : 6;
    var floor = window.innerWidth <= 900 ? FIT_MINW : 0;
    var cands = [];
    for (var cols = 3; cols <= maxCols; cols++) {
      var rows = Math.ceil(n / cols);
      var wW = (gridW - (cols - 1) * gap) / cols;
      var wH = ((budgetH - (rows - 1) * gap) / rows) / ratio;
      var w = Math.min(wW, wH, cap);
      cands.push({ w: w, wW: wW, cols: cols, rows: rows, orphan: (cols - (n % cols)) % cols, balanced: n % cols === 0 });
    }
    function widest(list) { var b = null; for (var i = 0; i < list.length; i++) if (!b || list[i].w > b.w + 0.5) b = list[i]; return b; }
    function viable(list) { return list.filter(function (c) { return c.w >= floor; }); }
    /* Desktop 9-card packs render 5+4, the pre-solver rows (Franklin's
       call, 2026-10-23); phone/tablet keeps the balanced 3x3 below. The
       100px guard hands truly squeezed budgets back to the normal path. */
    if (window.innerWidth > 900 && n === 9) {
      var c5 = null;
      for (var ci = 0; ci < cands.length; ci++) if (cands[ci].cols === 5) c5 = cands[ci];
      if (c5 && c5.w >= 100) return c5;
    }
    /* Balanced first: a column count that divides the pack evenly beats a
       marginally wider layout with an orphan row (9 -> 3x3 on phone/tablet, 5+4 on desktop;
       12 -> widest of 3/4/6; 15 -> widest of 3/5). Single-row layouts
       count as balanced only for tiny packs (n <= 3, e.g. Periodic 1x3);
       a 5-card States pack still prefers its 3+2 over five-across. */
    var bal = viable(cands.filter(function (c) { return c.balanced && (c.rows >= 2 || n <= 3); }));
    if (bal.length) return widest(bal);
    var balAny = viable(cands.filter(function (c) { return c.balanced; }));
    if (balAny.length) return widest(balAny);
    /* No divisor fits at/above the floor: minimize the last-row orphan,
       then take the widest — among floor-clearing multi-row layouts
       when any exist. */
    var multi = cands.filter(function (c) { return c.rows >= 2 || n <= 3; });
    var pool = viable(multi);
    if (!pool.length) {
      /* Squeezed budget (short viewport + tall control strip): nothing
         clears the readability floor. A near-floor fitting layout
         (>= 70px) still wins as-is — but when even the widest layout
         is stamp-sized, the height budget loses: keep the balanced
         shape at its WIDTH-driven size and let the stage grow past
         the fold (Franklin's rule: 9 renders 3x3 on phones; a taller
         stage beats 59px stamps in a 5-across orphan row, 2026-10-20).
         Falls back to the min-orphan multi-row shape for counts with
         no divisor in range. */
      var oldPick = widest(cands);
      if (oldPick && oldPick.w >= 70) return oldPick;
      var sq = cands.filter(function (c) { return c.balanced && (c.rows >= 2 || n <= 3); });
      if (!sq.length) {
        var mo = Math.min.apply(null, multi.map(function (x) { return x.orphan; }));
        sq = multi.filter(function (c) { return c.orphan === mo; });
      }
      if (!sq.length) sq = cands;
      var bw = null;
      sq.forEach(function (c) { var w = Math.min(c.wW, cap); if (!bw || w > bw.w + 0.5) bw = { w: w, cols: c.cols, rows: c.rows, orphan: c.orphan, balanced: c.balanced, sq: true }; });
      return bw;
    }
    var minOrphan = Math.min.apply(null, pool.map(function (c) { return c.orphan; }));
    var near = pool.filter(function (c) { return c.orphan === minOrphan; });
    if (near.length) return widest(near);
    return widest(cands);
  }
  function fitSolve(n, gridW, ratio, playing) {
    var grid = $('#revealGrid'), gap = 16;
    if (grid) { var g = parseFloat(getComputedStyle(grid).columnGap); if (!isNaN(g)) gap = g; }
    var cap = fitTodayW(playing, gridW);
    var b = fitBudget();
    var pick = fitPick(n, gridW, ratio, gap, cap, b.strict);
    var mode = 'window';
    if (window.innerWidth <= 900 && pick) {
      /* On phones the stage-top budget is always the roomier one (the
         strict budget subtracts the whole page chrome above the stage),
         so take it whenever it beats strict — the old floor gate let a
         barely-passing strict pick (81px) block a much roomier one. */
      var p2 = fitPick(n, gridW, ratio, gap, cap, b.scrolled);
      /* A squeezed strict pick (height budget ignored, stage will grow)
         must not outbid a stage-top pick that genuinely fits — take the
         fitting one whenever it exists. */
      if (p2 && (p2.w > pick.w + 0.5 || (pick.sq && !p2.sq))) { pick = p2; mode = 'stage-top'; }
    }
    if (!pick) return null;
    pick.gridH = pick.rows * pick.w * ratio + (pick.rows - 1) * gap;
    pick.rowW = pick.cols * pick.w + (pick.cols - 1) * gap;
    pick.total = b.padT + pick.gridH + b.gapY + b.scH + b.padB;
    pick.mode = mode;
    return pick;
  }
  function fitApply(n, gridW, ratio, playing) {
    var grid = $('#revealGrid'), stage = $('#stage');
    if (!grid || !stage) return;
    var pick = fitSolve(n, gridW, ratio, playing);
    if (!pick) return;
    grid.style.setProperty('--cardw', pick.w.toFixed(1) + 'px');
    grid.style.maxWidth = Math.ceil(pick.rowW) + 'px';  /* ceil: rounding down can wrap the row early */
    grid.dataset.fitCols = pick.cols; grid.dataset.fitMode = pick.mode;
    if (window.innerWidth <= 900) stage.style.minHeight = Math.round(Math.max(pick.total, 448)) + 'px';  /* 448 = the idle reservation: small reveals keep the panel height instead of collapsing */
    else stage.style.minHeight = '';
  }
  function fitReveal() {
    var o = S.opening, grid = $('#revealGrid');
    if (!o || !grid || grid.classList.contains('hidden')) return;
    var n = grid.querySelectorAll('.card').length; if (!n) return;
    grid.style.maxWidth = '';
    fitApply(n, grid.clientWidth, o.set.id === 'periodic' ? 1 : 7 / 5, grid.classList.contains('playing-3x3'));
  }
  function fitStagePre(set, n) {
    var stage = $('#stage'); if (!stage || !n || window.innerWidth > 900) return;
    var st = getComputedStyle(stage);
    var gridW = stage.clientWidth - (parseFloat(st.paddingLeft) || 0) - (parseFloat(st.paddingRight) || 0);
    gridW = Math.min(gridW, set.id === 'playing' ? 584 : 1000);
    var pick = fitSolve(n, gridW, set.id === 'periodic' ? 1 : 7 / 5, set.id === 'playing');
    if (pick) stage.style.minHeight = Math.round(Math.max(pick.total, 448)) + 'px';
  }
  window.addEventListener('resize', function () { fitReveal(); });
  /* FIT-END */

  function buildGrid(o) {
    var grid = $('#revealGrid');
    grid.classList.toggle('playing-3x3', o.set.id === 'playing');
    grid.innerHTML = o.pulls.map(function (p, i) {
      if (CPS.slips.isSlip(p)) return CPS.slips.render(p);
      var rset = p.homeSet || o.set;
      return CPS.cards.render(rset, p.card, { holo: p.holo, flippable: true, isNew: p.isNew, cls: 'deal',
        variant: p.variant ? { tier: p.variant, serial: p.serial } : null });
    }).join('');
    $$('.card', grid).forEach(function (el, i) {
      el.dataset.i = i; el.style.animationDelay = (i * 70) + 'ms';
      setTimeout(audio.deal, i * 70);
    });
    grid.classList.remove('hidden');
    $('#stageControls').classList.remove('hidden');
    $('#revealAllBtn').classList.remove('hidden');
    updateSummary();
    fitReveal();
  }

  function updateSummary() {
    var o = S.opening; if (!o) return;
    var n = o.revealed.filter(Boolean).length;
    if (!o.finished) { $('#stageSummary').innerHTML = 'Click a card to flip it · <b>' + n + ' / ' + o.pulls.length + '</b> revealed'; return; }
    $('#stageSummary').innerHTML = '';
  }

  function reveal(i) {
    var o = S.opening;
    if (!o || !o.torn || o.revealed[i]) return;
    o.revealed[i] = true;
    var el = $('#revealGrid').children[i], p = o.pulls[i];
    el.classList.remove('tease'); el.classList.add('flipped');
    audio.flip();
    if (CPS.slips.isSlip(p)) {
      var multiSlip = o.quick && o.pulls.filter(function (x) { return CPS.slips.isSlip(x); }).length > 1; /* Quick Open with several slips: the summary line reports the totals — don't strobe a banner per slip */
      setTimeout(function () { el.classList.add('glow'); if (!multiSlip) fx.banner(CPS.slips.banner(p), 'ticket', 2000); }, 300);
    } else {
      setTimeout(function () { el.classList.add('glow'); audio.reveal(p.card.rarity); flair(el, p); }, 300);
    }
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
      fx.banner(CPS.cards.VARIANTS[p.variant].emoji + ' ' + vt.name.toUpperCase() + ' #' + p.serial + '/' + vt.run + ' ' + CPS.cards.VARIANTS[p.variant].emoji, 'variant', 3200);
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
      var big = !CPS.slips.isSlip(o.pulls[i]) && R.INDEX[o.pulls[i].card.rarity] >= 3;
      if (big) await U.sleep(450);
      reveal(i);
      await U.sleep(big ? 900 : 160);
    }
    o.auto = false;
  }

  /* Quick Open: same roll as Open a pack, but skip the sealed-pack stage
     and flip every card at once — lands exactly where Reveal All ends. */
  async function startQuickOpen() {
    if ((S.opening && !S.opening.finished) || S.busy) return;
    if (S.set.id === 'jumbled') { if (CPS.jumbled) CPS.jumbled.quickOpen(); return; }
    if (await startOpen()) quickFinish();
  }
  function quickFinish() {
    var o = S.opening; if (!o || o.torn) return;
    o.torn = true; o.quick = true;
    $('#stagePack').classList.add('hidden');
    if (o.stuffedHero) fx.banner('STUFFED HERO PACK!', 'hero');
    else if (o.hero) fx.banner('HERO PACK!', 'hero');
    else if (o.stuffed) fx.banner('STUFFED PACK!', 'hero');
    buildGrid(o);
    $$('.card', $('#revealGrid')).forEach(function (el) { el.style.animationDelay = '0ms'; });
    o.auto = true;
    for (var i = 0; i < o.pulls.length; i++) { if (S.opening !== o) return; if (!o.revealed[i]) reveal(i); }
    o.auto = false;
  }

  function finish(o) {
    o.finished = true;
    updateSummary();
    CPS.slips.applyPackGrants(o.pulls);
    $('#revealAllBtn').classList.add('hidden');
    renderPacksSide();
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

  /* --- collection */
  /* Collection grid paging (2026-10-20 diet fix): the grid used to be
     built as ONE innerHTML burst of the whole set (420 full card
     renders). Phones survive that via content-visibility, but a
     browser that lays everything out at once (automation, very tall
     windows, find-in-page) hits a render cliff — the same cliff that
     killed the Stats gallery at 104 cards before it was chunked.
     The grid now renders COLL_PAGE cards at a time and appends the
     next chunk as the pager nears the viewport (or on demand via its
     button). Grid clicks are delegated on #collGrid, so appended
     chunks need no rebinding. Any fresh renderCollection (filter,
     search, sort, state refresh) resets paging to the first chunk. */
  var COLL_PAGE = 60;
  var collPage = { list: null, set: null, st: null, shown: 0, obs: null };
  function collCellHtml(c) {
    var set = collPage.set, st = collPage.st, e = st.cards[c.id];
    return CPS.cards.collected(set, c, onHand(e), onHandHolo(e), { v: e ? (e.v || 0) : 0, vh: e ? (e.vh || 0) : 0, turned: isTurned(set.id, c.id), total: e ? e.n : 0 });
  }
  function collPagerEl() {
    var grid = $('#collGrid'), p = $('#collPager');
    if (!p) {
      p = document.createElement('div');
      p.id = 'collPager';
      grid.parentNode.insertBefore(p, grid.nextSibling);
    }
    return p;
  }
  function appendCollChunk() {
    var list = collPage.list; if (!list) return;
    collPage.lastAppend = Date.now();
    var grid = $('#collGrid'), pager = collPagerEl();
    var end = Math.min(collPage.shown + COLL_PAGE, list.length);
    if (end > collPage.shown) {
      grid.insertAdjacentHTML('beforeend', list.slice(collPage.shown, end).map(collCellHtml).join(''));
      collPage.shown = end;
    }
    $('#collCount').textContent = collPage.shown < list.length
      ? collPage.shown + ' / ' + list.length + ' shown' : list.length + ' shown';
    if (collPage.shown < list.length) {
      pager.innerHTML = '<div style="text-align:center;padding:12px"><button class="btn" id="collMoreBtn">Show more cards (' + (list.length - collPage.shown) + ' more)</button></div>';
      $('#collMoreBtn').addEventListener('click', appendCollChunk);
      if (window.IntersectionObserver) {
        if (collPage.obs) collPage.obs.disconnect();
        collPage.obs = new IntersectionObserver(function (entries) {
          if (!entries.some(function (en) { return en.isIntersecting; })) return;
          /* Throttle the cascade (2026-10-21): on a fast phone the pager
             can still be within rootMargin the instant a chunk lands,
             re-firing immediately and bursting the whole set into the
             page at once. At most one auto-append per 350ms; the Show
             more button is never throttled. */
          var wait = 350 - (Date.now() - (collPage.lastAppend || 0));
          if (wait <= 0) appendCollChunk();
          else if (!collPage.throttleT) collPage.throttleT = setTimeout(function () { collPage.throttleT = null; appendCollChunk(); }, wait);
        }, { rootMargin: '600px' });
        collPage.obs.observe(pager);
      }
    } else {
      pager.innerHTML = '';
      if (collPage.obs) { collPage.obs.disconnect(); collPage.obs = null; }
    }
  }
  function resetCollPager() {
    if (collPage.obs) { collPage.obs.disconnect(); collPage.obs = null; }
    if (collPage.throttleT) { clearTimeout(collPage.throttleT); collPage.throttleT = null; }
    collPage.list = null; collPage.shown = 0;
    var p = $('#collPager'); if (p) p.innerHTML = '';
  }

  function renderCollection() {
    var set = S.set, st = ps(), f = S.coll;

    if (set.id === 'jumbled') {
      var rj = window.CardSets.get('jumbled');
      if (rj && !rj.stub && rj.cards.length) {
        set = rj; /* the Jumbled-only exclusives (mig. 169) DO have a collection */
      } else {
        if (rj && rj.stub && !rj._collRetry) { rj._collRetry = 1; window.CardSets.load('jumbled').then(function () { if (S.set.id === 'jumbled' && S.view === 'collection') renderCollection(); }); }
      $('#compTitle').textContent = 'Jumbled Mess';
      $('#compSub').textContent = 'Cards land in their home sets \u2014 no collection here.';
      $('#compRing').classList.remove('complete');
      $('#compRing').style.setProperty('--p', 0); $('#compPct').textContent = '\u2014';
      $('#rarityProgress').innerHTML = ''; $('#collGrid').innerHTML = '';
      resetCollPager();
      return;
      }
    }
    var owned = ownedCount(set, st), total = set.cards.length;
    var turnedN = 0, complete = 0;
    set.cards.forEach(function (c) { var t = isTurned(set.id, c.id); if (t) turnedN++; if (t || (st.cards[c.id] && st.cards[c.id].n > 0)) complete++; });
    var pct = total ? complete / total : 0;
    $('#compRing').style.setProperty('--p', (pct * 100).toFixed(1));
    $('#compRing').style.setProperty('--g', total ? (turnedN / total * 100).toFixed(1) : 0);
    $('#compPct').textContent = (pct * 100 >= 99.95 || pct === 0 ? Math.round(pct * 100) : (pct * 100).toFixed(1)) + '%';
    $('#compTitle').textContent = set.name;
    /* Pomp for a true completion (Franklin's definition: every card in
       the set TURNED IN): gold shimmer ring + a congrats line in place
       of the two amount lines. Owned-100% alone does not trigger it. */
    var done = total > 0 && turnedN === total;
    $('#compRing').classList.toggle('complete', done);
    $('#compSub').innerHTML = '<span class="packs-opened-note">Packs opened <b>' + st.stats.opened + '</b></span><br>' +
      (done
        ? '<span class="complete-note">Congrats! You\u2019ve completed this collection!</span>'
        : '<span class="owned-note">' + complete + ' / ' + total + ' unique cards owned (' + (pct * 100 >= 99.95 || pct === 0 ? Math.round(pct * 100) : (pct * 100).toFixed(1)) + '%)</span>' +
          '<br><span class="turned-note">' + turnedN + ' turned in (' + (total ? (turnedN / total * 100).toFixed(1) : '0.0') + '%)</span>');

    $('#rarityProgress').innerHTML = R.RARITIES.filter(function (r) { return set.pools[r.key].length; }).map(function (r) {
      var pool = set.pools[r.key], have = pool.filter(function (c) { return (st.cards[c.id] && st.cards[c.id].n) || isTurned(set.id, c.id); }).length;
      return '<button class="rp r-' + r.key + (f.rarity === r.key ? ' active' : '') + '" data-r="' + r.key + '">' +
        '<span class="rp-top"><span class="rp-name">' + r.label + '</span><span>' + have + '/' + pool.length + '</span></span>' +
        '<span class="bar"><i style="width:' + (have / pool.length * 100).toFixed(1) + '%"></i></span></button>';
    }).join('');

    $('#collSort').value = f.sort;
    var sel = $('#collRarity');
    sel.innerHTML = '<option value="">All rarities</option>' + R.RARITIES.filter(function (r) { return set.pools[r.key].length; })
      .map(function (r) { return '<option value="' + r.key + '">' + r.label + '</option>'; }).join('');
    sel.value = f.rarity;

    if (isCloud() && !S.myVariants) ensureVariants().then(function () {
      if (S.view !== 'collection') return;
      // Variants arrived: update the variants panel directly (as
      // renderView's hook does). Only the numbered filter's grid
      // depends on variant data — rebuilding all 420 cells here made
      // every first Collection entry render the grid twice.
      if (S.coll.own === 'numbered') renderCollection();
      else renderVariantsSection(set);
    });

    var q = f.q.trim().toLowerCase();
    var numberedIds = null;
    if (f.own === 'numbered') {
      numberedIds = {};
      (S.myVariants || []).forEach(function (v) { if (v.set_id === set.id) numberedIds[v.card_id] = 1; });
    }
    var list = set.cards.filter(function (c) {
      var e = st.cards[c.id], has = onHand(e) > 0;
      if (f.rarity && c.rarity !== f.rarity) return false;
      if (f.own === 'numbered' && !numberedIds[c.id]) return false;
      if (f.own === 'owned' && !has) return false;
      if (f.own === 'missing' && has) return false;
      if (f.own === 'dupes' && !(onHand(e) > 1)) return false;
      if (f.own === 'holo' && !(onHandHolo(e) > 0)) return false;
      if (f.own === 'fav' && !isFav(set.id, c.id)) return false;
      if (f.own === 'turned' && !isTurned(set.id, c.id)) return false;
      if (f.own === 'notturned' && isTurned(set.id, c.id)) return false;
      if (q) {
        var hay = c.name + ' ' + c.subtitle + ' ' + c.details + ' #' + U.pad(c.num, set.numWidth) + ' ' + c.num + ' ' + c.rarity;
        if (hay.toLowerCase().indexOf(q) < 0) return false;
      }
      return true;
    });
    var cnt = function (c) { return onHand(st.cards[c.id]); };
    if (f.sort === 'rarity') list.sort(function (a, b) { return R.INDEX[b.rarity] - R.INDEX[a.rarity] || a.num - b.num; });
    else if (f.sort === 'count') list.sort(function (a, b) { return cnt(b) - cnt(a) || a.num - b.num; });
    else if (f.sort === 'name') list.sort(function (a, b) { return a.name.localeCompare(b.name, undefined, { numeric: true }); });
    if (q) list.sort(function (a, b) { return (cnt(a) > 0 ? 0 : 1) - (cnt(b) > 0 ? 0 : 1); });

    resetCollPager();
    collPage.list = list; collPage.set = set; collPage.st = st;
    $('#collGrid').innerHTML = list.length ? '' : '<div class="empty">No cards match these filters.</div>';
    if (list.length) appendCollChunk();
    else $('#collCount').textContent = '0 shown';
    renderVariantsSection(set);
    var tb = $('#turnInAllBtn');
    if (tb) {
      var elig = isCloud() ? turnInPreview(set, st).eligible : 0;
      tb.classList.toggle('hidden', !elig);
      tb.textContent = 'Turn in cards from this set (' + elig + ')';
    }
    if (CPS.turninAll) CPS.turninAll.refresh();
  }

  function turnInPreview(set, st) {
    var vmap = variantCountMap(), p = { eligible: 0, holoOnly: 0, onlyCopy: 0, locked: 0 };
    set.cards.forEach(function (c) {
      if (isTurned(set.id, c.id)) return;
      var e = st.cards[c.id]; if (!e || !e.n) return;
      var vn = vmap[set.id + ':' + c.id] || 0;
      if (e.n - (e.v || 0) - vn < 1) { p.locked++; return; }
      p.eligible++;
      if ((e.n - e.h) - ((e.v || 0) - (e.vh || 0)) < 1) p.holoOnly++;
      if (e.n - (e.v || 0) === 1) p.onlyCopy++;
    });
    return p;
  }

  var confirmDismiss = null; /* while a confirmDialog is open, closeModal() fires this so backdrop/Escape dismiss as null (abort) instead of hanging the promise */
  function confirmDialog(title, bodyHtml, okLabel, cancelLabel) {
    return new Promise(function (resolve) {
      var done = false;
      openModal('<button class="modal-x" data-close aria-label="Close">×</button><h2>' + esc(title) + '</h2>' +
        '<div class="confirm-body">' + bodyHtml + '</div>' +
        '<div class="confirm-btns"><button class="btn" data-cx>' + esc(cancelLabel || 'Cancel') + '</button>' +
        '<button class="btn primary" data-ok>' + esc(okLabel || 'Confirm') + '</button></div>',
        function (box) {
          function fin(v) { if (done) return; done = true; confirmDismiss = null; closeModal(); resolve(v); }
          confirmDismiss = function () { fin(null); };
          box.querySelector('[data-ok]').addEventListener('click', function () { fin(true); });
          box.querySelector('[data-cx]').addEventListener('click', function () { fin(false); });
          box.querySelector('[data-close]').addEventListener('click', function () { fin(null); });
        });
    });
  }

  async function turnInAllFlow() {
    var set = S.set, st = ps();
    if (set && set.id === 'jumbled') { var rjT = window.CardSets.get('jumbled'); if (rjT && !rjT.stub && rjT.cards.length) set = rjT; }
    if (!isCloud() || !set || (set.id === 'jumbled' && !set.cards.length)) return;
    await ensureVariants();
    var p = turnInPreview(set, st);
    if (!p.eligible) { toast('Nothing to turn in — everything owned here is already turned in, vaulted, or numbered.', 'warn'); return; }
    var ok = await confirmDialog('Turn in one of every card in ' + set.name,
      '<p>Turn in <b>one copy of every card you own</b> in ' + set.name + ' — <b>' + p.eligible + '</b> card' + (p.eligible === 1 ? '' : 's') + ' total, including cards you only have one copy of.</p>' +
      '<p class="muted">Turning in destroys a copy and marks the card <b>permanently collected</b>: it counts toward your completion forever, even if you never own it again. <b>There is no undo.</b></p>' +
      (p.onlyCopy ? '<p class="muted">' + p.onlyCopy + ' of these ' + (p.onlyCopy === 1 ? 'is' : 'are') + ' your <b>only on-hand copy</b>.</p>' : '') +
      (p.locked ? '<p class="muted">' + p.locked + ' card' + (p.locked === 1 ? '' : 's') + ' skipped — only vaulted or numbered copies on hand.</p>' : ''),
      'Turn them in');
    if (!ok) return;
    var includeHolos = false;
    if (p.holoOnly > 0) {
      includeHolos = await confirmDialog('Holographic cards',
        '<p>Some of these cards are holographic — for <b>' + p.holoOnly + '</b> of them, the only copy that can be turned in is a holo.</p>' +
        '<p class="muted">Do you still want to turn these in?</p>',
        'Yes, turn in the holos too', 'Skip the holos');
    }
    if (includeHolos === null) return; /* holo dialog dismissed = abort the whole turn-in */
    try {
      var r = await CPS.cloud.call('turn_in_all', { p_set: set.id, p_include_holos: includeHolos });
      await refreshCloud();
      toast('✓ Turned in ' + r.turned + ' card' + (r.turned === 1 ? '' : 's') + '!' +
        (r.skipped_holo ? ' Skipped ' + r.skipped_holo + ' holo-only.' : '') +
        (r.skipped_locked ? ' Skipped ' + r.skipped_locked + ' locked.' : ''), 'good', 5000);
      if (CPS.turninRewards) CPS.turninRewards.announce(set.id, r.turnin_rewards);
    } catch (e) { cloudError(e); }
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
        '<div class="vserial-cap"><b>' + esc(CPS.cards.VARIANTS[v.tier].name) + ' #' + v.serial + '/' + CPS.cards.VARIANTS[v.tier].run + '</b>' + (v.vaulted ? ' <span class="vault-tag">🔒 Vault</span>' : '') + '</div></div>';
    }).join('');
    grid.querySelectorAll('[data-variant-card]').forEach(function (el) { el.addEventListener('click', function () { var v = mine.filter(function (x) { return x.card_id === el.dataset.variantCard; })[0]; openCardModal(set.id, el.dataset.variantCard, null, v ? { tier: v.tier, serial: v.serial } : null); }); });
  }

  /* --- dupe trade-in */
  var DUPE_RARS = { common: ['common'], uncommon: ['uncommon'], rare: ['rare'], epic: ['epic', 'legendary', 'chase'] };
  
  
  function variantCountMap() {
    var m = {};
    (S.myVariants || []).forEach(function (v) {
      if (v.vaulted) return;
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
      out[t] += Math.max(0, (e.n - (e.v || 0)) - Math.max(1, v));
    });
    return out;
  }

  /* --- collapsible panels */
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

  /* --- turn-ins + the Vault */
  function isTurned(setId, cardId) { return !!(S.turnedIn && S.turnedIn[setId + ':' + cardId]); }
  function onHand(e) { return e ? Math.max(0, e.n - (e.v || 0)) : 0; }
  function onHandHolo(e) { return e ? Math.max(0, e.h - (e.vh || 0)) : 0; }

  /* --- favorites (the Vault) */
  function favKey(setId, cardId) { return setId + ':' + cardId; }
  function isFav(setId, cardId) {
    return !!(S.favorites && S.favorites[favKey(setId, cardId)]);
  }
  function favCount() {
    return S.favorites ? Object.keys(S.favorites).length : 0;
  }
  async function toggleFavorite(setId, cardId, holo) {
    var k = favKey(setId, cardId);
    if (isCloud()) {
      try {
        var r = await CPS.cloud.call('toggle_favorite', { p_set: setId, p_card: cardId });
        if (r.favorited) S.favorites[k] = true; else delete S.favorites[k];
        toast(r.favorited ? 'Vaulted a copy — it is protected now. 🔒' : 'Released a copy from your Vault.', 'good');
      } catch (e) { cloudError(e); return; }
    }
    openCardModal(setId, cardId, holo); // re-render the modal button
    if (S.view === 'collection') renderCollection();
  }

  /* --- players */
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
      var _pt = await Promise.all([CPS.cloud.call('list_players'), CPS.cloud.call('list_trades')]);
      var players = _pt[0], trades = _pt[1];
      renderTrades(trades);
      if (CPS.playersDir) { CPS.playersDir.render(players); return; }
      box.innerHTML = players.map(function (p) {
        return '<button class="player-card" data-player="' + esc(p.id) + '">' +
          '<span class="avatar">' + esc((p.display_name[0] || 'P').toUpperCase()) + '</span>' +
          '<span class="player-meta"><span class="player-name-row"><b>' + esc(p.display_name) + '</b>' +
          (p.is_me ? '<span class="pill pill-you">You</span>' : '') + '</span>' +
          '<span class="muted small">' + p.favorites + ' in Vault · ' + p.unique_cards + ' unique cards</span></span>' +
          '<span class="player-go">›</span></button>';
      }).join('') || '<div class="empty">No players yet.</div>';
    } catch (e) { cloudError(e); }
  }
  function ownedSetIds() {
    var ids = [];
    Object.keys((S.player && S.player.sets) || {}).forEach(function (id) {
      var st = S.player.sets[id];
      if (st && ((st.cards && Object.keys(st.cards).length) || (st.stats && st.stats.pulled > 0))) ids.push(id);
    });
    return ids;
  }
  function ensureOwnedSets() {
    return window.CardSets.loadIds ? window.CardSets.loadIds(ownedSetIds()) : Promise.resolve();
  }

  /* One shared list_notifications fetch: the bell badge and the gift
     pop-up poller used to each pull the full list on their own 60s
     cadences (list_notifications is the #3 RPC consumer all-time).
     Single-flight + a 10s cache collapses the duplicates; the badge
     tick also nudges the gift poller so there is one fetch per cycle. */
  var _notifFlight = null, _notifCache = null, _notifCacheAt = 0;
  function fetchNotifications() {
    if (_notifFlight) return _notifFlight;
    if (_notifCache && Date.now() - _notifCacheAt < 10000) return Promise.resolve(_notifCache);
    _notifFlight = CPS.cloud.call('list_notifications').then(function (n) {
      _notifCache = n; _notifCacheAt = Date.now(); _notifFlight = null;
      return n;
    }, function (e) { _notifFlight = null; throw e; });
    return _notifFlight;
  }
  async function refreshNotifBadge() {
    if (!isCloud()) return;
    try {
      var n = await fetchNotifications();
      var b = $('#notifBadge');
      b.textContent = n.unread > 99 ? '99+' : n.unread;
      b.classList.toggle('hidden', !n.unread);
    } catch (e) {  }
    if (CPS.giftPop && CPS.giftPop.check) CPS.giftPop.check();
  }

  /* --- variants */
  var VARIANT_ORDER = ['oneofone', 'obsidian', 'prism', 'rainbow'];

  async function ensureVariants() {
    if (!isCloud()) return [];
    if (!S.myVariants) {
      try { S.myVariants = await CPS.cloud.call('list_variants', {}); }
      catch (e) { S.myVariants = []; }
    }
    return S.myVariants;
  }
  /* --- trading */
  var TB = null; // trade builder state

  function tbStateOf(set) { return S.player.sets[set.id] || { cards: {} }; }

  // my owned cards as flat [{set_id, card_id, n, h}]
  function tbMyCollection() {
    var out = [];
    window.CardSets.all().forEach(function (set) {
      var st = tbStateOf(set);
      set.cards.forEach(function (card) {
        var e = st.cards[card.id];
        if (e && onHand(e) > 0) out.push({ set_id: set.id, card_id: card.id, n: onHand(e), h: onHandHolo(e) });
      });
    });
    return out;
  }

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


  function tradeMiniCard(setId, cardId, holo, qty, variant) {
    var set = window.CardSets.get(setId), card = set && set.byId.get(cardId);
    if (!set || !card) return '<span class="muted">?</span>';
    return '<div class="trade-card">' + CPS.cards.render(set, card, { holo: !!holo, count: qty > 1 ? qty : 0, variant: variant || null }) + '</div>';
  }
  function tradeItemsHtml(items, packSet, packQty, tokens, tickets) {
    var h = '<div class="trade-items">' + (items || []).map(function (it) {
      return tradeMiniCard(it.set_id, it.card_id, it.holo, it.qty, it.tier ? { tier: it.tier, serial: it.serial } : null);
    }).join('');
    if (packQty > 0 && packSet) {
      var set = window.CardSets.get(packSet);
      if (set) h += '<div class="trade-card">' + CPS.cards.pack(set) +
        '<div class="trade-cap"><b>🎁 ' + packQty + ' pack' + (packQty === 1 ? '' : 's') + '</b></div></div>';
    }
    if (tokens > 0) h += '<div class="trade-card"><div class="trade-cap"><b>🪙 ' + tokens + ' token' + (tokens === 1 ? '' : 's') + '</b></div></div>';
    if (tickets > 0) h += '<div class="trade-card"><div class="trade-cap"><b>🎟️ ' + tickets + ' ticket' + (tickets === 1 ? '' : 's') + '</b></div></div>';
    return h + '</div>';
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
    var nGive = (t.direction === 'incoming' ? t.want_items : t.offer_items || []).reduce(function (s, it) { return s + (it.qty || 1); }, 0) +
      (t.direction === 'incoming' ? (t.want_packs || 0) : (t.offer_packs || 0)) +
      ((t.direction === 'incoming' ? t.want_tokens : t.offer_tokens) > 0 ? 1 : 0) + ((t.direction === 'incoming' ? t.want_tickets : t.offer_tickets) > 0 ? 1 : 0);
    var nGet = (t.direction === 'incoming' ? t.offer_items : t.want_items || []).reduce(function (s, it) { return s + (it.qty || 1); }, 0) +
      (t.direction === 'incoming' ? (t.offer_packs || 0) : (t.want_packs || 0)) +
      ((t.direction === 'incoming' ? t.offer_tokens : t.want_tokens) > 0 ? 1 : 0) + ((t.direction === 'incoming' ? t.offer_tickets : t.want_tickets) > 0 ? 1 : 0);
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
      tradeItemsHtml(t.offer_items, t.offer_pack_set, t.offer_packs, t.offer_tokens, t.offer_tickets) + '</div>' +
      '<span class="trade-swap">\u21c4</span><div class="trade-side"><span class="trade-cap-top">' + rightCap + '</span>' +
      tradeItemsHtml(t.want_items, t.want_pack_set, t.want_packs, t.want_tokens, t.want_tickets) + '</div></div>' +
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
      var rr = await CPS.cloud.call('respond_trade', { p_offer: id, p_accept: accept });
      if (rr && rr.status === 'unavailable') {
        toast((rr && rr.message) || 'That trade is no longer available.', 'warn');
        renderPlayers();
        return;
      }
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

  /* --- trade builder view */
  async function openTradeBuilder(prefillTo) {
    if (!isCloud()) return;
    openModal('<div class="muted" style="padding:24px">Loading…</div>');
    if (window.CardSets.loadAll) await window.CardSets.loadAll();
    try {
      var players = await CPS.cloud.call('list_players');
      var others = players.filter(function (p) { return !p.is_me; });
      if (!others.length) {
        openModal('<button class="modal-x" data-close aria-label="Close">\u00d7</button><div class="empty" style="padding:24px">No other players to trade with yet.</div>');
        return;
      }
      var to = prefillTo && others.some(function (p) { return p.id === prefillTo; }) ? prefillTo : others[0].id;
      TB = { to: to, step: 1, their: [], theirPacks: [], toName: '', setId: '', q: '', rarity: '',
             picks: [], offer: [], want: [], offerPack: null, wantPack: null, packSet: '', packs: 0,
             offerMoney: null, wantMoney: null, tokens: 0, tickets: 0, myColl: tbMyCollection() };
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
      TB.theirPacks = p.pack_inventory || [];
      TB.toName = p.display_name;
    } catch (e) { TB.their = []; TB.toName = ''; cloudError(e); }
    TB.step = 1; TB.picks = []; TB.offer = []; TB.want = [];
    TB.offerPack = null; TB.wantPack = null; TB.packSet = ''; TB.packs = 0;
    TB.offerMoney = null; TB.wantMoney = null; TB.tokens = 0; TB.tickets = 0;
    TB.setId = ''; TB.q = ''; TB.rarity = '';
    $('#tradeSearch').value = '';
    renderTradeBuilder();
  }

  function renderTradeBuilder() {
    if (!TB) return;
    var steps = ['Your offer', TB.toName ? 'Pick from ' + TB.toName : 'Their card', 'Review'];
    $('#tradeSteps').innerHTML = steps.map(function (s, i) {
      var n = i + 1;
      var done = n < TB.step;
      return '<span class="tstep' + (n === TB.step ? ' active' : done ? ' done' : '') + '"' +
        (done ? ' data-tstep="' + n + '" title="Go back and edit" style="cursor:pointer"' : '') + '>' + n + '. ' + esc(s) + '</span>';
    }).join('');
    $('#tradeSteps').querySelectorAll('[data-tstep]').forEach(function (el) {
      el.addEventListener('click', function () { tbGotoStep(+el.getAttribute('data-tstep')); });
    });
    $('#tradeTitle').textContent = TB.step === 1 ? 'Choose your offer' : TB.step === 2 ? 'Choose what you want' : 'Review trade';
    $('#tradeReview').classList.add('hidden');
    $('#tradeGrid').classList.remove('hidden');
    if (TB.step === 3) {
      if (CPS.tradeCopies) CPS.tradeCopies.hide();
      renderTradeReview();
      return;
    }
    $('#tradeFilters').classList.remove('hidden');
    $('#tradePackBar').classList.remove('hidden');
    tbRenderPackBar();
    $('#tradeMoneyBar').classList.remove('hidden');
    tbRenderMoneyBar();
    var groups = TB.step === 1 ? tbGroup(TB.myColl) : tbGroup(TB.their);
    /* Trades browse one set at a time (Franklin, 2026-10-24): there is no
       All sets mode. Keep the chosen set while it exists on this side of
       the trade; otherwise start with the first set alphabetically. */
    if (!groups.some(function (g) { return g.set.id === TB.setId; })) {
      TB.setId = groups.length ? groups[0].set.id : '';
    }
    $('#tradeSetSel').innerHTML = groups.map(function (g) {
      return '<option value="' + esc(g.set.id) + '"' + (g.set.id === TB.setId ? ' selected' : '') + '>' +
        esc(g.set.name) + ' (' + (g.total || g.cards.length) + ')</option>';
    }).join('');
    tbRenderGrid(groups);
  }

  // 180: one pack bundle per side (one set + a quantity), Market-style.
  // The pack bar edits a per-step scratch (TB.packSet/TB.packs), synced
  // into TB.offerPack / TB.wantPack as it changes.
  function tbPackInventory() {
    if (TB.step === 1) {
      var sets = (S.player && S.player.sets) || {};
      return Object.keys(sets).filter(function (id) { return id !== 'jumbled' && sets[id].packs > 0; })
        .map(function (id) { return { set_id: id, packs: sets[id].packs }; });
    }
    return TB.theirPacks || [];
  }
  function tbPackAvail(setId) {
    var inv = tbPackInventory();
    for (var i = 0; i < inv.length; i++) if (inv[i].set_id === setId) return inv[i].packs;
    return 0;
  }
  function tbCurrentPack() { return TB.step === 1 ? TB.offerPack : TB.wantPack; }
  function tbSyncPackScratch() {
    var b = (TB.packSet && TB.packs > 0) ? { set: TB.packSet, qty: TB.packs } : null;
    if (TB.step === 1) TB.offerPack = b; else if (TB.step === 2) TB.wantPack = b;
  }
  function tbRenderPackBar() {
    var bar = $('#tradePackBar'); if (!bar) return;
    var saved = tbCurrentPack();
    if (saved) { TB.packSet = saved.set; TB.packs = saved.qty; }
    var inv = tbPackInventory();
    if (!inv.some(function (x) { return x.set_id === TB.packSet; })) { TB.packSet = ''; TB.packs = 0; tbSyncPackScratch(); }
    $('#tradePackSet').innerHTML = '<option value="">\u2014 no packs \u2014</option>' + inv.map(function (x) {
      var s = window.CardSets.get(x.set_id);
      return '<option value="' + esc(x.set_id) + '"' + (x.set_id === TB.packSet ? ' selected' : '') + '>' +
        esc(s ? s.name : x.set_id) + ' (' + x.packs + ')</option>';
    }).join('');
    var qty = $('#tradePackQty');
    qty.disabled = !TB.packSet;
    qty.max = TB.packSet ? tbPackAvail(TB.packSet) : '';
    qty.value = TB.packs || 0;
    $('#tradePackHave').textContent = TB.packSet
      ? (TB.step === 1 ? 'you have ' : 'they have ') + tbPackAvail(TB.packSet) + ' unopened'
      : 'add unopened packs to this side of the trade';
  }

  // 184: one currency bundle per side (tokens + tickets), edited via a
  // per-step scratch (TB.tokens / TB.tickets) synced into
  // TB.offerMoney / TB.wantMoney exactly like the pack bundle. The
  // sender's currency escrows at propose time (server-side).
  function tbCurrentMoney() { return TB.step === 1 ? TB.offerMoney : TB.wantMoney; }
  function tbMoneyText(m) {
    if (!m) return '';
    var bits = [];
    if (m.tokens > 0) bits.push('🪙 ' + m.tokens + ' token' + (m.tokens === 1 ? '' : 's'));
    if (m.tickets > 0) bits.push('🎟️ ' + m.tickets + ' ticket' + (m.tickets === 1 ? '' : 's'));
    return bits.join(' + ');
  }
  function tbSyncMoneyScratch() {
    var m = (TB.tokens > 0 || TB.tickets > 0) ? { tokens: TB.tokens || 0, tickets: TB.tickets || 0 } : null;
    if (TB.step === 1) TB.offerMoney = m; else if (TB.step === 2) TB.wantMoney = m;
  }
  function tbRenderMoneyBar() {
    var bar = $('#tradeMoneyBar'); if (!bar) return;
    var saved = tbCurrentMoney();
    TB.tokens = saved ? saved.tokens : 0;
    TB.tickets = saved ? saved.tickets : 0;
    var tok = $('#tradeTokens'), tic = $('#tradeTickets');
    tok.value = TB.tokens || 0; tic.value = TB.tickets || 0;
    if (TB.step === 1) {
      tok.max = S.gameTokens || 0; tic.max = S.spins || 0;
      $('#tradeMoneyHave').textContent = 'you have 🪙 ' + (S.gameTokens || 0) + ' · 🎟️ ' + (S.spins || 0) + ' — yours escrow when you send';
    } else {
      tok.removeAttribute('max'); tic.removeAttribute('max');
      $('#tradeMoneyHave').textContent = 'they pay this if they accept';
    }
  }

  /* Trade grid paging (2026-10-24): the builder used to render EVERY owned
     card at once \u2014 12,074 unique cards for the biggest collection \u2014 and
     hard-froze the client the moment it opened. Same cure as the Collection
     grid: TB_PAGE cards at a time, throttled auto-append on scroll plus a
     Show more button. The signature resets paging when step/partner/filters
     change; re-renders for pick changes keep the expanded depth. */
  var TB_PAGE = 60;
  var tbPage = { list: null, sig: '', shown: 0, obs: null, throttleT: null, lastAppend: 0 };
  function tbCardHtml(it) {
    var sel = TB.picks.some(function (p) { return p.setId === it.set.id && p.cardId === it.card.id && !p.tier; });
    return '<button class="trade-pick' + (sel ? ' selected' : '') + '" data-set="' + esc(it.set.id) +
      '" data-card="' + esc(it.card.id) + '">' + CPS.cards.collected(it.set, it.card, it.n, it.h) + '</button>';
  }
  function tbSyncPager() {
    var old = $('#tradeMoreBtn');
    if (old) old.remove();
    if (tbPage.obs) { tbPage.obs.disconnect(); tbPage.obs = null; }
    $('#tradeCount').textContent = tbPage.shown < tbPage.list.length
      ? tbPage.shown + ' / ' + tbPage.list.length + ' shown' : tbPage.list.length + ' shown';
    if (tbPage.shown >= tbPage.list.length) return;
    $('#tradeGrid').insertAdjacentHTML('beforeend',
      '<button class="btn" id="tradeMoreBtn" style="grid-column:1/-1">Show more cards (' + (tbPage.list.length - tbPage.shown) + ' more)</button>');
    var btn = $('#tradeMoreBtn');
    btn.addEventListener('click', function () { tbAppendChunk(); });
    if (window.IntersectionObserver) {
      tbPage.obs = new IntersectionObserver(function (entries) {
        if (!entries.some(function (en) { return en.isIntersecting; })) return;
        var wait = 350 - (Date.now() - (tbPage.lastAppend || 0));
        if (wait <= 0) tbAppendChunk();
        else if (!tbPage.throttleT) tbPage.throttleT = setTimeout(function () { tbPage.throttleT = null; tbAppendChunk(); }, wait);
      }, { rootMargin: '600px' });
      tbPage.obs.observe(btn);
    }
  }
  function tbAppendChunk() {
    if (!TB || !tbPage.list || tbPage.shown >= tbPage.list.length) return;
    tbPage.lastAppend = Date.now();
    var end = Math.min(tbPage.shown + TB_PAGE, tbPage.list.length);
    var btn = $('#tradeMoreBtn'); if (btn) btn.remove();
    $('#tradeGrid').insertAdjacentHTML('beforeend', tbPage.list.slice(tbPage.shown, end).map(tbCardHtml).join(''));
    tbPage.shown = end;
    tbSyncPager();
  }
  function tbRenderGrid(groups) {
    groups = groups || (TB.step === 1 ? tbGroup(TB.myColl) : tbGroup(TB.their));
    if (!groups.some(function (g) { return g.set.id === TB.setId; })) {
      TB.setId = groups.length ? groups[0].set.id : '';
      var setSel = $('#tradeSetSel'); if (setSel) setSel.value = TB.setId;
    }
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
    var sig = TB.step + '|' + TB.to + '|' + TB.setId + '|' + TB.rarity + '|' + q;
    if (sig !== tbPage.sig) { tbPage.sig = sig; tbPage.shown = TB_PAGE; }
    tbPage.list = list;
    if (tbPage.shown > list.length) tbPage.shown = list.length;
    if (!list.length) {
      if (tbPage.obs) { tbPage.obs.disconnect(); tbPage.obs = null; }
      $('#tradeCount').textContent = '0 shown';
      $('#tradeGrid').innerHTML = '<div class="empty">' + (TB.step === 1 ? 'You don\'t own any cards yet.' : esc(TB.toName) + ' doesn\'t own any cards yet.') + '</div>';
    } else {
      $('#tradeGrid').innerHTML = list.slice(0, tbPage.shown).map(tbCardHtml).join('');
      tbSyncPager();
    }
    tbRenderDock();
    if (CPS.tradeCopies) CPS.tradeCopies.render(TB, tbRenderGrid);
  }
  function tbRenderDock() {
    var dock = $('#tradeDock');
    var pack = tbCurrentPack();
    var money = tbCurrentMoney();
    if (TB.step === 3 || (!TB.picks.length && !pack && !money)) { dock.classList.add('hidden'); return; }
    dock.classList.remove('hidden');
    $('#tradeChips').innerHTML = TB.picks.map(function (p, i) {
      var set = window.CardSets.get(p.setId), card = set && set.byId.get(p.cardId);
      if (!set || !card) return '';
      var tv = p.tier ? { tier: p.tier, serial: p.serial } : null;
      return '<span class="trade-chip"><b>' + esc(card.name) + '</b>' +
        (tv ? '<span class="chip-variant" title="' + esc(CPS.cards.variantLabel(tv.tier, tv.serial)) + ' travels with this card">' + CPS.cards.VARIANTS[tv.tier].emoji + ' #' + tv.serial + '</span>' : '') +
        (p.h > 0 ? '<button class="chip-holo' + (p.holo ? ' on' : '') + '" data-chip-holo="' + i + '" title="Toggle holographic">\u2726</button>' : '') +
        '<button class="chip-x" data-chip-x="' + i + '" title="Remove">\u00d7</button></span>';
    }).join('') + (!pack ? '' : (function () {
      var pset = window.CardSets.get(pack.set);
      return '<span class="trade-chip"><b>🎁 ' + pack.qty + ' \u00d7 ' + esc(pset ? pset.name : pack.set) +
        ' pack' + (pack.qty === 1 ? '' : 's') + '</b>' +
        '<button class="chip-x" data-pack-x title="Remove packs">\u00d7</button></span>';
    })()) + (!money ? '' :
      '<span class="trade-chip"><b>' + tbMoneyText(money) + '</b>' +
      '<button class="chip-x" data-money-x title="Remove currency">\u00d7</button></span>');
    $('#tradeContinueBtn').innerHTML = (TB.step === 1 ? 'Continue \u2192 pick their card' : 'Continue \u2192 review') +
      ' (' + TB.picks.length + '/10' + (pack ? ' + 🎁' + pack.qty : '') + (money ? ' + 💰' : '') + ')';
  }

  function tbContinue() {
    if (!TB || TB.step === 3) return;
    if (!TB.picks.length && !tbCurrentPack() && !tbCurrentMoney()) return;
    tbGotoStep(TB.step + 1);
  }

  /* The builder's one navigator: Continue, the step pills and the
     review screen's Edit buttons all come through here. The current
     step's in-progress picks are saved to their side first, and the
     destination step re-seeds its picks (and, via tbRenderPackBar, its
     pack bundle) from what was saved — going back no longer wipes the
     other side. */
  function tbGotoStep(n) {
    if (!TB || n === TB.step || n < 1 || n > 3) return;
    if (TB.step === 1) TB.offer = TB.picks;
    else if (TB.step === 2) TB.want = TB.picks;
    TB.step = n;
    TB.picks = n === 1 ? TB.offer.slice() : n === 2 ? TB.want.slice() : [];
    TB.setId = ''; TB.q = ''; TB.rarity = ''; TB.packSet = ''; TB.packs = 0;
    $('#tradeSearch').value = '';
    renderTradeBuilder();
    window.scrollTo(0, 0);
  }

  function renderTradeReview() {
    $('#tradeFilters').classList.add('hidden');
    $('#tradePackBar').classList.add('hidden');
    $('#tradeMoneyBar').classList.add('hidden');
    $('#tradeGrid').classList.add('hidden');
    $('#tradeDock').classList.add('hidden');
    function packTile(bundle) {
      if (!bundle) return '';
      var set = window.CardSets.get(bundle.set);
      if (!set) return '';
      return '<div class="trade-card">' + CPS.cards.pack(set) +
        '<div class="trade-cap"><b>🎁 ' + bundle.qty + ' pack' + (bundle.qty === 1 ? '' : 's') + '</b>' +
        '<span class="muted small">' + esc(set.name) + '</span></div></div>';
    }
    function cardsHtml(picks, mine, pack) {
      return '<div class="trade-review-cards">' + picks.map(function (p) {
        var set = window.CardSets.get(p.setId), card = set && set.byId.get(p.cardId);
        if (!set || !card) return '';
        var tv = p.tier ? { tier: p.tier, serial: p.serial } : null;
        return '<div class="trade-card">' + CPS.cards.render(set, card, { holo: p.holo, variant: tv }) +
          '<div class="trade-cap"><b>' + esc(card.name) + '</b><span class="muted small">' + esc(set.name) +
          (p.holo ? ' \u00b7 \u2726 holo' : '') +
          (tv ? ' \u00b7 ' + CPS.cards.VARIANTS[tv.tier].emoji + ' #' + tv.serial + '/' + CPS.cards.VARIANTS[tv.tier].run : '') + '</span></div></div>';
      }).join('') + packTile(pack) + '</div>';
    }
    var box = $('#tradeReview');
    box.classList.remove('hidden');
    box.innerHTML = '<div class="trade-review-group"><span class="trade-cap-top">You give (' + (TB.offer.length + (TB.offerPack ? TB.offerPack.qty : 0)) + ')</span>' +
      cardsHtml(TB.offer, true, TB.offerPack) +
      (TB.offerMoney ? '<div class="muted small" style="margin-top:6px">' + tbMoneyText(TB.offerMoney) + '</div>' : '') +
      '<button class="btn small" id="tradeEditOffer" style="margin-top:8px">Edit your offer</button></div>' +
      '<div class="trade-review-swap">\u21c4</div>' +
      '<div class="trade-review-group"><span class="trade-cap-top">You get (' + (TB.want.length + (TB.wantPack ? TB.wantPack.qty : 0)) + ')</span>' +
      cardsHtml(TB.want, false, TB.wantPack) +
      (TB.wantMoney ? '<div class="muted small" style="margin-top:6px">' + tbMoneyText(TB.wantMoney) + '</div>' : '') +
      '<button class="btn small" id="tradeEditWant" style="margin-top:8px">Edit what you get</button></div>' +
      ((TB.offerPack || TB.offerMoney) ? '<p class="muted small" style="grid-column:1/-1">🔒 Held in escrow when you send this offer: your ' +
        [TB.offerPack ? 'packs' : '', TB.offerMoney ? 'tokens/tickets' : ''].filter(Boolean).join(' and ') +
        ' — delivered if ' + esc(TB.toName) + ' accepts, and returned if they decline, or if the offer is cancelled or expires.</p>' : '') +
      '<div class="trade-review-actions"><button class="btn" id="tradeStartOver">Start over</button>' +
      '<button class="btn primary" id="tradeSendBtn">Send offer to ' + esc(TB.toName) + '</button></div>';
    $('#tradeEditOffer').addEventListener('click', function () { tbGotoStep(1); });
    $('#tradeEditWant').addEventListener('click', function () { tbGotoStep(2); });
    $('#tradeStartOver').addEventListener('click', function () {
      TB.step = 1; TB.offer = []; TB.want = []; TB.picks = [];
      TB.offerPack = null; TB.wantPack = null; TB.packSet = ''; TB.packs = 0;
      TB.offerMoney = null; TB.wantMoney = null; TB.tokens = 0; TB.tickets = 0;
      renderTradeBuilder(); window.scrollTo(0, 0);
    });
    $('#tradeSendBtn').addEventListener('click', async function () {
      var btn = this; btn.disabled = true;
      try {
        await CPS.cloud.call('propose_trade', {
          p_to: TB.to,
          p_offer: { cards: TB.offer.map(function (p) { return { set: p.setId, card: p.cardId, holo: p.holo, tier: p.tier, serial: p.serial }; }),
                     pack_set: TB.offerPack ? TB.offerPack.set : null, packs: TB.offerPack ? TB.offerPack.qty : 0,
                     tokens: TB.offerMoney ? TB.offerMoney.tokens : 0, tickets: TB.offerMoney ? TB.offerMoney.tickets : 0 },
          p_want: { cards: TB.want.map(function (p) { return { set: p.setId, card: p.cardId, holo: p.holo, tier: p.tier, serial: p.serial }; }),
                    pack_set: TB.wantPack ? TB.wantPack.set : null, packs: TB.wantPack ? TB.wantPack.qty : 0,
                    tokens: TB.wantMoney ? TB.wantMoney.tokens : 0, tickets: TB.wantMoney ? TB.wantMoney.tickets : 0 }
        });
        toast('Trade offer sent to ' + TB.toName + '!');
        showView('players');
      } catch (e) { cloudError(e); btn.disabled = false; }
    });
  }



  function vaultButtonsHtml(set, card, e, variant) {
    if (!isCloud() || !e || !(e.n > 0)) return '';
    var v = e.v || 0, vh = e.vh || 0;
    var plainOn = (e.n - e.h) - (v - vh), holoOn = e.h - vh, plainV = v - vh;
    var h = '<div class="vault-box"><div class="vault-title">🔒 The Vault</div>';
    if (plainOn > 0) h += '<button class="btn small" data-vault="plain">Vault a plain copy</button>';
    if (plainV > 0) h += '<button class="btn small" data-unvault="plain">Release plain (' + plainV + ' vaulted)</button>';
    if (holoOn > 0) h += '<button class="btn small" data-vault="holo">Vault a holo copy</button>';
    if (vh > 0) h += '<button class="btn small" data-unvault="holo">Release holo (' + vh + ' vaulted)</button>';
    if (variant) {
      var inst = (S.myVariants || []).filter(function (x) { return x.set_id === set.id && x.card_id === card.id && x.tier === variant.tier && x.serial === variant.serial; })[0];
      if (inst) h += '<button class="btn small" data-vault-variant="' + inst.id + '" data-von="' + (inst.vaulted ? '0' : '1') + '">' + (inst.vaulted ? 'Release this numbered copy' : 'Vault this numbered copy') + '</button>';
    }
    h += '<div class="muted small">Vaulted copies are protected — they can\'t be traded, gifted, sold, or turned in until released.</div></div>';
    if (!isTurned(set.id, card.id)) {
      var vn = (S.myVariants || []).filter(function (x) { return x.set_id === set.id && x.card_id === card.id; }).length;
      if (e.n - v - vn > 0) h += '<button class="btn small turnin-btn" data-turnin>✓ Turn in this card</button>';
      else h += '<div class="muted small">No copy can be turned in — the rest are vaulted or numbered.</div>';
    }
    return h;
  }

  async function turnInFlow(setId, cardId, forceHolo, variant) {
    var set = window.CardSets.get(setId); if (!set) return;
    var card = set.byId.get(cardId); if (!card) return;
    var st = ps(set), e = st.cards[cardId]; if (!e) return;
    await ensureVariants();
    var plainOn = (e.n - e.h) - ((e.v || 0) - (e.vh || 0));
    var willHolo = plainOn < 1;
    var ok = await confirmDialog('Turn in ' + card.name + '?',
      '<p>Turning in destroys one copy of this card' + (willHolo ? ' — your <b>holo</b> copy, since no plain copy is on hand' : '') + ' and marks it <b>permanently collected</b>.</p>' +
      '<p class="muted">It counts toward your completion forever, even if you never own it again. The copy itself is gone. <b>There is no undo.</b></p>',
      'Turn it in');
    if (!ok) return;
    try {
      var tr = await CPS.cloud.call('turn_in', { p_set: setId, p_card: cardId });
      await refreshCloud();
      toast('✓ ' + card.name + ' turned in — permanently collected!', 'good');
      openCardModal(setId, cardId, forceHolo, variant);
      if (CPS.turninRewards) CPS.turninRewards.announce(setId, tr && tr.turnin_rewards);
    } catch (e2) { cloudError(e2); }
  }

  function openCardModal(setId, cardId, forceHolo, variant) {
    var set = window.CardSets.get(setId); if (!set) return;
    if (set.stub) { window.CardSets.load(setId).then(function (s2) { if (s2) openCardModal(setId, cardId, forceHolo, variant); }); return; }
    var card = set.byId.get(cardId); if (!card) return;
    var st = ps(set), e = st.cards[card.id], owned = e && e.n > 0, r = rarityOf(card.rarity);
    var row = window.CardSets.oddsTable(set).filter(function (x) { return x.rarity.key === card.rarity; })[0];
    var holo = forceHolo != null ? forceHolo : !!(e && e.h);
    var html = (galleryReturnKind ? '<button class="btn small gallery-back" data-gallery-back>← Back to list</button>' : CPS.cardBack ? '<button class="btn small gallery-back" data-card-back>' + esc(CPS.cardBack.text) + '</button>' : '') +
      '<button class="modal-x" data-close aria-label="Close">×</button><div class="zoom">' +
      '<div class="zoom-card">'+(owned?CPS.cards.render(set,card,variant?{variant:variant}:{holo:holo}):CPS.cards.render(set,card,{cls:'unowned'}))+'</div>' +
      '<div class="zoom-info"><div class="pill r-' + card.rarity + '">' + r.label + '</div>' +
      '<h3>' + esc(card.name) + '</h3>' +
      (!owned && !isTurned(set.id, card.id) ? '<div class="muted">Not collected yet \u2014 pull it from a pack!</div>' : '') +
      (card.subtitle ? '<div class="muted">' + esc(card.subtitle) + '</div>' : '') +
      '<dl>' +
      '<dt>Set</dt><dd>' + esc(set.name) + '</dd>' +
      '<dt>You own</dt><dd>' + (owned ? e.n + ' total · ' + onHand(e) + ' on hand' + (e.h ? ' · ' + e.h + ' holo' : '') + ((e.v || 0) ? ' · ' + e.v + ' in Vault' : '') : '0') + '</dd>' +
      (variant ? '<dt>Variant</dt><dd>'+esc(CPS.cards.VARIANTS[variant.tier].name)+' #'+variant.serial+'/'+CPS.cards.VARIANTS[variant.tier].run+'</dd>' : '') +
      (isTurned(set.id, card.id) ? '<dt>Turned in</dt><dd class="turned-note">✓ Permanently collected</dd>' : '') +
      '<dt>Odds</dt><dd>' + (row ? U.oneIn(row.perCard) + ' packs' : '—') + '</dd>' +
      '<dt>Times pulled</dt><dd id="cardPulled">…</dd>' +
      '<dt>Currently existing</dt><dd id="cardPop">…</dd></dl>' +
      '<div class="variant-census" id="vcensus" style="display:none"></div>' +
      (card.details ? '<div class="zoom-details">' + esc(card.details) + '</div>' : '') +
      (owned && e.h && e.n > e.h ? '<button class="btn small" data-toggle-holo="' + (holo ? 0 : 1) + '">Show ' + (holo ? 'regular' : 'holo') + ' version</button>' : '') +
      (owned && isCloud() ? '<button class="btn small" data-gift>🎁 Gift</button>' : '') +
      vaultButtonsHtml(set, card, e, variant) +
      '</div></div>';
    openModal(html, function (box) {
      var bk = box.querySelector('[data-gallery-back]');
      if (bk) bk.addEventListener('click', function () { showStatGallery(galleryReturnKind, true); });
      var cb=box.querySelector('[data-card-back]');if(cb)cb.addEventListener('click',function(){if(CPS.cardBack)CPS.cardBack.go();});
      var t = box.querySelector('[data-toggle-holo]');
      if (t) t.addEventListener('click', function () { openCardModal(setId, cardId, t.dataset.toggleHolo === '1'); });
      var g = box.querySelector('[data-gift]');
      if (g) g.addEventListener('click', function () { if (CPS.gift) CPS.gift.open(setId, cardId); });
      box.querySelectorAll('[data-vault],[data-unvault]').forEach(function (b2) {
        b2.addEventListener('click', async function () {
          var on = b2.hasAttribute('data-vault');
          var holo2 = (on ? b2.dataset.vault : b2.dataset.unvault) === 'holo';
          b2.disabled = true;
          try {
            await CPS.cloud.call('vault_copy', { p_set: setId, p_card: cardId, p_holo: holo2, p_on: on });
            await refreshCloud();
            toast(on ? 'Copy vaulted 🔒' : 'Copy released from the Vault.', 'good');
            openCardModal(setId, cardId, forceHolo, variant);
          } catch (e) { cloudError(e); b2.disabled = false; }
        });
      });
      var vb = box.querySelector('[data-vault-variant]');
      if (vb) vb.addEventListener('click', async function () {
        vb.disabled = true;
        try {
          await CPS.cloud.call('vault_variant', { p_variant_id: vb.dataset.vaultVariant, p_on: vb.dataset.von === '1' });
          S.myVariants = null;
          await refreshCloud();
          toast(vb.dataset.von === '1' ? 'Numbered copy vaulted 🔒' : 'Numbered copy released.', 'good');
          openCardModal(setId, cardId, forceHolo, variant);
        } catch (e) { cloudError(e); vb.disabled = false; }
      });
      var ti = box.querySelector('[data-turnin]');
      if (ti) ti.addEventListener('click', function () { turnInFlow(setId, cardId, forceHolo, variant); });
      if (CPS.census) CPS.census.fill(box, set, card, variant);
      if (CPS.popfill) CPS.popfill(box, set, card);
    });
  }

  /* --- stats */
  var galleryReturnKind = null, galleryScrollTop = 0;
  function showStatGallery(kind, restoreScroll) {
    if (window.CardSets.load) {
      var needIds = kind === 'numbered'
        ? Array.from(new Set((S.myVariants || []).map(function (v) { return v.set_id; })))
        : null;
      var gateReady = needIds
        ? needIds.every(function (id) { var s = window.CardSets.get(id); return s && !s.stub; })
        : !(window.CardSets.pending && window.CardSets.pending());
      if (!gateReady) {
        (needIds ? window.CardSets.loadIds(needIds) : window.CardSets.loadAll())
          .then(function () { showStatGallery(kind, restoreScroll); });
        return;
      }
    }
    var title, items = [];
    var NT = ['rainbow', 'prism', 'obsidian', 'oneofone'];
    if (kind === 'numbered') {
      title = 'Your Numbered Cards';
      (S.myVariants || []).forEach(function (v) {
        var sd = window.CardSets.get(v.set_id), c = sd && sd.byId.get(v.card_id);
        if (!sd || !c) return;
        items.push({ sd: sd, c: c, html: CPS.cards.render(sd, c, { variant: { tier: v.tier, serial: v.serial } }),
                     variant: { tier: v.tier, serial: v.serial }, holo: false });
      });
      items.sort(function (a, b) { var ta = NT.indexOf(a.variant.tier), tb = NT.indexOf(b.variant.tier); if (ta < 0) ta = 99; if (tb < 0) tb = 99; return (ta - tb) || a.c.name.localeCompare(b.c.name) || (a.variant.serial - b.variant.serial) || a.sd.name.localeCompare(b.sd.name); });
    } else {
      title = 'Your ' + rarityOf(kind).label + ' Cards';
      window.CardSets.all().forEach(function (sd) {
        var pst = S.player.sets[sd.id]; if (!pst) return;
        sd.cards.forEach(function (c) {
          if (c.rarity !== kind) return;
          var e = pst.cards[c.id];
          if (!(e && e.n > 0) && !isTurned(sd.id, c.id)) return;
          var holo = !!(e && e.h > 0);
          items.push({ sd: sd, c: c, html: CPS.cards.render(sd, c, { holo: holo }), variant: null, holo: holo, turned: isTurned(sd.id, c.id) });
        });
      });
      items.sort(function (a, b) { return a.c.name.localeCompare(b.c.name) || a.sd.name.localeCompare(b.sd.name); });
    }
    // Render in chunks: a 100+ card gallery of full card renders at once can
    // kill a phone browser tab outright (Chrome's "Can't open this page").
    var PAGE = 60;
    function itemsHtml(list) {
      return list.map(function (x) {
        return '<div class="stat-gallery-item' + (x.turned ? ' turned' : '') + '" data-set="' + esc(x.sd.id) + '" data-card="' + esc(x.c.id) + '"' +
          (x.variant ? ' data-vtier="' + esc(x.variant.tier) + '" data-vserial="' + x.variant.serial + '"' : '') +
          ' data-holo="' + (x.holo ? '1' : '0') + '">' + x.html + (x.turned ? '<span class="badge-turned" title="Turned in — permanently collected">✓</span>' : '') + '</div>';
      }).join('');
    }
    function groupedHtml(list) { return NT.map(function (tier) { var ti = list.filter(function (x) { return x.variant.tier === tier; }); if (!ti.length) return ''; var tv = CPS.cards.VARIANTS[tier]; return '<h3 class="st-head vt-' + esc(tier) + '">' + tv.emoji + ' ' + esc(tv.name) + ' <span class="muted small">(' + ti.length + ')</span></h3><div class="stat-gallery sg-sec">' + itemsHtml(ti) + '</div>'; }).join(''); }
    var paged = !restoreScroll && items.length > PAGE, shown = paged ? items.slice(0, PAGE) : items, moreBtn = paged ? '<button type="button" class="btn small" data-gallery-more>Show all ' + items.length + ' cards</button>' : '', body = !items.length ? '<div class="empty">None yet \u2014 keep ripping packs!</div>' : kind === 'numbered' ? '<div class="sg-wrap">' + groupedHtml(shown) + '</div>' + moreBtn : '<div class="stat-gallery">' + itemsHtml(shown) + '</div>' + moreBtn;
    openModal('<button class="modal-x" data-close aria-label="Close">×</button>' +
      '<h2>' + esc(title) + ' <span class="muted small">(' + items.length + ')</span></h2>' + body,
      function (box) {
        if (restoreScroll) {
          var g0 = box.querySelector('.sg-wrap') || box.querySelector('.stat-gallery');
          if (g0) g0.scrollTop = galleryScrollTop;
        }
        var more = box.querySelector('[data-gallery-more]');
        if (more) more.addEventListener('click', function () {
          if (kind === 'numbered') { var w = box.querySelector('.sg-wrap'); if (w) { w.innerHTML = groupedHtml(items); bindItems(w); } }
          else { var g = box.querySelector('.stat-gallery'); if (g) { g.innerHTML = itemsHtml(items); bindItems(g); } }
          more.remove();
        });
        bindItems(box);
      });
    function bindItems(box) {
        box.querySelectorAll('.stat-gallery-item').forEach(function (el) {
          el.addEventListener('click', function () {
            var g = el.closest('.sg-wrap') || el.closest('.stat-gallery');
            galleryScrollTop = g ? g.scrollTop : 0;
            galleryReturnKind = kind;
            var vt = el.getAttribute('data-vtier');
            var variant = vt ? { tier: vt, serial: parseInt(el.getAttribute('data-vserial'), 10) } : null;
            openCardModal(el.getAttribute('data-set'), el.getAttribute('data-card'),
              el.getAttribute('data-holo') === '1', variant);
          });
        });
    }
  }
  function renderStatsLazy() {
    if (window.CardSets.pending && window.CardSets.pending()) {
      $('#statTiles').innerHTML = '<div class="muted">Loading set data…</div>';
      window.CardSets.loadAll().then(function () { if (S.view === 'stats') renderStats(); });
      return;
    }
    renderStats();
  }
  function renderStats() {
    var set = S.set, st = ps();
    var agg = { opened: 0, pulled: 0, holos: 0, byRarity: {}, unique: 0, total: 0, packs: 0, ownedByRarity: {} };
    window.CardSets.all().forEach(function (sd) {
      var pst = S.player.sets[sd.id], psd = pst ? pst.stats : null;
      agg.opened += psd ? psd.opened || 0 : 0;
      agg.pulled += psd ? psd.pulled || 0 : 0;
      agg.holos += psd ? psd.holos || 0 : 0;
      agg.unique += pst ? sd.cards.filter(function (c) { return (pst.cards[c.id] && pst.cards[c.id].n > 0) || isTurned(sd.id, c.id); }).length : 0;
      agg.total += sd.cards.length; agg.packs += pst ? pst.packs || 0 : 0;
      R.RARITIES.forEach(function (r) { agg.byRarity[r.key] = (agg.byRarity[r.key] || 0) + (psd && psd.byRarity[r.key] || 0); });
      if (pst) sd.cards.forEach(function (c) {
        var e = pst.cards[c.id];
        if ((e && e.n > 0) || isTurned(sd.id, c.id)) agg.ownedByRarity[c.rarity] = (agg.ownedByRarity[c.rarity] || 0) + 1;
      });
    });
    var numberedEarly = (S.myVariants || []).length;
    var tiles=[['Packs opened',agg.opened],['Cards pulled',agg.pulled],['Unique cards',U.fmt(agg.unique)+' / '+U.fmt(agg.total)],['Completion',U.pct(agg.total?agg.unique/agg.total:0)],
      ['Epic Cards',agg.ownedByRarity.epic||0,'epic'],['Legendary Cards',agg.ownedByRarity.legendary||0,'legendary'],
      ['Chase Cards',agg.ownedByRarity.chase||0,'chase'],['Numbered Cards',numberedEarly,'numbered']];
    $('#statTiles').innerHTML=tiles.map(function(t){
      return '<div class="tile' + (t[2] ? ' clickable' : '') + '"' + (t[2] ? ' data-stat-gallery="' + t[2] + '" title="Click to see your ' + t[0].toLowerCase() + '"' : '') + '><span>'+t[0]+'</span><b>'+(typeof t[1]==='number'?U.fmt(t[1]):t[1])+'</b>' + (t[2] ? '<span class="tile-hint">Click to view ›</span>' : '') + '</div>';
    }).join('');
    $$('#statTiles [data-stat-gallery]').forEach(function (el) {
      el.addEventListener('click', function () { showStatGallery(el.getAttribute('data-stat-gallery')); });
    });
    var numbered = (S.myVariants || []).length;
    var max = Math.max.apply(null, R.RARITIES.map(function (r) { return agg.byRarity[r.key] || 0; }).concat([numbered, 1]));
    $('#rarityBars').innerHTML = R.RARITIES.map(function (r) {
      var n = agg.byRarity[r.key] || 0;
      return '<div class="barrow r-' + r.key + '"><span class="bl">' + r.label + '</span><span class="bar"><i style="width:' + (n / max * 100).toFixed(1) + '%"></i></span><span class="bn">' + U.fmt(n) + (agg.pulled ? ' <em>' + U.pct(n / agg.pulled) + '</em>' : '') + '</span></div>';
    }).join('') + '<div class="barrow r-numbered"><span class="bl">Numbered</span><span class="bar"><i style="width:' + (numbered / max * 100).toFixed(1) + '%"></i></span><span class="bn">' + U.fmt(numbered) + '</span></div>';
    if (isCloud() && !S.myVariants) ensureVariants().then(function () { if (S.view === 'stats') renderStats(); });

    var bestO = null, bestSd = null, bestSc = -1;
    window.CardSets.all().forEach(function (sd) {
      var pst = S.player.sets[sd.id], bb = pst && pst.stats && pst.stats.best, cc = bb && sd.byId.get(bb.id);
      if (!cc) return;
      var sc = CPS.packs.score(cc, bb.holo);
      if (sc > bestSc) { bestSc = sc; bestO = bb; bestSd = sd; }
    });
    var best = bestO && bestSd.byId.get(bestO.id);
    $('#bestPull').innerHTML = best
      ? CPS.cards.render(bestSd, best, { holo: bestO.holo }) + '<div class="best-cap"><b class="rt-' + best.rarity + '">' + esc(best.name) + (bestO.holo ? ' (holo)' : '') + '</b><span>' + rarityOf(best.rarity).label + ' · ' + esc(bestSd.name) + ' · ' + new Date(bestO.at).toLocaleDateString() + '</span></div>'
      : '<div class="empty">Open a pack to get started.</div>';
    var allRec = [];
    window.CardSets.all().forEach(function (sd) {
      var pst = S.player.sets[sd.id];
      (pst && pst.recent || []).forEach(function (x) { allRec.push({ sd: sd, id: x.id, holo: x.holo, at: x.at || 0 }); });
    });
    allRec.sort(function (a, b) { return b.at - a.at; });
    allRec = allRec.slice(0, CONFIG.recentMax);
    $('#recentPulls').innerHTML = allRec.length ? allRec.map(function (x) {
      var c = x.sd.byId.get(x.id); return c ? CPS.cards.render(x.sd, c, { holo: x.holo }) : '';
    }).join('') : '<div class="empty">Nothing yet.</div>';
    if (CPS.globalStats && (!isCloud() || S.myVariants)) CPS.globalStats.render();
  }

  /* --- odds */
  function renderOdds() {
    var set = S.set;
    if (set.id === 'jumbled') {
      $('#oddsSetName').textContent = '\u00b7 Jumbled Mess';
      $('#oddsIntro').textContent = '5 cards, each from a random set. First four: Uncommon 62% \u00b7 Rare 26% \u00b7 Epic 10% \u00b7 Legendary 2%. Fifth: Rare 80% \u00b7 Epic 14% \u00b7 Legendary 5% \u00b7 Chase 1% \u2014 and 1 in 10 of those Chases is the Jumbled Mess Chase, found nowhere else. A few cards live only in these packs: see the Jumbled Mess collection.';
      $('#oddsTable').innerHTML = ''; $('#slotList').innerHTML = '';
      return;
    }
    var rows = window.CardSets.oddsTable(set);
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

  /* --- sets & settings */
  function renderSets() {
    $('#setList').innerHTML = window.CardSets.all().map(function (s) {
      var st = S.player.sets[s.id], owned = st ? (s.stub ? Object.keys(st.cards).length : ownedCount(s, st)) : 0;
      return '<div class="set-item' + (s.id === S.set.id ? ' current' : '') + '">' +
        CPS.cards.swatch(s) +
        '<div class="set-meta"><b>' + esc(s.name) + '</b><span>' + (s.total || s.cards.length) + ' cards · ' + (S.onlineSets.indexOf(s.id) >= 0 ? 'on the server' : 'not on server') +
        ' · you have ' + owned + '</span></div>' +
        '<div class="set-actions">' + (s.id === S.set.id ? '<span class="pill">Selected</span>' : '<button class="btn small" data-use="' + esc(s.id) + '">Use</button>') +
        (function(){ var on = S.onlineSets.indexOf(s.id) >= 0; return '<button class="btn small' + (on ? ' ghost' : ' primary') + '" data-sync="' + esc(s.id) + '">' + (on ? 'Re-sync' : 'Upload') + '</button>'; })() +
        (s.source === 'imported' ? '<button class="btn small ghost" data-remove="' + esc(s.id) + '">Remove</button>' : '') + '</div></div>';
    }).join('') + (window.CardSets.errors.length || S.loadWarnings.length
      ? '<div class="warn-box">' + S.loadWarnings.concat(window.CardSets.errors).map(esc).join('<br>') + '</div>' : '');
  }

  function openPlayerModal() {
    if (isCloud()) return toggleAccountMenu();
    return showGate({});
  }

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
        try { enterCloud(await CPS.cloud.call('get_state')); if (setsReadyP) await setsReadyP; closeModal(true); afterEnter(); toast('Welcome back, ' + S.account.display_name + '!', 'good'); }
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

  function closeAccountMenu() {
    var m = $('#acctMenu'); if (m) m.classList.add('hidden');
  }
  function toggleAccountMenu() {
    var m = $('#acctMenu'), btn = $('#playerBtn');
    if (!m || !btn) return;
    if (!m.classList.contains('hidden')) { closeAccountMenu(); return; }
    var r = btn.getBoundingClientRect();
    m.style.top = (r.bottom + 6) + 'px';
    m.style.right = Math.max(8, window.innerWidth - r.right) + 'px';
    m.classList.remove('hidden');
    if (CPS.friends) CPS.friends.renderMenu();
  }

  /* --- admin (online) */

  
  function suggestUsername(name) {
    return String(name || '').replace(/[^A-Za-z0-9_.-]+/g, '').slice(0, 32) || 'Player' + (1 + Math.floor(Math.random() * 99));
  }
  function randomPin() {
    var b = new Uint32Array(1); crypto.getRandomValues(b);
    return String(b[0] % 10000).padStart(4, '0');
  }
  function validPin(p) { return /^[0-9]{4}$/.test(p); }

  function renderAdminArea() {
    var unlocked = isAdmin() && !!S.dev;
    $('#adminGate').classList.toggle('hidden', unlocked || !isAdmin());
    $('#adminBody').classList.toggle('hidden', !unlocked);
    $('#setsArea').classList.toggle('hidden', !unlocked);
    if (unlocked) renderAdmin();
    if (unlocked && CPS.online) CPS.online.adminTick();
    if (unlocked && CPS.maintenance) CPS.maintenance.adminTick();
    if (unlocked) renderSets();
  }

  async function renderAdmin() {
    if (!isAdmin() || !S.dev) return;
    var grantSets = window.CardSets.all().filter(function (x) { return S.onlineSets.indexOf(x.id) >= 0; })
      .sort(function (a, b) { return a.name.localeCompare(b.name); });
    if (typeof CPS !== 'undefined' && CPS.jumbled && !grantSets.some(function (x) { return x.id === 'jumbled'; })) grantSets.push(CPS.jumbled.pseudoSet());
    var setOpts = grantSets
      .map(function (x) { return '<option value="' + esc(x.id) + '"' + (x.id === S.set.id ? ' selected' : '') + '>' + esc(x.name) + '</option>'; }).join('') +
      '<option value="__random">Random Packs</option>';


    $('#gaAllSet').innerHTML = setOpts || '<option value="">(upload a set first)</option>';
    $('#acctList').innerHTML = '<div class="muted small">Loading…</div>';
    try {
      var accts = await CPS.cloud.call('admin_list_accounts');
      $('#acctList').innerHTML = accts.map(function (x) {
        var packs = Object.keys(x.packs || {}).map(function (k) { var st = window.CardSets.get(k); return (st ? st.code : k) + ' ' + x.packs[k]; }).join(', ') || '0';
        return '<div class="acct-row' + (x.disabled ? ' disabled' : '') + '" data-acct="' + esc(x.id) + '" data-name="' + esc(x.display_name) + '">' +
          '<div class="acct-main"><span class="avatar">' + esc((x.display_name[0] || 'P').toUpperCase()) + '</span><div><b>' + esc(x.display_name) + '</b>' +
          (x.is_admin ? ' <span class="pill r-legendary">Admin</span>' : '') + (x.disabled ? ' <span class="pill r-chase">Disabled</span>' : '') +
          (x.locked ? ' <span class="pill r-epic" title="Too many wrong PINs. Reset the PIN to unlock now.">Locked</span>' : '') +
          (x.has_pin === false ? ' <span class="pill r-chase">No PIN</span>' : '') + (x.is_me ? ' <span class="pill">You</span>' : '') +
          '<div class="muted small">username <b class="acct-user">' + esc(x.username || x.hint) + '</b> · packs ' + esc(packs) + ' · ' + (x.spins || 0) + ' spins (' + (x.spins_done || 0) + ' used) · ' + (x.tokens || 0) + ' tokens · ' + x.opened + ' opened · ' + x.unique_cards + ' unique · last login ' +
          (x.last_login_at ? new Date(x.last_login_at).toLocaleDateString() : 'never') + '</div></div></div>' +

          '<button class="btn small ghost" data-act="rename">Rename</button>' +
          '<button class="btn small ghost" data-act="reuser">Change username</button>' +
          '<button class="btn small ghost" data-act="pin">Reset PIN</button>' +
          (x.is_me ? '' : '<button class="btn small ghost" data-act="' + (x.disabled ? 'enable' : 'disable') + '">' + (x.disabled ? 'Enable' : 'Disable') + '</button>' +
            '<button class="btn small ghost danger-text" data-act="delete">Delete</button>') + '</div></div>';
      }).join('') || '<div class="empty">No accounts yet.</div>';
      // Populate grant recipient dropdowns (admins included; pick kept across re-renders)
      var grantOpts = '<option value="everyone">Everyone (non-admin)</option>' +
        accts.map(function(x) { return '<option value="' + esc(x.id) + '">' + esc(x.display_name) + (x.is_admin ? ' (Admin)' : '') + (x.is_me ? ' (You)' : '') + '</option>'; }).join('');
      ['grantPacksWho', 'grantSpinsWho', 'grantTokensWho', 'grantCreditWho', 'notifyWho'].forEach(function(id) {
        var sel = document.getElementById(id);
        if (sel) { var p = sel.value; sel.innerHTML = grantOpts; if (p && grantOpts.indexOf('value="' + p + '"') > -1) sel.value = p; }
      });
    } catch (e) { cloudError(e); }
  }

  async function adminAction(e) {
    var b = e.target.closest('[data-act]'); if (!b) return;
    var row = b.closest('[data-acct]'), id = row.dataset.acct, name = row.dataset.name, act = b.dataset.act, r;
    try {
      if (act === 'rename') {
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
        if (act === 'disable' && !(await confirmDialog('Disable account', '<p>Disable ' + esc(name) + '? They will be logged out and can\'t log in until you enable them.</p>', 'Disable'))) return;
        await CPS.cloud.call('admin_update_account', { p_account: id, p_disabled: act === 'disable' });
      } else if (act === 'delete') {
        if (!(await confirmDialog('Delete account', '<p>Delete ' + esc(name) + ' and ALL their cards, packs and stats? This cannot be undone.</p>', 'Delete'))) return;
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
      var setIds = window.CardSets.all().filter(function (x) { return x.id !== 'jumbled' && S.onlineSets.indexOf(x.id) >= 0; }).map(function (x) { return x.id; });
      var r = await CPS.cloud.call('admin_create_account', { p_username: user, p_display_name: display, p_pin: pin,
        p_start_packs: Math.max(0, parseInt($('#naPacks').value, 10) || 0), p_sets: setIds, p_is_admin: $('#naAdmin').checked });
      showCreated(r.display_name, r.username || user, pin);
      toast('Created ' + r.display_name + ' with ' + r.packs + ' pack' + (r.packs === 1 ? '' : 's') +
        ' of ' + (r.set_ids || []).length + ' set' + ((r.set_ids || []).length === 1 ? '' : 's') + '.', 'good');
      $('#naName').value = ''; $('#naUser').value = ''; $('#naPin').value = ''; $('#naAdmin').checked = false;
      renderAdmin();
    } catch (err) { cloudError(err); }
    finally { btn.disabled = false; }
  }

  /* --- dev mode lock */
  function requestDevUnlock() {
    var html = '<button class="modal-x" data-close aria-label="Close">×</button><h2>🔒 Unlock dev mode</h2>' +
      '<p class="muted small">Dev mode adds free packs for testing. Enter the password to turn it on in this browser.</p>' +
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

  /* --- modal */
  function openModal(html, after) {
    S.gateOpen = false;
    var m = $('#modal'), box = $('#modalBox');
    var fresh = box.cloneNode(false); box.replaceWith(fresh); // drop old listeners
    fresh.innerHTML = html; m.classList.remove('hidden');
    if (after) after(fresh);
  }
  function closeModal(force) {
    galleryReturnKind = null; CPS.cardBack = null;
    if (S.gateOpen && !force) return; // the login screen stays until you log in
    if (confirmDismiss) confirmDismiss(); // a pending confirmDialog dismisses as abort, never hangs
    S.gateOpen = false;
    $('#modal').classList.add('hidden'); $('#modalBox').innerHTML = '';
  }

  /* --- tilt */
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


  /* --- prize wheel */
  function spinCount() {
    return isCloud() ? (S.spins || 0) : ((S.player && S.player.spins) || 0);
  }
  
  function updateWheelBadge() {
    var b = $('#wheelBadge');
    if (b) { var n = spinCount(); b.textContent = n; b.classList.toggle('hidden', !(n > 0)); }
  }
  /* Single-flight, same reasoning as refreshCloud: refreshQuests is
     called from 12 sites and bursts stacked identical list_quests
     fetches (the most-called content RPC). */
  var _questFlight = null, _questTrail = null;
  async function _refreshQuestsOnce() {
    if (!isCloud()) { S.quests = null; updateDailyBadge(); return; }
    try { S.quests = await CPS.cloud.call('list_quests', {}); }
    catch (e) { S.quests = []; }
    updateDailyBadge();
  }
  function refreshQuests() {
    if (_questFlight) {
      if (!_questTrail) {
        _questTrail = _questFlight.then(async function () {
          _questTrail = null; _questFlight = null;
          return refreshQuests();
        });
      }
      return _questTrail;
    }
    _questFlight = _refreshQuestsOnce();
    return _questFlight;
  }
  function updateDailyBadge() {
    var n = (S.quests || []).filter(function (q) { return q.done && !q.claimed; }).length;
    var b = $('#dailyBadge');
    if (b) { b.textContent = n; b.classList.toggle('hidden', !(n > 0)); }
  }
  function questHtml(q) {
    var pct = Math.min(100, Math.round(q.progress / q.target * 100));
    return '<div class="quest tier-' + q.tier + (q.done && !q.claimed ? ' claimable' : '') + '">' +
      '<div class="quest-top"><div><b>' + esc(q.title) + '</b>' +
      '<span class="quest-tier">' + q.tier + ' &middot; ' + (q.currency === 'token' ? '&#x1FA99; ' + q.amount + ' token' + (q.amount === 1 ? '' : 's') : '&#x1F39F;&#xFE0F; ' + (q.amount != null ? q.amount : q.tickets) + ' ticket' + ((q.amount != null ? q.amount : q.tickets) === 1 ? '' : 's')) + '</span></div>' +
      (q.claimed ? '<span class="quest-done">Claimed &#x2713;</span>' :
       q.done ? '<button class="btn small primary" data-claim="' + esc(q.key) + '">Claim</button>' :
       '<span class="quest-prog">' + Math.min(q.progress, q.target) + '/' + q.target + '</span>') +
      '</div><div class="bar quest-bar"><i style="width:' + pct + '%"></i></div></div>';
  }
  async function renderDaily() {
    var list = $('#questList');
    if (!list) return;
    if (!S.quests) list.innerHTML = '<div class="muted">Loading&hellip;</div>'; /* Loading flash only on first load, not after every claim */
    await refreshQuests();
    if (S.view !== 'daily') return;
    var all = S.quests || [];
    var qs = all.filter(function (q) { return !q.claimed; }).concat(all.filter(function (q) { return q.claimed; })); /* claimed stay visible at the bottom */
    list.innerHTML = qs.length ? qs.map(questHtml).join('') :
      '<div class="empty">No quests today &mdash; check back tomorrow.</div>';
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
      updateWheelBadge();
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
    var abtn = $('#autoSpinBtn');
    if (abtn) {
      abtn.style.display = (!isLocked() && n > 1 && cfg && cfg.wheels.length) ? '' : 'none';
      abtn.disabled = S.spinning && !S.autospin;
      abtn.textContent = S.autospin ? 'STOP' : 'AUTOSPIN';
    }
    var mbtn = $('#multiSpinBtn');
    if (mbtn) {
      mbtn.style.display = (!isLocked() && n >= 10 && cfg && cfg.wheels.length) ? '' : 'none';
      mbtn.disabled = S.spinning || S.autospin;
    }
    var m5btn = $('#multiSpin5Btn');
    if (m5btn) {
      m5btn.style.display = (!isLocked() && n >= 5 && cfg && cfg.wheels.length) ? '' : 'none';
      m5btn.disabled = S.spinning || S.autospin;
    }
    var allbtn = $('#multiSpinAllBtn');
    if (allbtn) {
      allbtn.style.display = (!isLocked() && n >= 2 && cfg && cfg.wheels.length) ? '' : 'none';
      allbtn.disabled = S.spinning || S.autospin;
      allbtn.textContent = 'SPIN ALL ×' + n;
    }
    updateWheelBadge();
  }
  async function startWheelSpin() {
    if (S.spinning || isLocked()) return;
    if (spinCount() < 1) { toast('No spin tickets left. Come back tomorrow for your daily spin!', 'warn'); audio.error(); return; }
    doOneSpin(1);
  }
  async function startAutospin() {
    if (S.autospin || S.spinning || isLocked()) return;
    if (spinCount() < 2) { toast('Autospin needs at least 2 spin tickets.', 'warn'); return; }
    S.autospin = true;
    S._autoAgg = { n: 0, bySet: {}, tokens: 0, credit: 0 };
    renderWheel();
    while (S.autospin && S.view === 'wheel' && spinCount() > 0) {
      var ok = await doOneSpin(2);
      if (!ok) break;
    }
    S.autospin = false;
    S.spinning = false;
    renderWheel();
    if (S._autoAgg && S._autoAgg.n > 1 && CPS.wheelMulti && CPS.wheelMulti.showSummary) CPS.wheelMulti.showSummary(S._autoAgg);
    S._autoAgg = null;
  }
  async function doOneSpin(speed) {
    speed = speed || 1;
    var cfg = S._wheelCfg || wheelConfig();
    if (!cfg || !cfg.wheels.length) { toast('The wheel isn\'t ready yet.', 'warn'); return false; }
    S.spinning = true;
    S._wheelEnd = null;
    CPS.wheel.draw($('#wheelCanvas'), cfg.wheels[0], 0);
    $('#wheelName').textContent = cfg.wheels[0].name;
    renderWheel();
    if (CPS.wheel.startIdle) CPS.wheel.startIdle($('#wheelCanvas'), cfg.wheels[0]);
    var canvas = $('#wheelCanvas'), out = null;
    try {
      out = await CPS.cloud.call('spin_wheel', {});
      S.spins = out.spins_left;
      refreshQuests();
    } catch (e) {
      if (CPS.wheel.stopIdle) CPS.wheel.stopIdle(canvas);
      S.spinning = false;
      renderWheel();
      cloudError(e);
      return false;
    }
    renderWheel(); // show the consumed ticket now, not after the animation
    
    var endState = await CPS.wheel.playHops(canvas, cfg, out.hops || [], speed);
    var prize = out.prize || {}, isTok = prize.kind === 'tokens', isCred = prize.kind === 'credit';
    var pset = !isTok && !isCred && prize.set_id ? window.CardSets.get(prize.set_id) : null;
    if (isCloud() && pset) ps(pset).packs = out.packs_now;
    if (isCloud() && isTok && CPS.games) CPS.games.setTokens(out.tokens_now);
    if (!isCloud()) renderPacksSide();
    if (endState) {
      S._wheelEnd = {
        wheelId: endState.wheelId, key: endState.key, rot: endState.rotation,
        resultHtml: CPS.wheel.prizeHtml(prize, pset && pset.name)
      };
    }
    if (S.autospin && S._autoAgg && CPS.wheelMulti) CPS.wheelMulti.addPrize(S._autoAgg, prize);
    audio.coin();
    S.spinning = false;
    renderWheel();
    renderPacksSide();
    return true;
  }

  /* --- events */
  function bind() {
    $$('.tab').forEach(function (t) { t.addEventListener('click', function () { showView(t.dataset.view); }); });
    if (CPS.market) CPS.market.init();
    $('#brandHome').addEventListener('click', function (e) { e.preventDefault(); if (!isLocked()) showView('packs'); });
    window.addEventListener('hashchange', function () { var v = location.hash.slice(1); if (v && v !== S.view && $('#view-' + v)) showView(v); });
    var _ddBtn = $('#setDDBtn'); if (_ddBtn) _ddBtn.addEventListener('click', function (e) { e.stopPropagation(); toggleSetDD(); });
    window.addEventListener('resize', function () { closeSetDD(); });
    document.addEventListener('scroll', function (e) { var l = $('#setDDList'); if (l && !l.classList.contains('hidden') && e.target !== l) closeSetDD(); }, true);
    var _ddList = $('#setDDList'); if (_ddList) _ddList.addEventListener('click', function (e) {
      var b = e.target.closest('[data-set-id]'); if (!b) return;
      selectSet(b.getAttribute('data-set-id'));
    });
    document.addEventListener('click', function (e) { if (!e.target.closest('#setDD') && !e.target.closest('#setDDList')) closeSetDD(); });
    document.addEventListener('keydown', function (e) { if (e.key === 'Escape') closeSetDD(); });
    $('#openBtn').addEventListener('click', startOpen);
    var _qb = $('#quickOpenBtn'); if (_qb) _qb.addEventListener('click', startQuickOpen);
    $('#spinBtn').addEventListener('click', startWheelSpin);
    $('#autoSpinBtn').addEventListener('click', function () {
      if (S.autospin) { S.autospin = false; var ab = $('#autoSpinBtn'); if (ab) { ab.textContent = 'Stopping...'; ab.disabled = true; } }
      else startAutospin();
    });
    var _msb = $('#multiSpinBtn'); if (_msb) _msb.addEventListener('click', function () { if (CPS.wheelMulti) CPS.wheelMulti.start(); });
    var _m5b = $('#multiSpin5Btn'); if (_m5b) _m5b.addEventListener('click', function () { if (CPS.wheelMulti) CPS.wheelMulti.start(5); });
    var _mab = $('#multiSpinAllBtn'); if (_mab) _mab.addEventListener('click', function () { if (CPS.wheelMulti && CPS.wheelMulti.startAll) CPS.wheelMulti.startAll(); });
    $('#revealAllBtn').addEventListener('click', revealAll);
    $('#stagePack').addEventListener('pointerdown', function (e) { if (e.button == null || e.button === 0) tear(); });
    $('#stageIdle').addEventListener('click', function (e) { if (e.target.closest('.idle-pack')) openFromPack(); });
    $('#stageIdle').addEventListener('keydown', function (e) {
      if ((e.key === 'Enter' || e.key === ' ') && e.target.closest('.idle-pack')) { e.preventDefault(); e.stopPropagation(); openFromPack(); }
    });
    $('#revealGrid').addEventListener('click', function (e) {
      var c = e.target.closest('.card'); if (!c) return;
      if (!c.classList.contains('flipped')) reveal(+c.dataset.i);
      else if (!c.dataset.ticket && !c.dataset.tokens && !c.dataset.credit) openCardModal(c.dataset.set, c.dataset.card, c.classList.contains('holo'));
    });
    $('#freePackBtn').addEventListener('click', function () { addFree(1); });
    $('#adminUnlockBtn').addEventListener('click', requestDevUnlock);
    $('#free10Btn').addEventListener('click', function () { addFree(10); });

    // collection
    var collSearchTimer = null;
    $('#collSearch').addEventListener('input', function (e) {
      S.coll.q = e.target.value;
      if (collSearchTimer) clearTimeout(collSearchTimer);
      collSearchTimer = setTimeout(renderCollection, 150);
    });
    $('#collRarity').addEventListener('change', function (e) { S.coll.rarity = e.target.value; renderCollection(); });
    $('#collSort').addEventListener('change', function (e) { S.coll.sort = e.target.value; renderCollection(); });
    $('#playerList').addEventListener('click', function (e) {
      var b = e.target.closest('[data-player]');
      if (b) CPS.profile.openProfile(b.dataset.player);
    });
    $('#newTradeBtn').addEventListener('click', function () { openTradeBuilder(null); });
    $('#tradeBackBtn').addEventListener('click', function () { showView('players'); });
    $('#tradeHistBtn').addEventListener('click', function () { showView('trade-history'); });
    $('#tradeHistBackBtn').addEventListener('click', function () { showView('players'); });
    $('#tradeWithSel').addEventListener('change', async function () {
      if (!TB) return;
      var sel = this, v = sel.value;
      var hasWork = TB.offer.length || TB.want.length || TB.picks.length || TB.offerPack || TB.wantPack || TB.offerMoney || TB.wantMoney || TB.tokens > 0 || TB.tickets > 0;
      if (v !== TB.to && hasWork) {
        var ok = await confirmDialog('Switch trading partner?',
          'Your picks for ' + esc(TB.toName || 'this partner') + ' will be cleared.', 'Switch partner', 'Keep building');
        if (!ok) { sel.value = TB.to; return; }
      }
      TB.to = v; tbLoadTheir();
    });
    $('#tradePackSet').addEventListener('change', function () {
      if (!TB) return;
      TB.packSet = this.value;
      TB.packs = TB.packSet ? Math.max(1, Math.min(TB.packs || 1, tbPackAvail(TB.packSet))) : 0;
      tbSyncPackScratch(); tbRenderPackBar(); tbRenderDock();
    });
    $('#tradePackQty').addEventListener('input', function () {
      if (!TB) return;
      TB.packs = Math.max(0, parseInt(this.value, 10) || 0);
      tbSyncPackScratch(); tbRenderDock();
    });
    $('#tradePackQty').addEventListener('change', function () {
      if (!TB) return;
      var m = tbPackAvail(TB.packSet);
      if (TB.packs > m) TB.packs = m;
      tbSyncPackScratch(); tbRenderPackBar(); tbRenderDock();
    });
    $('#tradeTokens').addEventListener('input', function () {
      if (!TB) return;
      TB.tokens = Math.max(0, parseInt(this.value, 10) || 0);
      tbSyncMoneyScratch(); tbRenderDock();
    });
    $('#tradeTokens').addEventListener('change', function () {
      if (!TB) return;
      if (TB.step === 1 && TB.tokens > (S.gameTokens || 0)) TB.tokens = S.gameTokens || 0;
      tbSyncMoneyScratch(); tbRenderMoneyBar(); tbRenderDock();
    });
    $('#tradeTickets').addEventListener('input', function () {
      if (!TB) return;
      TB.tickets = Math.max(0, parseInt(this.value, 10) || 0);
      tbSyncMoneyScratch(); tbRenderDock();
    });
    $('#tradeTickets').addEventListener('change', function () {
      if (!TB) return;
      if (TB.step === 1 && TB.tickets > (S.spins || 0)) TB.tickets = S.spins || 0;
      tbSyncMoneyScratch(); tbRenderMoneyBar(); tbRenderDock();
    });
    $('#tradeSearch').addEventListener('input', function () { if (TB) { TB.q = this.value; tbRenderGrid(); } });
    $('#tradeSetSel').addEventListener('change', function () { if (TB) { TB.setId = this.value; tbRenderGrid(); } });
    $('#tradeRarity').addEventListener('change', function () { if (TB) { TB.rarity = this.value; tbRenderGrid(); } });
    $('#tradeContinueBtn').addEventListener('click', tbContinue);
    $('#tradeGrid').addEventListener('click', function (e) {
      if (!TB || TB.step === 3) return;
      var b = e.target.closest('.trade-pick');
      if (!b) return;
      var setId = b.dataset.set, cardId = b.dataset.card;
      var idx = TB.picks.findIndex(function (p) { return p.setId === setId && p.cardId === cardId && !p.tier; });
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
      if (e.target.closest('[data-money-x]')) {
        TB.tokens = 0; TB.tickets = 0; tbSyncMoneyScratch(); tbRenderMoneyBar(); tbRenderDock();
        return;
      }
      if (e.target.closest('[data-pack-x]')) {
        TB.packSet = ''; TB.packs = 0; tbSyncPackScratch(); tbRenderPackBar(); tbRenderDock();
        return;
      }
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
      if (a) { a.disabled = true; respondTrade(a.dataset.tradeAccept, true); return; }
      var d = e.target.closest('[data-trade-decline]');
      if (d) { d.disabled = true; respondTrade(d.dataset.tradeDecline, false); return; }
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
    var tib = $('#turnInAllBtn');
    if (tib) tib.addEventListener('click', function () { turnInAllFlow(); });
    $('#questList').addEventListener('click', function (e) {
      var b = e.target.closest('[data-claim]'); if (!b || b.disabled) return;
      b.disabled = true;
      (async function () {
        try {
          var r = await CPS.cloud.call('claim_quest', { p_key: b.dataset.claim });
          if (r.spins_now != null) { S.spins = r.spins_now; updateWheelBadge(); }
          fx.confetti(120);
          toast(r.currency === 'token'
            ? '+' + r.amount + ' arcade token' + (r.amount === 1 ? '' : 's') + '!'
            : '+' + r.tickets + ' spin ticket' + (r.tickets === 1 ? '' : 's') + '!', 'good');
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
    var setSearch = $('#setSearch');
    if (setSearch) setSearch.addEventListener('input', function () {
      var q = setSearch.value.toLowerCase();
      var items = document.querySelectorAll('#setList .set-item');
      for (var i = 0; i < items.length; i++) {
        var txt = items[i].textContent.toLowerCase();
        items[i].style.display = (!q || txt.indexOf(q) >= 0) ? '' : 'none';
      }
    });
    $('#setList').addEventListener('click', async function (e) {
      var u = e.target.closest('[data-use]'), rm = e.target.closest('[data-remove]'), sy = e.target.closest('[data-sync]');
      if (u) { selectSet(u.dataset.use); renderSets(); }
      if (rm && confirm('Remove this imported set from this browser? (Your pulled cards stay saved.)')) {
        await Store.deleteCustomSet(rm.dataset.remove); window.CardSets.unregister(rm.dataset.remove);
        if (S.set.id === rm.dataset.remove) S.set = window.CardSets.all()[0];
        fillSetSelect(); selectSet(S.set.id); renderSets();
      }
      if (sy) {
        var set = window.CardSets.get(sy.dataset.sync); if (!set) return;
        sy.disabled = true; sy.textContent = 'Uploading…';
        try {
          var r = await CPS.cloud.call('admin_upsert_set', { p_set: setPayload(set) });
          if (S.onlineSets.indexOf(set.id) < 0) S.onlineSets.push(set.id);
          toast('"' + set.name + '" is on the server (' + r.cards + ' cards).', 'good');
          renderSets();
        } catch (err) { cloudError(err); sy.disabled = false; sy.textContent = 'Retry'; }
      }
    });
    var _soundToggle = $('#soundToggle'); if (_soundToggle) _soundToggle.addEventListener('change', function (e) { audio.enabled = e.target.checked; Store.setPref('sound', audio.enabled); applyPrefsUI(); });
    $('#soundBtn').addEventListener('click', function () { audio.enabled = !audio.enabled; Store.setPref('sound', audio.enabled); applyPrefsUI(); if (audio.enabled) audio.click(); });
    $('#notifBtn').addEventListener('click', function () { if (CPS.notifPanel) CPS.notifPanel.open(); });
    refreshNotifBadge();
    setInterval(function () { if (!document.hidden) refreshNotifBadge(); }, 60000);
    document.addEventListener('visibilitychange', function () { if (!document.hidden) refreshNotifBadge(); });
    var _devToggle = $('#devToggle'); if (_devToggle) _devToggle.addEventListener('change', function (e) {
      if (e.target.checked) { e.target.checked = S.dev; if (!S.dev) requestDevUnlock(); return; }
      S.dev = false; Store.setPref('dev', false); applyPrefsUI(); if (S.view === 'admin') renderView(); toast('Dev mode off. The password is needed to turn it back on.', '', 2500);
    });
    var _resetSetBtn = $('#resetSetBtn'); if (_resetSetBtn) _resetSetBtn.addEventListener('click', function () {
      if (isCloud()) { toast('Online progress can\'t be reset from here.', 'warn'); return; }
      if (!confirm('Reset all your packs, cards and stats in "' + S.set.name + '"?')) return;
      delete S.player.sets[S.set.id]; save(); resetStage(); renderView(); toast('Progress reset.', 'warn');
    });
    $('#playerBtn').addEventListener('click', openPlayerModal);
    var _acctProfile = $('#acctProfileBtn');
    if (_acctProfile) _acctProfile.addEventListener('click', function () {
      closeAccountMenu();
      if (S.account && CPS.profile) CPS.profile.openProfile(S.account.id);
    });
    var _acctFaq = $('#acctFaqBtn');
    if (_acctFaq) _acctFaq.addEventListener('click', function () {
      closeAccountMenu();
      showView('faq');
    });
    var _acctLogout = $('#acctLogoutBtn');
    if (_acctLogout) _acctLogout.addEventListener('click', async function () {
      closeAccountMenu();
      await CPS.cloud.logout(); lockOut('You are logged out.');
    });
    document.addEventListener('pointerdown', function (e) {
      var m = $('#acctMenu');
      if (!m || m.classList.contains('hidden')) return;
      if (e.target.closest('#acctMenu') || e.target.closest('#playerBtn')) return;
      closeAccountMenu();
    });
    document.addEventListener('keydown', function (e) { if (e.key === 'Escape') closeAccountMenu(); });
    $('#newAcctForm').addEventListener('submit', createAccount);
    $('#naSuggest').addEventListener('click', function () { $('#naUser').value = suggestUsername($('#naName').value); });
    $('#naPinRandom').addEventListener('click', function () { $('#naPin').value = randomPin(); });
    $('#acctList').addEventListener('click', adminAction);
    $('#adminRefresh').addEventListener('click', function () { refreshCloud(); });
    $('#gaSpinAllBtn').addEventListener('click', async function () {
      var n = parseInt($('#gaSpinAllN').value, 10);
      var who = $('#grantSpinsWho').value;
      if (!(n >= 1)) { toast('Pick a number of spin tickets.', 'warn'); return; }
      var whoName = who === 'everyone' ? 'every non-admin player' : ($('#grantSpinsWho').selectedOptions[0].textContent || 'player');
      if (!(await confirmDialog('Grant spin tickets', '<p>Give ' + n + ' spin ticket' + (n === 1 ? '' : 's') + ' to ' + esc(whoName) + '?</p>', 'Grant'))) return;
      var btn = this; btn.disabled = true;
      try {
        var r;
        if (who === 'everyone') {
          r = await CPS.cloud.call('admin_grant_spins_all', { p_spins: n });
          toast('Gave ' + n + ' spin ticket' + (n === 1 ? '' : 's') + ' to ' + r.players + ' player' + (r.players === 1 ? '' : 's') + '.', 'good');
        } else {
          r = await CPS.cloud.call('admin_grant_spins', { p_account: who, p_spins: n });
          toast('Gave ' + n + ' spin ticket' + (n === 1 ? '' : 's') + ' to ' + whoName + '.', 'good');
        }
        renderAdmin();
      } catch (e) { cloudError(e); }
      btn.disabled = false;
    });
    CPS.admintokens.bindAll();
    CPS.admintokens.bindCreditAll();
    CPS.admintokens.bindNotify();
    $('#gaAllBtn').addEventListener('click', async function () {
      var sid = $('#gaAllSet').value, n = parseInt($('#gaAllN').value, 10);
      var who = $('#grantPacksWho').value;
      if (!sid || !(n >= 1)) { toast('Pick a set and a number of packs.', 'warn'); return; }
      var setName = sid === '__random' ? 'Random' : ((window.CardSets.get(sid) || {}).name || sid);
      var whoName = who === 'everyone' ? 'every non-admin player' : ($('#grantPacksWho').selectedOptions[0].textContent || 'player');
      if (!(await confirmDialog('Grant packs', '<p>Give ' + n + ' ' + esc(setName) + ' pack' + (n === 1 ? '' : 's') + ' to ' + esc(whoName) + '?</p>', 'Grant'))) return;
      var btn = this; btn.disabled = true;
      try {
        var r;
        if (who === 'everyone') {
          r = await CPS.cloud.call(sid === '__random' ? 'admin_grant_random_packs_all' : 'admin_grant_packs_all', sid === '__random' ? { p_packs: n } : { p_set: sid, p_packs: n });
          toast('Gave ' + n + ' pack' + (n === 1 ? '' : 's') + ' to ' + r.players + ' player' + (r.players === 1 ? '' : 's') + '.', 'good');
        } else {
          r = await CPS.cloud.call(sid === '__random' ? 'admin_grant_random_packs' : 'admin_grant_packs', sid === '__random' ? { p_packs: n, p_account: who } : { p_set: sid, p_packs: n, p_account: who });
          toast('Gave ' + n + ' ' + setName + ' pack' + (n === 1 ? '' : 's') + ' to ' + whoName + '.', 'good');
        }
        renderAdmin();
      } catch (e) { cloudError(e); }
      btn.disabled = false;
    });
    initCollapsible();
    document.addEventListener('click', function (e) {
      var b = e.target.closest('.collapse-btn'); if (!b) return;
      var p = b.closest('.panel'); if (!p || !p.id) return;
      p.classList.toggle('collapsed');
      var s = collapsedPanels(); s[p.id] = p.classList.contains('collapsed'); saveCollapsed(s);
      e.stopPropagation();
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
      if (img.dataset && img.dataset.o) return; /* grid thumb failed: the img's own onerror swaps in the full art — don't stomp it with placeholder art */
      var el = img.closest('.card'), set = window.CardSets.get(el.dataset.set), c = set && set.byId.get(el.dataset.card);
      if (c) img.outerHTML = CPS.cards.art(set, c);
    }, true);
  }

  CPS.app = { state: S, config: CONFIG, openPack: startOpen, tear: tear, revealAll: revealAll, showView: showView, selectSet: selectSet, goBack: goBack };
  /* Shared context for split-out modules (js/tickets.js). */
  CPS.appCtx = { S: S, U: U, R: R, audio: audio, fx: fx,
    $: $, $$: $$, esc: esc, save: save, isCloud: isCloud, isLocked: isLocked, isAdmin: isAdmin,
    toast: toast, cloudError: cloudError, refreshCloud: refreshCloud, renderView: renderView,
    renderCollection: renderCollection, renderPacksSide: renderPacksSide,
    updateWheelBadge: updateWheelBadge, spinCount: spinCount, refreshQuests: refreshQuests, renderWheel: renderWheel, wheelConfig: wheelConfig,
    renderAdmin: renderAdmin,
    dupeCounts: dupeCounts, DUPE_RARS: DUPE_RARS, variantCountMap: variantCountMap, isTurned: isTurned,
    ensureVariants: ensureVariants, rarityOf: rarityOf, ps: ps,
    openModal: openModal, closeModal: closeModal, openCardModal: openCardModal, openTradeBuilder: openTradeBuilder, confirmDialog: confirmDialog, quickFinish: quickFinish,
    showView: showView, refreshNotifBadge: refreshNotifBadge, ensureOwnedSets: ensureOwnedSets,
    fetchNotifications: fetchNotifications, goBack: goBack };
  boot().catch(function (e) { console.error(e); toast('Something went wrong starting the app: ' + e.message, 'error', 10000); });
})(window.CPS);

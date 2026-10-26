/* js/profile.js — player profile + other-players collection viewing.
   Consumes CPS.appCtx; registers CPS.profile. Split out of app.js. */
(function (CPS) {
  'use strict';
  var ctx = CPS.appCtx;
  var setSort = 'pct'; // 'pct' = by completion, 'name' = A-Z; persists across opens

/* Best pull = highest rarity owned; numbered variants then holos break ties. */
function bestPull(collection) {
  var R = ctx.R, best = null, bs = -1;
  var vrank = { rainbow: 1, prism: 2, obsidian: 3, oneofone: 4 };
  (collection || []).forEach(function (e) {
    var set = window.CardSets.get(e.set_id), card = set && set.byId.get(e.card_id);
    if (!set || !card) return;
    var vr = 0;
    (e.variants || []).forEach(function (v) { vr = Math.max(vr, vrank[v.tier] || 0); });
    var score = (R.INDEX[card.rarity] || 0) * 10 + vr + (e.h > 0 ? 0.5 : 0);
    if (score > bs) { bs = score; best = { set: set, card: card }; }
  });
  return best;
}

var XHIST_ICONS = { trade: '🔁', gift: '🎁', bounty: '🎯', market: '🏪' };
async function openExchangeHistory(accountId, name) {
  ctx.openModal('<button class="modal-x" data-close aria-label="Close">×</button>' +
    '<h3>📜 Exchanges with ' + ctx.esc(name) + '</h3><div class="muted" style="padding:16px">Loading…</div>');
  try {
    var rows = await CPS.cloud.call('exchange_history', { p_other: accountId });
    var html = '<button class="modal-x" data-close aria-label="Close">×</button>' +
      '<h3>📜 Exchanges with ' + ctx.esc(name) + '</h3>';
    if (!rows || !rows.length) {
      html += '<div class="empty" style="padding:16px">No exchanges with ' + ctx.esc(name) + ' yet — trades, gifts, bounties and Trading Post deals between you will show up here.</div>';
    } else {
      html += rows.map(function (e) {
        var when = '';
        try { when = new Date(e.at).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' }); } catch (err) {}
        return '<div class="xhist-row" style="padding:8px 0;border-bottom:1px solid rgba(127,127,127,.18)">' +
          '<div>' + (XHIST_ICONS[e.kind] || '•') + ' <b>' + ctx.esc(e.title) + '</b>' +
          (e.status ? ' <span class="pill st-' + ctx.esc(e.status) + '">' + ctx.esc(e.status) + '</span>' : '') +
          (e.thanked ? ' <span class="muted small">🙏 thanked</span>' : '') +
          '<span class="muted small" style="float:right">' + when + '</span></div>' +
          '<div class="muted small">' + ctx.esc(e.detail) + '</div></div>';
      }).join('');
    }
    ctx.openModal(html);
  } catch (e) { ctx.closeModal(true); ctx.cloudError(e); }
}

async function openProfile(accountId) {
  ctx.openModal('<div class="muted" style="padding:24px">Loading…</div>');
  try {
    var p = await CPS.cloud.call('get_profile', { p_account: accountId });
    var friended = false;
    if (!p.is_me && CPS.friends) { try { friended = await CPS.friends.isFriendAsync(accountId); } catch (e) {} }
    var sets = p.sets || [], collection = p.collection || [];
    var totU = 0, totT = 0, totTi = 0, holos = 0;
    sets.forEach(function (s) { totU += s.unique || 0; totT += s.total || 0; totTi += s.turned || 0; });
    collection.forEach(function (c) { holos += c.h || 0; });
    var pct = totT ? (totU / totT * 100) : 0;
    var best = bestPull(collection);
    var statsHtml =
      '<div class="prof-stats">' +
      '<div class="prof-stat"><b>' + ctx.U.fmt(totU) + '</b><span>cards</span></div>' +
      '<div class="prof-stat"><b>' + pct.toFixed(1) + '%</b><span>complete</span></div>' +
      '<div class="prof-stat"><b>' + ctx.U.fmt(holos) + '</b><span>holos</span></div>' +
      '<div class="prof-stat"><b>' + ctx.U.fmt(totTi) + '</b><span>turned in</span></div>' +
      '</div>' +
      (best ? '<div class="prof-best"><span class="pb-top">★ Best pull</span>' +
        '<b class="rt-' + best.card.rarity + '">' + ctx.esc(best.card.name) + '</b>' +
        '<span class="pb-sub">' + ctx.esc(best.set.name) + ' · ' + ctx.rarityOf(best.card.rarity).label + '</span></div>' : '');

    var poss = ctx.esc(p.display_name) + '’s';
    ctx.openModal('<button class="modal-x" data-close aria-label="Close">×</button><div class="profile">' +
      '<div class="prof-head"><span class="avatar big">' + ctx.esc((p.display_name[0] || 'P').toUpperCase()) + '</span>' +
      '<div><h2>' + ctx.esc(p.display_name) + '</h2>' + (p.is_me ? '<span class="pill pill-you">You</span>' : '<button class="btn small" id="profTradeBtn">Propose trade</button> <button class="btn small" id="profGiftBtn">🎁 Gift</button> <button class="btn small" id="profHistBtn">📜 History</button> <button class="btn small' + (friended ? ' friended' : '') + '" id="profFriendBtn">' + (friended ? '⭐ Friend' : '☆ Add friend') + '</button>') + '</div></div>' +
      statsHtml +
      '<div class="prof-nav">' +
      '<button class="btn prof-nav-btn" id="profVaultBtn">🔒 View ' + poss + ' Vault<span class="muted">' + (p.favorites || []).length + '</span></button>' +
      '<button class="btn prof-nav-btn" id="profCollBtn">🗂️ View ' + poss + ' Collection</button>' +
      '<button class="btn prof-nav-btn" id="profTrophyBtn">🏆 View ' + poss + ' Trophy Case</button>' +
      '</div>' +
      '</div>', function (box) {
      box.querySelector('#profVaultBtn').addEventListener('click', function () { openVaultScreen(accountId); });
      box.querySelector('#profCollBtn').addEventListener('click', function () { openCollectionScreen(accountId); });
      box.querySelector('#profTrophyBtn').addEventListener('click', function () { openTrophyScreen(accountId, p.display_name); });
      var ptb = box.querySelector('#profTradeBtn');
      if (ptb) ptb.addEventListener('click', function () { ctx.openTradeBuilder(accountId); });
      var pgb = box.querySelector('#profGiftBtn');
      if (pgb) pgb.addEventListener('click', function () { if (CPS.giftBundle) CPS.giftBundle.open(accountId, p.display_name); });
      var phb = box.querySelector('#profHistBtn');
      if (phb) phb.addEventListener('click', function () { openExchangeHistory(accountId, p.display_name); });
      var pfb = box.querySelector('#profFriendBtn');
      if (pfb) pfb.addEventListener('click', async function () {
        if (!CPS.friends) return;
        pfb.disabled = true;
        try {
          var now = await CPS.friends.toggle(accountId, p.display_name);
          pfb.textContent = now ? '⭐ Friend' : '☆ Add friend';
          pfb.classList.toggle('friended', now);
          ctx.toast(now ? 'Added ' + p.display_name + ' to your friends.' : 'Removed ' + p.display_name + ' from your friends.', '', 2200);
        } catch (e) { ctx.cloudError(e); }
        finally { pfb.disabled = false; }
      });
      var pb = box.querySelector('.prof-best');
      if (pb && best) { pb.style.cursor = 'pointer'; pb.addEventListener('click', function () { CPS.cardBack = { text: '← Back to ' + p.display_name + '’s profile', go: function () { openProfile(accountId); } }; ctx.openCardModal(best.set.id, best.card.id); }); }
    });
  } catch (e) { ctx.closeModal(true); ctx.cloudError(e); }
}

var VRANK = { oneofone: 0, obsidian: 1, prism: 2, rainbow: 3 };
function bestVaultedVariant(variants) {
  var vs = (variants || []).filter(function (v) { return v.vaulted; }).sort(function (x, y) {
    var rx = VRANK[x.tier] != null ? VRANK[x.tier] : 9, ry = VRANK[y.tier] != null ? VRANK[y.tier] : 9;
    return (rx - ry) || (x.serial - y.serial);
  });
  return vs.length ? vs[0] : null;
}

function favsHtml(p) {
  // A vaulted NUMBERED copy should show as numbered. The favorites
  // rows carry no tier/serial, but the same payload's collection
  // entries list every variant with its vaulted flag -- the tile
  // wears the best vaulted variant (tier rank, then lowest serial).
  var vaultedVariant = {};
  (p.collection || []).forEach(function (e) {
    var b = bestVaultedVariant(e.variants);
    if (b) vaultedVariant[e.set_id + ':' + e.card_id] = b;
  });
  return (p.favorites || []).map(function (f) {
    var set = window.CardSets.get(f.set_id), card = set && set.byId.get(f.card_id);
    if (!set || !card) return '';
    var v = vaultedVariant[f.set_id + ':' + f.card_id];
    return '<div class="prof-fav" data-fav-set="' + ctx.esc(f.set_id) + '" data-fav-card="' + ctx.esc(f.card_id) + '" data-fav-holo="' + (f.holo ? '1' : '0') + '">' + CPS.cards.render(set, card, { holo: !!f.holo, variant: v ? { tier: v.tier, serial: v.serial } : undefined }) + '</div>';
  }).join('');
}

function bindFavClicks(box, before) {
  box.querySelectorAll('.prof-fav').forEach(function (elm) {
    elm.style.cursor = 'pointer';
    elm.addEventListener('click', function () { if (before) before(); ctx.openCardModal(elm.dataset.favSet, elm.dataset.favCard, elm.dataset.favHolo === '1'); });
  });
}

async function openVaultScreen(accountId) {
  ctx.openModal('<div class="muted" style="padding:24px">Loading…</div>');
  try {
    var p = await CPS.cloud.call('get_profile', { p_account: accountId });
    var favs = favsHtml(p);
    ctx.openModal('<button class="modal-x" data-close aria-label="Close">×</button><div class="profile">' +
      '<button class="btn small prof-back" id="profBackBtn">← Back</button>' +
      '<h3 class="prof-coll-h"><span>🔒 ' + ctx.esc(p.display_name) + '’s Vault (' + (p.favorites || []).length + ')</span>' +
      (p.is_me ? '<button class="btn small" id="profFavEditBtn">Edit</button>' : '') + '</h3>' +
      (favs ? '<div class="prof-favs">' + favs + '</div>' : '<div class="empty">Nothing in the Vault yet.</div>') +
      '</div>', function (box) {
      box.querySelector('#profBackBtn').addEventListener('click', function () { openProfile(accountId); });
      var feb = box.querySelector('#profFavEditBtn');
      if (feb) feb.addEventListener('click', function () { openFavManager(accountId, p.favorites || []); });
      bindFavClicks(box, function () {
        CPS.cardBack = { text: '← Back to ' + p.display_name + '’s Vault', go: function () { openVaultScreen(accountId); } };
      });
    });
  } catch (e) { ctx.closeModal(true); ctx.cloudError(e); }
}

async function openCollectionScreen(accountId) {
  ctx.openModal('<div class="muted" style="padding:24px">Loading…</div>');
  try {
    var p = await CPS.cloud.call('get_profile', { p_account: accountId });
    var sets = p.sets || [], collection = p.collection || [];
    ctx.openModal('<button class="modal-x" data-close aria-label="Close">×</button><div class="profile">' +
      '<button class="btn small prof-back" id="profBackBtn">← Back</button>' +
      '<h3 class="prof-coll-h"><span>' + ctx.esc(p.display_name) + '’s Collection</span><button class="btn small" id="profSortBtn"></button></h3>' +
      '<div class="prof-sets cols2"></div>' +
      '</div>', function (box) {
      function renderSets() {
        var arr = sets.slice();
        arr.sort(function (a, b) {
          if (setSort === 'pct') {
            var pa = a.total ? a.unique / a.total : 0, pb = b.total ? b.unique / b.total : 0;
            if (pb !== pa) return pb - pa;
          }
          return a.set_name < b.set_name ? -1 : (a.set_name > b.set_name ? 1 : 0);
        });
        var el = box.querySelector('.prof-sets');
        el.innerHTML = arr.map(function (s) {
          var pc = s.total ? (s.unique / s.total * 100) : 0;
          var tp = s.total ? ((s.turned || 0) / s.total * 100) : 0;
          return '<div class="prof-set" data-pset="' + ctx.esc(s.set_id) + '">' +
            '<div class="prof-set-top"><span>' + ctx.esc(s.set_name) + '</span>' +
            '<span class="muted small">' + ctx.U.fmt(s.unique) + '/' + ctx.U.fmt(s.total) + ' · ' + pc.toFixed(1) + '% collected</span></div>' +
            '<span class="bar"><i style="width:' + pc.toFixed(1) + '%"></i></span>' +
            (s.turned ? '<div class="muted small turned-note">' + ctx.U.fmt(s.turned) + ' turned in · ' + tp.toFixed(1) + '%</div>' : '') + '</div>';
        }).join('') || '<div class="empty">—</div>';
        el.querySelectorAll('.prof-set').forEach(function (elm) {
          elm.addEventListener('click', function () {
            openPlayerSet(accountId, p.display_name, elm.dataset.pset, collection, 'collection');
          });
        });
      }
      renderSets();
      var sb = box.querySelector('#profSortBtn');
      var paintSort = function () { sb.textContent = setSort === 'pct' ? 'Sort: % ↓' : 'Sort: A–Z'; };
      paintSort();
      sb.addEventListener('click', function () {
        setSort = setSort === 'pct' ? 'name' : 'pct';
        paintSort(); renderSets();
      });
      box.querySelector('#profBackBtn').addEventListener('click', function () { openProfile(accountId); });
    });
  } catch (e) { ctx.closeModal(true); ctx.cloudError(e); }
}

var trophyStamp = 0;
async function openTrophyScreen(accountId, displayName) {
  var stamp = ++trophyStamp;
  ctx.openModal('<button class="modal-x" data-close aria-label="Close">×</button><div class="profile">' +
    '<button class="btn small prof-back" id="profBackBtn">← Back</button>' +
    '<h3 class="prof-coll-h"><span>🏆 ' + ctx.esc(displayName) + '’s Trophy Case</span></h3>' +
    '<div id="trophyBody"><div class="muted" style="padding:12px">Loading…</div></div>' +
    '</div>', function (box) {
    box.querySelector('#profBackBtn').addEventListener('click', function () { openProfile(accountId); });
  });
  try {
    var t = await CPS.cloud.call('get_trophies', { p_account: accountId });
    if (stamp !== trophyStamp) return;
    var body = document.getElementById('trophyBody');
    if (body) body.innerHTML = (CPS.trophies && CPS.trophies.render) ? CPS.trophies.render(t) : '<div class="empty">Trophies unavailable right now.</div>';
  } catch (e) {
    if (stamp !== trophyStamp) return;
    var b2 = document.getElementById('trophyBody');
    if (b2) b2.innerHTML = '<div class="empty">Trophies unavailable right now.</div>';
  }
}

/* ---------------- favorites manager ---------------- */

function ownedCards() {
  // every owned card across all sets (side-effect-free read, unlike ps())
  var out = [];
  var psets = (ctx.S.player && ctx.S.player.sets) || {};
  window.CardSets.all().forEach(function (s) {
    if (s.id === 'jumbled') return;
    var st = psets[s.id];
    if (!st || !st.cards) return;
    s.cards.forEach(function (c) {
      var e = st.cards[c.id];
      if (e && e.n - (e.v || 0) > 0) out.push({ set: s, card: c, n: e.n - (e.v || 0) });
    });
  });
  return out;
}

function openFavManager(accountId, seedFavs, _ready) {
  if (!_ready && ctx.ensureOwnedSets) {
    ctx.ensureOwnedSets().then(function () { openFavManager(accountId, seedFavs, true); });
    return;
  }
  var myFavs = (seedFavs || []).slice(); // [{set_id, card_id, holo}]
  var favKeys = {};
  myFavs.forEach(function (f) { favKeys[f.set_id + ':' + f.card_id] = true; });
  var all = ownedCards();

  function myVaultedVariant(setId, cardId) {
    return bestVaultedVariant((ctx.S.myVariants || []).filter(function (v) {
      return v.set_id === setId && v.card_id === cardId;
    }));
  }

  function renderFavs(box) {
    box.querySelector('.favmgr-grid').innerHTML = myFavs.map(function (f, i) {
      var set = window.CardSets.get(f.set_id), card = set && set.byId.get(f.card_id);
      if (!set || !card) return '';
      var v = myVaultedVariant(f.set_id, f.card_id);
      return '<div class="favmgr-item" data-k="' + ctx.esc(f.set_id + ':' + f.card_id) + '">' +
        CPS.cards.render(set, card, { holo: !!f.holo, variant: v ? { tier: v.tier, serial: v.serial } : undefined }) +
        '<button class="favmgr-x" aria-label="Release from Vault">×</button></div>';
    }).join('') || '<div class="empty">Your Vault is empty — search below to vault copies.</div>';
    box.querySelector('#favmgrCount').textContent = myFavs.length + (myFavs.length === 1 ? ' card' : ' cards');
    box.querySelectorAll('.favmgr-x').forEach(function (x) {
      x.addEventListener('click', function () {
        var k2 = x.parentNode.dataset.k.split(':');
        toggle(k2[0], k2[1], box);
      });
    });
    box.querySelectorAll('.favmgr-item').forEach(function (item) { bindDrag(item, box); });
  }

  async function saveOrder() {
    try {
      await CPS.cloud.call('reorder_favorites', { p_order: myFavs.map(function (f) {
        return { set_id: f.set_id, card_id: f.card_id };
      }) });
    } catch (e) { ctx.cloudError(e); }
  }

  // Drag to reorder (pointer events: mouse + touch). The dragged
  // tile live-shuffles among its siblings; on release, if the
  // order changed, it is saved once via reorder_favorites.
  function bindDrag(item, box) {
    item.addEventListener('dragstart', function (ev) { ev.preventDefault(); });
    item.addEventListener('pointerdown', function (ev) {
      if (ev.button != null && ev.button > 0) return;
      if (ev.target.closest && ev.target.closest('.favmgr-x')) return;
      var grid = item.parentNode;
      var startX = ev.clientX, startY = ev.clientY, dragging = false;
      function onMove(e2) {
        if (!dragging) {
          if (Math.abs(e2.clientX - startX) + Math.abs(e2.clientY - startY) < 7) return;
          dragging = true;
          item.classList.add('dragging');
          grid.classList.add('drag-active');
          item.style.pointerEvents = 'none';
          if (item.setPointerCapture && ev.pointerId != null) { try { item.setPointerCapture(ev.pointerId); } catch (err) {} }
        }
        var under = document.elementFromPoint(e2.clientX, e2.clientY);
        var over = under && under.closest ? under.closest('.favmgr-item') : null;
        if (!over || over === item || !grid.contains(over)) return;
        var r = over.getBoundingClientRect();
        var after = e2.clientY > r.bottom ? true : e2.clientY < r.top ? false : e2.clientX > r.left + r.width / 2;
        if (after) { if (over.nextSibling !== item) grid.insertBefore(item, over.nextSibling); }
        else if (over !== item.nextSibling) grid.insertBefore(item, over);
      }
      function onUp() {
        item.removeEventListener('pointermove', onMove);
        item.removeEventListener('pointerup', onUp);
        item.removeEventListener('pointercancel', onUp);
        if (!dragging) return;
        item.classList.remove('dragging');
        grid.classList.remove('drag-active');
        item.style.pointerEvents = '';
        var order = [];
        grid.querySelectorAll('.favmgr-item').forEach(function (el) { order.push(el.dataset.k); });
        var changed = order.some(function (k, i2) { return !myFavs[i2] || myFavs[i2].set_id + ':' + myFavs[i2].card_id !== k; });
        if (!changed) return;
        var byKey = {};
        myFavs.forEach(function (f) { byKey[f.set_id + ':' + f.card_id] = f; });
        myFavs = order.map(function (k) { return byKey[k]; }).filter(Boolean);
        saveOrder();
        renderFavs(box);
      }
      item.addEventListener('pointermove', onMove);
      item.addEventListener('pointerup', onUp);
      item.addEventListener('pointercancel', onUp);
    });
  }

  function renderResults(box, q) {
    var el = box.querySelector('.favmgr-results');
    q = (q || '').trim().toLowerCase();
    if (!q) { el.innerHTML = '<div class="empty muted small">Type to search your collection.</div>'; return; }
    var hits = all.filter(function (o) {
      return !favKeys[o.set.id + ':' + o.card.id] && o.card.name.toLowerCase().indexOf(q) >= 0;
    }).slice(0, 24);
    el.innerHTML = hits.length ? hits.map(function (o) {
      return '<div class="favmgr-row" data-k="' + ctx.esc(o.set.id + ':' + o.card.id) + '">' +
        '<div class="favmgr-row-t"><b class="rt-' + o.card.rarity + '">' + ctx.esc(o.card.name) + '</b>' +
        '<div class="muted small">' + ctx.esc(o.set.name) + ' · ' + ctx.rarityOf(o.card.rarity).label + ' · ×' + o.n + '</div></div>' +
        '<button class="btn small">+ Add</button></div>';
    }).join('') : '<div class="empty">No matches in your collection.</div>';
    el.querySelectorAll('.favmgr-row').forEach(function (row) {
      row.querySelector('button').addEventListener('click', function () {
        var k3 = row.dataset.k.split(':');
        toggle(k3[0], k3[1], box);
      });
    });
  }

  async function toggle(setId, cardId, box) {
    var k = setId + ':' + cardId;
    try {
      var r = await CPS.cloud.call('toggle_favorite', { p_set: setId, p_card: cardId });
      if (r.favorited) {
        var st = ((ctx.S.player || {}).sets || {})[setId], e = st && st.cards[cardId];
        if (!favKeys[k]) myFavs.push({ set_id: setId, card_id: cardId, holo: !!(e && e.h > 0) });
        favKeys[k] = true;
        ctx.toast('Vaulted a copy — it is protected now. 🔒', 'good');
      } else {
        myFavs = myFavs.filter(function (f) { return f.set_id + ':' + f.card_id !== k; });
        delete favKeys[k];
        ctx.toast('Released a copy from your Vault — it is back in your inventory.', 'good');
      }
      await ctx.refreshCloud();
      all = ownedCards();
      renderFavs(box);
      renderResults(box, box.querySelector('.favmgr-search input').value);
    } catch (e2) { ctx.cloudError(e2); }
  }

  ctx.openModal('<button class="modal-x" data-close aria-label="Close">×</button><div class="profile">' +
    '<h2>Manage your Vault <span class="muted small" id="favmgrCount"></span></h2>' +
    '<div class="muted small">Drag a card to reorder your Vault. × releases a copy.</div>' +
    '<div class="favmgr-grid"></div>' +
    '<h3>Vault a copy</h3>' +
    '<div class="favmgr-search"><input type="search" placeholder="Search your cards…" aria-label="Search your cards"></div>' +
    '<div class="favmgr-results"></div>' +
    '<div class="row" style="margin-top:12px"><button class="btn primary" id="favmgrDone">Done</button></div>' +
    '</div>', function (box) {
    renderFavs(box);
    renderResults(box, '');
    if (ctx.isCloud && ctx.isCloud() && !ctx.S.myVariants) {
      ctx.ensureVariants().then(function () { if (box.isConnected) renderFavs(box); });
    }
    var inp = box.querySelector('.favmgr-search input');
    inp.addEventListener('input', function () { renderResults(box, inp.value); });
    box.querySelector('#favmgrDone').addEventListener('click', function () { openVaultScreen(accountId); });
  });
}

function openPlayerSet(accountId, displayName, setId, collection, backTo) {
  var set = window.CardSets.get(setId);
  if (!set) return;
  var owned = {};
  (collection || []).forEach(function (c) { if (c.set_id === setId) owned[c.card_id] = c; });
  var cards = set.cards.filter(function (card) { return owned[card.id]; });
  ctx.openModal('<button class="modal-x" data-close aria-label="Close">\u00d7</button><div class="profile">' +
    '<button class="btn small" id="pcBackBtn">\u2190 Back</button>' +
    '<h2>' + ctx.esc(displayName) + '</h2>' +
    '<div class="muted">' + ctx.esc(set.name) + ' \u00b7 ' + cards.length + ' / ' + set.cards.length + ' unique</div>' +
    (cards.length ? '<div class="prof-favs">' + cards.map(function (card) {
      var e = owned[card.id];
      var v=(e.variants||[])[0];
      return '<div class="prof-fav" data-fav-set="' + ctx.esc(set.id) + '" data-fav-card="' + ctx.esc(card.id) + '" data-fav-holo="' + (e.h > 0 ? '1' : '0') + '">' + CPS.cards.render(set,card,{holo:e.h>0,variant:v&&{tier:v.tier,serial:v.serial}}) +
        '<div class="prof-fav-cap"><b>' + ctx.esc(card.name) + '</b>' +
        '<span class="muted small">#' + ctx.U.pad(card.num, set.numWidth) + ' \u00b7 ' + ctx.rarityOf(card.rarity).label +
        (e.h > 0 ? ' \u00b7 \u2726 holo' : '') + ' \u00b7 \u00d7' + e.n + '</span></div></div>';
    }).join('') + '</div>' : '<div class="empty">No cards in this set yet.</div>') +
    '</div>', function (box) {
      box.querySelector('#pcBackBtn').addEventListener('click', function () {
        if (backTo === 'collection') openCollectionScreen(accountId); else openProfile(accountId);
      });
      box.querySelectorAll('.prof-fav').forEach(function (elm) {
        elm.style.cursor = 'pointer';
        elm.addEventListener('click', function () {
          CPS.cardBack = { text: '← Back to ' + set.name, go: function () { openPlayerSet(accountId, displayName, setId, collection, backTo); } };
          ctx.openCardModal(elm.dataset.favSet, elm.dataset.favCard, elm.dataset.favHolo === '1');
        });
      });
    });
}

  CPS.profile = { openProfile: openProfile, openPlayerSet: openPlayerSet };
})(window.CPS = window.CPS || {});

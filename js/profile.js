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

async function openProfile(accountId) {
  ctx.openModal('<div class="muted" style="padding:24px">Loading…</div>');
  try {
    var p = await CPS.cloud.call('get_profile', { p_account: accountId });
    var sets = p.sets || [], collection = p.collection || [];
    var totU = 0, totT = 0, totTi = 0, holos = 0;
    sets.forEach(function (s) { totU += s.unique || 0; totT += s.total || 0; totTi += s.turned || 0; });
    collection.forEach(function (c) { holos += c.h || 0; });
    var pct = totT ? (totU / totT * 100) : 0;
    var best = bestPull(collection);
    var favs = (p.favorites || []).map(function (f) {
      var set = window.CardSets.get(f.set_id), card = set && set.byId.get(f.card_id);
      if (!set || !card) return '';
      return '<div class="prof-fav">' + CPS.cards.render(set, card, { holo: !!f.holo }) + '</div>';
    }).join('');
    var statsHtml =
      '<div class="prof-stats">' +
      '<div class="prof-stat"><b>' + totU.toLocaleString() + '</b><span>cards</span></div>' +
      '<div class="prof-stat"><b>' + pct.toFixed(1) + '%</b><span>complete</span></div>' +
      '<div class="prof-stat"><b>' + holos + '</b><span>holos</span></div>' +
      '<div class="prof-stat"><b>' + totTi.toLocaleString() + '</b><span>turned in</span></div>' +
      '</div>' +
      (best ? '<div class="prof-best"><span class="pb-top">★ Best pull</span>' +
        '<b class="rt-' + best.card.rarity + '">' + ctx.esc(best.card.name) + '</b>' +
        '<span class="pb-sub">' + ctx.esc(best.set.name) + ' · ' + ctx.rarityOf(best.card.rarity).label + '</span></div>' : '');

    function renderSets(box) {
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
          '<span class="muted small">' + s.unique + '/' + s.total + ' · ' + pc.toFixed(1) + '% collected</span></div>' +
          '<span class="bar"><i style="width:' + pc.toFixed(1) + '%"></i></span>' +
          (s.turned ? '<div class="muted small turned-note">' + s.turned + ' turned in · ' + tp.toFixed(1) + '%</div>' : '') + '</div>';
      }).join('') || '<div class="empty">—</div>';
      el.querySelectorAll('.prof-set').forEach(function (elm) {
        elm.addEventListener('click', function () {
          openPlayerSet(accountId, p.display_name, elm.dataset.pset, collection);
        });
      });
    }

    ctx.openModal('<button class="modal-x" data-close aria-label="Close">×</button><div class="profile">' +
      '<div class="prof-head"><span class="avatar big">' + ctx.esc((p.display_name[0] || 'P').toUpperCase()) + '</span>' +
      '<div><h2>' + ctx.esc(p.display_name) + '</h2>' + (p.is_me ? '<span class="pill pill-you">You</span>' : '<button class="btn small" id="profTradeBtn">Propose trade</button>') + '</div></div>' +
      statsHtml +
      '<h3 class="prof-coll-h"><span>🔒 The Vault (' + (p.favorites || []).length + ')</span>' +
      (p.is_me ? '<button class="btn small" id="profFavEditBtn">Edit</button>' : '') + '</h3>' +
      (favs ? '<div class="prof-favs">' + favs + '</div>' : '<div class="empty">Nothing in the Vault yet.</div>') +
      '<h3 class="prof-coll-h"><span>Collection</span><button class="btn small" id="profSortBtn"></button></h3>' +
      '<div class="prof-sets cols2"></div>' +
      '</div>', function (box) {
      renderSets(box);
      var sb = box.querySelector('#profSortBtn');
      var paintSort = function () { sb.textContent = setSort === 'pct' ? 'Sort: % ↓' : 'Sort: A–Z'; };
      paintSort();
      sb.addEventListener('click', function () {
        setSort = setSort === 'pct' ? 'name' : 'pct';
        paintSort(); renderSets(box);
      });
      var feb = box.querySelector('#profFavEditBtn');
      if (feb) feb.addEventListener('click', function () { openFavManager(accountId, p.favorites || []); });
      var ptb = box.querySelector('#profTradeBtn');
      if (ptb) ptb.addEventListener('click', function () { ctx.openTradeBuilder(accountId); });
    });
  } catch (e) { ctx.closeModal(true); ctx.cloudError(e); }
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

function openFavManager(accountId, seedFavs) {
  var myFavs = (seedFavs || []).slice(); // [{set_id, card_id, holo}]
  var favKeys = {};
  myFavs.forEach(function (f) { favKeys[f.set_id + ':' + f.card_id] = true; });
  var all = ownedCards();

  function renderFavs(box) {
    box.querySelector('.favmgr-grid').innerHTML = myFavs.map(function (f, i) {
      var set = window.CardSets.get(f.set_id), card = set && set.byId.get(f.card_id);
      if (!set || !card) return '';
      return '<div class="favmgr-item" data-k="' + ctx.esc(f.set_id + ':' + f.card_id) + '">' +
        CPS.cards.render(set, card, { holo: !!f.holo }) +
        '<button class="favmgr-x" aria-label="Release from Vault">×</button>' +
        '<div class="favmgr-mv">' +
          '<button data-mv="-1" aria-label="Move earlier"' + (i === 0 ? ' disabled' : '') + '>‹</button>' +
          '<button data-mv="1" aria-label="Move later"' + (i === myFavs.length - 1 ? ' disabled' : '') + '>›</button>' +
        '</div></div>';
    }).join('') || '<div class="empty">Your Vault is empty — search below to vault copies.</div>';
    box.querySelector('#favmgrCount').textContent = myFavs.length + (myFavs.length === 1 ? ' card' : ' cards');
    box.querySelectorAll('.favmgr-x').forEach(function (x) {
      x.addEventListener('click', function () {
        var k2 = x.parentNode.dataset.k.split(':');
        toggle(k2[0], k2[1], box);
      });
    });
    box.querySelectorAll('.favmgr-mv button').forEach(function (b) {
      b.addEventListener('click', function () { moveFav(b, box); });
    });
  }

  async function moveFav(btn, box) {
    var k = btn.closest('.favmgr-item').dataset.k;
    var i = -1;
    myFavs.forEach(function (f, j) { if (f.set_id + ':' + f.card_id === k) i = j; });
    if (i < 0) return;
    var j = i + parseInt(btn.dataset.mv, 10);
    if (j < 0 || j >= myFavs.length) return;
    var t = myFavs[i]; myFavs[i] = myFavs[j]; myFavs[j] = t;
    renderFavs(box);
    try {
      await CPS.cloud.call('reorder_favorites', { p_order: myFavs.map(function (f) {
        return { set_id: f.set_id, card_id: f.card_id };
      }) });
    } catch (e) { ctx.cloudError(e); }
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
    '<div class="favmgr-grid"></div>' +
    '<h3>Vault a copy</h3>' +
    '<div class="favmgr-search"><input type="search" placeholder="Search your cards…" aria-label="Search your cards"></div>' +
    '<div class="favmgr-results"></div>' +
    '<div class="row" style="margin-top:12px"><button class="btn primary" id="favmgrDone">Done</button></div>' +
    '</div>', function (box) {
    renderFavs(box);
    renderResults(box, '');
    var inp = box.querySelector('.favmgr-search input');
    inp.addEventListener('input', function () { renderResults(box, inp.value); });
    box.querySelector('#favmgrDone').addEventListener('click', function () { openProfile(accountId); });
  });
}

function openPlayerSet(accountId, displayName, setId, collection) {
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
      return '<div class="prof-fav">' + CPS.cards.render(set,card,{holo:e.h>0,variant:v&&{tier:v.tier,serial:v.serial}}) +
        '<div class="prof-fav-cap"><b>' + ctx.esc(card.name) + '</b>' +
        '<span class="muted small">#' + ctx.U.pad(card.num, set.numWidth) + ' \u00b7 ' + ctx.rarityOf(card.rarity).label +
        (e.h > 0 ? ' \u00b7 \u2726 holo' : '') + ' \u00b7 \u00d7' + e.n + '</span></div></div>';
    }).join('') + '</div>' : '<div class="empty">No cards in this set yet.</div>') +
    '</div>', function (box) {
      box.querySelector('#pcBackBtn').addEventListener('click', function () { openProfile(accountId); });
    });
}

  CPS.profile = { openProfile: openProfile, openPlayerSet: openPlayerSet };
})(window.CPS = window.CPS || {});

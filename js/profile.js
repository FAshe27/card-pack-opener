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
    var totU = 0, totT = 0, holos = 0;
    sets.forEach(function (s) { totU += s.unique || 0; totT += s.total || 0; });
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
        return '<div class="prof-set" data-pset="' + ctx.esc(s.set_id) + '">' +
          '<div class="prof-set-top"><span>' + ctx.esc(s.set_name) + '</span>' +
          '<span class="muted small">' + s.unique + '/' + s.total + ' · ' + pc.toFixed(0) + '%</span></div>' +
          '<span class="bar"><i style="width:' + pc.toFixed(1) + '%"></i></span></div>';
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
      '<h3>★ Favorites (' + (p.favorites || []).length + '/' + 20 + ')</h3>' +
      (favs ? '<div class="prof-favs">' + favs + '</div>' : '<div class="empty">No favorites yet.</div>') +
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
      var ptb = box.querySelector('#profTradeBtn');
      if (ptb) ptb.addEventListener('click', function () { ctx.openTradeBuilder(accountId); });
    });
  } catch (e) { ctx.closeModal(true); ctx.cloudError(e); }
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

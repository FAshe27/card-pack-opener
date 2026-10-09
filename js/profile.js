/* js/profile.js — player profile + other-players collection viewing.
   Consumes CPS.appCtx; registers CPS.profile. Split out of app.js. */
(function (CPS) {
  'use strict';
  var ctx = CPS.appCtx;

async function openProfile(accountId) {
  ctx.openModal('<div class="muted" style="padding:24px">Loading…</div>');
  try {
    var p = await CPS.cloud.call('get_profile', { p_account: accountId });
    var favs = (p.favorites || []).map(function (f) {
      var set = window.CardSets.get(f.set_id), card = set && set.byId.get(f.card_id);
      if (!set || !card) return '';
      return '<div class="prof-fav">' + CPS.cards.render(set, card, { holo: !!f.holo }) +
        '<div class="prof-fav-cap"><b>' + ctx.esc(card.name) + '</b>' +
        '<span class="muted small">' + ctx.esc(set.name) + ' · ' + ctx.rarityOf(card.rarity).label + '</span></div></div>';
    }).join('');
    var sets = (p.sets || []).map(function (s) {
      var pct = s.total ? (s.unique / s.total * 100) : 0;
      return '<div class="prof-set" data-pset="' + ctx.esc(s.set_id) + '"><div class="prof-set-top"><span>' + ctx.esc(s.set_name) + '</span>' +
        '<span class="muted small">' + s.unique + '/' + s.total + '</span></div>' +
        '<span class="bar"><i style="width:' + pct.toFixed(1) + '%"></i></span></div>';
    }).join('');
    ctx.openModal('<button class="modal-x" data-close aria-label="Close">×</button><div class="profile">' +
      '<div class="prof-head"><span class="avatar big">' + ctx.esc((p.display_name[0] || 'P').toUpperCase()) + '</span>' +
      '<div><h2>' + ctx.esc(p.display_name) + '</h2>' + (p.is_me ? '<span class="pill pill-you">You</span>' : '<button class="btn small" id="profTradeBtn">Propose trade</button>') + '</div></div>' +
      '<h3>★ Favorites (' + (p.favorites || []).length + '/' + 20 + ')</h3>' +
      (favs ? '<div class="prof-favs">' + favs + '</div>' : '<div class="empty">No favorites yet.</div>') +
      '<h3>Collection</h3><div class="prof-sets">' + (sets || '<div class="empty">—</div>') + '</div>' +
      '</div>', function (box) {
      box.querySelectorAll('.prof-set').forEach(function (el) {
        el.addEventListener('click', function () {
          openPlayerSet(accountId, p.display_name, el.dataset.pset, p.collection || []);
        });
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

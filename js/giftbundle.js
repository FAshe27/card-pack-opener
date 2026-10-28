/* Bundle gifting from a player's profile (migration 181).
   One send may mix: up to FIVE cards (same copy rules as
   js/gifting.js — regular / ✦ holo / specific numbered copies;
   Vaulted copies stay put; picks may span sets), one pack bundle
   (one set + quantity), arcade tokens, and spin tickets.
   Jumbled Mess stays out entirely: its packs can't be gifted and its
   cards never appear in the picker (the server rejects both too).
   The server moves everything in one transaction and the recipient
   gets one gift pop-up with a Say Thanks button.
   Registers as CPS.giftBundle; opened from the profile's Gift button. */
(function (CPS) {
  var C = CPS.appCtx;
  var S = C.S, $ = C.$, esc = C.esc, toast = C.toast, cloudError = C.cloudError;
  var openModal = C.openModal, closeModal = C.closeModal, ps = C.ps;
  var ensureVariants = C.ensureVariants, refreshQuests = C.refreshQuests, refreshCloud = C.refreshCloud;

  var PAGE = 60;
  var MAX_CARDS = 5;
  var G = null;
  var lastDraft = null, lastTo = null; // unsent picks survive a stray close, per recipient (nav audit)

  function onHand(e) { return e ? Math.max(0, e.n - (e.v || 0)) : 0; }
  function allSerialCount(setId, cardId) {
    /* ALL numbered copies, vaulted or not — a vaulted numbered copy
       still isn't a regular copy (cps_vault_variant never touches
       collection.vaulted_count). */
    return (S.myVariants || []).filter(function (v) { return v.set_id === setId && v.card_id === cardId; }).length;
  }
  function mySerials(setId, cardId) {
    return (S.myVariants || []).filter(function (v) { return v.set_id === setId && v.card_id === cardId && !v.vaulted; })
      .sort(function (a, b) { return a.serial - b.serial; });
  }
  function myCardSets() {
    return window.CardSets.all().filter(function (set) {
      if (set.id === 'jumbled') return false;
      var cards = ps(set).cards;
      return Object.keys(cards).some(function (id) { return onHand(cards[id]) > 0; });
    });
  }
  function gridList() {
    var set = window.CardSets.get(G.setId);
    if (!set || !set.cards) return [];
    var cards = ps(set).cards;
    return set.cards.filter(function (card) {
      var e = cards[card.id];
      if (!e || onHand(e) <= 0) return false;
      /* Nothing giftable when every copy is a vaulted numbered one. */
      if (onHand(e) - allSerialCount(set.id, card.id) <= 0 && mySerials(set.id, card.id).length === 0) return false;
      if (G.rarity && card.rarity !== G.rarity) return false;
      if (G.q) {
        var hay = ('#' + card.num + ' ' + card.num + ' ' + card.name + ' ' + (card.subtitle || '')).toLowerCase();
        if (hay.indexOf(G.q) < 0) return false;
      }
      return true;
    });
  }
  function packCount(set) { return ps(set).packs || 0; }
  function packSets() {
    return window.CardSets.all().filter(function (set) {
      return set.id !== 'jumbled' && packCount(set) > 0;
    });
  }
  /* Copy availability for one card, ignoring the pick at exceptIdx
     (the one being edited keeps claim on its own copy). */
  function copiesInfo(setId, cardId, exceptIdx) {
    var set = window.CardSets.get(setId);
    var e = set ? ps(set).cards[cardId] : null;
    var serialsAll = mySerials(setId, cardId);
    var claimedSerials = {}, claimedRegular = 0, claimedHolo = 0;
    G.picks.forEach(function (p, i) {
      if (i === exceptIdx || p.setId !== setId || p.cardId !== cardId) return;
      if (p.variantId) claimedSerials[p.variantId] = 1;
      else { claimedRegular++; if (p.holo) claimedHolo++; }
    });
    var hand = onHand(e);
    var serials = serialsAll.filter(function (v) { return !claimedSerials[v.id]; });
    var regulars = Math.max(0, hand - allSerialCount(setId, cardId) - claimedRegular);
    var holoRemain = Math.max(0, (e ? Math.max(0, e.h - (e.vh || 0)) : 0) - claimedHolo);
    var plainRemain = Math.max(0, (e ? Math.max(0, (e.n - e.h) - ((e.v || 0) - (e.vh || 0))) : 0) - (claimedRegular - claimedHolo));
    return { e: e, hand: hand, serials: serials, regulars: regulars, holoRemain: holoRemain, plainRemain: plainRemain };
  }
  function pickLabel(p) {
    var set = window.CardSets.get(p.setId);
    var card = set && set.byId.get(p.cardId);
    var label = card ? card.name : 'Card';
    if (p.variantId) {
      var vv = mySerials(p.setId, p.cardId).filter(function (v) { return v.id === p.variantId; })[0];
      if (vv) label += ' ' + CPS.cards.VARIANTS[vv.tier].name + ' #' + vv.serial + '/' + CPS.cards.VARIANTS[vv.tier].run;
    } else if (p.holo) label += ' ✦ holo';
    return label + (set ? ' (' + set.name + ')' : '');
  }
  function parts() {
    var out = [], seen = {};
    G.picks.forEach(function (p) {
      var label = pickLabel(p);
      if (seen[label]) { seen[label].n++; return; }
      seen[label] = { label: label, n: 1 };
      out.push(seen[label]);
    });
    var list = out.map(function (x) { return x.n > 1 ? x.label + ' ×' + x.n : x.label; });
    if (G.packs > 0 && G.packSet) {
      var pset = window.CardSets.get(G.packSet);
      list.push(G.packs + ' ' + (pset ? pset.name : G.packSet) + ' pack' + (G.packs === 1 ? '' : 's'));
    }
    if (G.tokens > 0) list.push('🪙 ' + G.tokens + ' token' + (G.tokens === 1 ? '' : 's'));
    if (G.tickets > 0) list.push('🎟️ ' + G.tickets + ' spin ticket' + (G.tickets === 1 ? '' : 's'));
    return list;
  }
  function hasGift() { return !!(G.picks.length || (G.packs > 0 && G.packSet) || G.tokens > 0 || G.tickets > 0); }

  function renderGrid() {
    var box = $('#gbGrid');
    if (!box) return;
    var list = gridList();
    var shown = list.slice(0, G.shown);
    box.innerHTML = shown.length
      ? '<div class="coll-grid gb-grid">' + shown.map(function (card) {
          var set = window.CardSets.get(G.setId);
          var e = ps(set).cards[card.id] || {};
          var n = G.picks.filter(function (p) { return p.setId === G.setId && p.cardId === card.id; }).length;
          return '<button type="button" class="trade-pick' + (n ? ' selected' : '') + '" data-gb-card="' + esc(card.id) + '">' +
            CPS.cards.collected(set, card, onHand(e), Math.max(0, (e.h || 0) - (e.vh || 0))) +
            (n ? '<span class="gb-n">' + n + ' in gift</span>' : '') + '</button>';
        }).join('') + '</div>' +
        (list.length > shown.length
          ? '<button type="button" class="btn small" id="gbMore">Show more cards (' + (list.length - shown.length) + ' more)</button>'
          : '')
      : '<div class="muted small">No cards match.</div>';
    box.querySelectorAll('[data-gb-card]').forEach(function (b) {
      b.addEventListener('click', function () { tileClick(b.getAttribute('data-gb-card')); });
    });
    var more = $('#gbMore');
    if (more) more.addEventListener('click', function () { G.shown += PAGE; renderGrid(); });
  }

  function tileClick(cardId) {
    var info = copiesInfo(G.setId, cardId, -1);
    var mine = [];
    G.picks.forEach(function (p, i) { if (p.setId === G.setId && p.cardId === cardId) mine.push(i); });
    if (!(info.regulars > 0 || info.serials.length)) {
      if (mine.length) { G.active = mine[0]; renderPicks(); renderCopy(); }
      else toast('No copies of that card on hand to gift.');
      return;
    }
    if (G.picks.length >= MAX_CARDS) { toast('Gifts hold up to ' + MAX_CARDS + ' cards — remove one first.'); return; }
    var pick = { setId: G.setId, cardId: cardId, variantId: null, holo: false };
    if (info.regulars <= 0 && info.serials.length) pick.variantId = info.serials[0].id;
    else if (info.holoRemain > 0 && info.plainRemain <= 0) pick.holo = true;
    G.picks.push(pick);
    G.active = G.picks.length - 1;
    renderGrid(); renderPicks(); renderCopy(); sync();
  }

  function renderPicks() {
    var box = $('#gbPicks');
    if (!box) return;
    if (!G.picks.length) { box.innerHTML = ''; return; }
    box.innerHTML = '<div class="gb-pickrows">' + G.picks.map(function (p, i) {
      return '<button type="button" class="gb-pickrow' + (i === G.active ? ' on' : '') + '" data-gb-pick="' + i + '">' +
        '<span>' + esc(pickLabel(p)) + '</span>' +
        '<span class="gb-x" data-gb-del="' + i + '" title="Remove">✕</span></button>';
    }).join('') + '</div>';
    box.querySelectorAll('[data-gb-pick]').forEach(function (b) {
      b.addEventListener('click', function () { G.active = parseInt(b.getAttribute('data-gb-pick'), 10); renderPicks(); renderCopy(); });
    });
    box.querySelectorAll('[data-gb-del]').forEach(function (b) {
      b.addEventListener('click', function (ev) {
        ev.stopPropagation();
        var i = parseInt(b.getAttribute('data-gb-del'), 10);
        G.picks.splice(i, 1);
        if (G.active >= G.picks.length) G.active = G.picks.length - 1;
        renderGrid(); renderPicks(); renderCopy(); sync();
      });
    });
  }

  function renderCopy() {
    var box = $('#gbCopy');
    if (!box) return;
    var p = G.picks[G.active];
    if (!p) { box.innerHTML = '<div class="muted small">Optional — tap cards above to add up to ' + MAX_CARDS + '.</div>'; return; }
    var set = window.CardSets.get(p.setId);
    var card = set && set.byId.get(p.cardId);
    var info = copiesInfo(p.setId, p.cardId, G.active);
    if (!card || !info.e) { box.innerHTML = ''; return; }
    var canChoose = !p.variantId && info.regulars > 0 && info.holoRemain > 0 && info.plainRemain > 0;
    var holoOnly = !p.variantId && info.regulars > 0 && info.holoRemain > 0 && info.plainRemain <= 0;
    if (holoOnly) p.holo = true;
    var html = '<div class="gb-picked"><b>' + esc(card.name) + '</b> <span class="muted small">' + esc(set.name) +
      ' · ' + info.hand + ' on hand' + (info.e.h ? ' (' + info.e.h + ' holo)' : '') + ((info.e.v || 0) ? ' · ' + info.e.v + ' in Vault' : '') + '</span></div>';
    var serialChoices = info.serials.slice();
    if (p.variantId && !serialChoices.some(function (v) { return v.id === p.variantId; })) {
      var own = mySerials(p.setId, p.cardId).filter(function (v) { return v.id === p.variantId; })[0];
      if (own) serialChoices.unshift(own);
    }
    if (serialChoices.length || info.regulars > 0) {
      html += '<div class="gift-copies"><span class="fld-label">Which copy?</span>' +
        (info.regulars > 0 || !p.variantId ? '<label class="check"><input type="radio" name="gbCopy" value=""' + (!p.variantId ? ' checked' : '') + '> Regular copy</label>' : '') +
        serialChoices.map(function (v) {
          var vt = CPS.cards.VARIANTS[v.tier];
          return '<label class="check"><input type="radio" name="gbCopy" value="' + v.id + '"' +
            (p.variantId === v.id ? ' checked' : '') + '> ' + vt.name + ' #' + v.serial + '/' + vt.run + '</label>';
        }).join('') + '</div>';
    }
    if (canChoose) html += '<label class="inline"><input type="checkbox" id="gbHolo"' + (p.holo ? ' checked' : '') + '> Holographic copy</label>';
    else if (holoOnly) html += '<div class="muted small">Holographic copy</div>';
    if (info.e.n === 1 && G.picks.filter(function (x) { return x.setId === p.setId && x.cardId === p.cardId; }).length === 1)
      html += '<div class="warn-box">This is your last copy — you’ll no longer own this card.</div>';
    box.innerHTML = html;
    box.querySelectorAll('input[name=gbCopy]').forEach(function (r) {
      r.addEventListener('change', function () {
        p.variantId = r.value || null;
        if (p.variantId) p.holo = false;
        renderPicks(); renderCopy(); sync();
      });
    });
    var hb = $('#gbHolo');
    if (hb) hb.addEventListener('change', function () { p.holo = hb.checked; renderPicks(); sync(); });
  }

  function sync() {
    var recap = $('#gbRecap'), btn = $('#gbReviewBtn');
    var p = parts();
    if (recap) recap.innerHTML = p.length ? '🎁 ' + p.map(esc).join(' + ') : '<span class="muted">Nothing added yet — pick cards, packs, tokens, or tickets.</span>';
    if (btn) btn.disabled = !hasGift();
  }

  function num(v, max) {
    var n = parseInt(v, 10);
    if (!(n > 0)) return 0;
    return Math.min(n, max);
  }

  function closeOut(sent) {
    if (!G) { closeModal(true); return; }
    var rt = G.returnTo;
    if (sent) { lastDraft = null; lastTo = null; }
    else { lastDraft = G; lastTo = G.to; }
    G = null;
    CPS.modalCloseGuard = null;
    closeModal(true);
    if (rt) rt();
  }

  function showForm() {
    CPS.modalCloseGuard = function () { closeOut(false); return true; };
    var sets = myCardSets();
    if (!G.setId || !window.CardSets.get(G.setId) || G.setId === 'jumbled') G.setId = sets.length ? sets[0].id : '';
    var psets = packSets();
    openModal('<button class="modal-x" data-close aria-label="Close">×</button><div class="gift-modal">' +
      '<h2>🎁 Gift to ' + esc(G.toName) + '</h2>' +
      '<span class="fld-label">Cards (optional, up to ' + MAX_CARDS + ')</span>' +
      '<div class="gb-controls"><select id="gbSet">' + sets.map(function (s) {
        return '<option value="' + esc(s.id) + '"' + (s.id === G.setId ? ' selected' : '') + '>' + esc(s.name) + '</option>';
      }).join('') + '</select>' +
      '<input id="gbQ" type="search" placeholder="Search your cards…" value="' + esc(G.q) + '">' +
      '<select id="gbRarity"><option value="">All rarities</option>' +
      ((window.CPSRarities && window.CPSRarities.RARITIES) || ['common', 'uncommon', 'rare', 'epic', 'legendary', 'chase'].map(function (k) { return { key: k, label: k }; })).map(function (r) {
        return '<option value="' + esc(r.key) + '"' + (G.rarity === r.key ? ' selected' : '') + '>' + esc(r.label || r.key) + '</option>';
      }).join('') + '</select></div>' +
      '<div id="gbGrid"></div><div id="gbPicks"></div><div id="gbCopy"></div>' +
      '<span class="fld-label">Packs (optional)</span>' +
      '<div class="gb-controls"><select id="gbPackSet"><option value="">— No packs —</option>' + psets.map(function (s) {
        return '<option value="' + esc(s.id) + '"' + (s.id === G.packSet ? ' selected' : '') + '>' + esc(s.name) + ' — ' + packCount(s) + ' unopened</option>';
      }).join('') + '</select>' +
      '<input id="gbPacks" type="number" min="0" step="1" value="' + (G.packs || '') + '" placeholder="Qty"' + (G.packSet ? '' : ' disabled') + '></div>' +
      '<span class="fld-label">Tokens &amp; tickets (optional)</span>' +
      '<div class="gb-controls"><label class="gb-num">🪙 Tokens <span class="muted">(have ' + (S.gameTokens || 0) + ')</span>' +
      '<input id="gbTokens" type="number" min="0" step="1" value="' + (G.tokens || '') + '"></label>' +
      '<label class="gb-num">🎟️ Tickets <span class="muted">(have ' + (S.spins || 0) + ')</span>' +
      '<input id="gbTickets" type="number" min="0" step="1" value="' + (G.tickets || '') + '"></label></div>' +
      '<div id="gbRecap" class="gb-recap"></div>' +
      '<div class="gift-actions"><button class="btn primary" id="gbReviewBtn">Review gift</button></div></div>');

    $('#gbSet').addEventListener('change', function () { G.setId = this.value; G.shown = PAGE; renderGrid(); });
    $('#gbQ').addEventListener('input', function () { G.q = this.value.trim().toLowerCase(); G.shown = PAGE; renderGrid(); });
    $('#gbRarity').addEventListener('change', function () { G.rarity = this.value; G.shown = PAGE; renderGrid(); });
    $('#gbPackSet').addEventListener('change', function () {
      G.packSet = this.value;
      $('#gbPacks').disabled = !G.packSet;
      var max = G.packSet ? packCount(window.CardSets.get(G.packSet)) : 0;
      if (G.packs > max) { G.packs = max; $('#gbPacks').value = max || ''; }
      sync();
    });
    $('#gbPacks').addEventListener('input', function () { G.packs = num(this.value, G.packSet ? packCount(window.CardSets.get(G.packSet)) : 0); sync(); });
    $('#gbTokens').addEventListener('input', function () { G.tokens = num(this.value, S.gameTokens || 0); sync(); });
    $('#gbTickets').addEventListener('input', function () { G.tickets = num(this.value, S.spins || 0); sync(); });
    $('#gbReviewBtn').addEventListener('click', showConfirm);
    renderGrid(); renderPicks(); renderCopy(); sync();
  }

  function showConfirm() {
    if (!hasGift()) return;
    var art = G.picks.length ? '<div class="trade-items">' + G.picks.map(function (p) {
      var set = window.CardSets.get(p.setId);
      var card = set && set.byId.get(p.cardId);
      if (!set || !card) return '';
      var vv = p.variantId ? mySerials(p.setId, p.cardId).filter(function (v) { return v.id === p.variantId; })[0] : null;
      return '<div class="trade-card">' +
        CPS.cards.render(set, card, vv ? { variant: { tier: vv.tier, serial: vv.serial } } : { holo: p.holo }) +
        '<div class="trade-cap"><b>' + esc(card.name) + '</b><span class="muted small">' + esc(set.name) + '</span></div></div>';
    }).join('') + '</div>' : '';
    openModal('<button class="modal-x" data-close aria-label="Close">×</button><div class="gift-modal">' +
      '<h2>Confirm gift</h2>' +
      '<p>Send <b>' + esc(G.toName) + '</b>:</p>' + art +
      '<p>' + parts().map(esc).join('<br>') + '</p>' +
      '<p class="muted small">Gifts are sent instantly and can’t be undone.</p>' +
      '<div class="gift-actions"><button class="btn" id="gbBackBtn">Back</button>' +
      '<button class="btn primary" id="gbSendBtn">Send gift</button></div></div>');
    $('#gbBackBtn').addEventListener('click', showForm);
    $('#gbSendBtn').addEventListener('click', async function () {
      var btn = this; btn.disabled = true;
      try {
        await CPS.cloud.call('gift', { p_to: G.to, p_gift: {
          cards: G.picks.map(function (p) {
            return { set: p.setId, card: p.cardId, holo: p.variantId ? false : !!p.holo, variant_id: p.variantId || null };
          }),
          pack_set: G.packs > 0 ? G.packSet : null,
          packs: G.packs || 0, tokens: G.tokens || 0, tickets: G.tickets || 0 } });
        S.myVariants = null; refreshQuests();
        var name = G.toName;
        closeOut(true);
        toast('🎁 Gift sent to ' + name + '!');
        refreshCloud();
      } catch (err) { cloudError(err); btn.disabled = false; }
    });
  }

  async function open(toId, toName, opts) {
    openModal('<button class="modal-x" data-close aria-label="Close">×</button><div class="empty" style="padding:24px">Loading…</div>');
    try {
      /* Only the giver's owned sets can be picked from — load just
         those (this used to download every set file, ~8.5 MB). */
      if (C.ensureOwnedSets) await C.ensureOwnedSets();
      await ensureVariants();
      if (lastDraft && lastTo === toId) { G = lastDraft; lastDraft = null; }
      else {
        G = { to: toId, toName: toName, setId: '', q: '', rarity: '', shown: PAGE, picks: [], active: -1,
          packSet: '', packs: 0, tokens: 0, tickets: 0 };
      }
      G.to = toId; G.toName = toName;
      G.returnTo = (opts && opts.returnTo) || null;
      showForm();
    } catch (e) { closeModal(true); cloudError(e); }
  }

  CPS.giftBundle = { open: open };
})(window.CPS);

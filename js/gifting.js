/* Gifting: send one copy of a card to another player.
   Split out of js/app.js (which was outgrowing the push size limit).
   Uses the shared context exposed as CPS.appCtx; registers as CPS.gift.
   Vault-aware: vaulted copies (regular or numbered) can't be gifted —
   the pickers only offer on-hand copies. */
(function (CPS) {
  var C = CPS.appCtx;
  var S = C.S, $ = C.$, esc = C.esc, toast = C.toast, cloudError = C.cloudError;
  var openModal = C.openModal, closeModal = C.closeModal, ps = C.ps;
  var ensureVariants = C.ensureVariants, refreshQuests = C.refreshQuests;
  var renderCollection = C.renderCollection;

  function onHand(e) { return e ? Math.max(0, e.n - (e.v || 0)) : 0; }
  function mySerials(setId, cardId) {
    return (S.myVariants || []).filter(function (v) { return v.set_id === setId && v.card_id === cardId && !v.vaulted; })
      .sort(function (a, b) { return a.serial - b.serial; });
  }

  async function openGiftModal(setId, cardId) {
    var set = window.CardSets.get(setId), card = set && set.byId.get(cardId);
    if (set && !card && set.stub && window.CardSets.load) {
      try { await window.CardSets.load(setId); } catch (e) { /* fall through */ }
      set = window.CardSets.get(setId); card = set && set.byId.get(cardId);
    }
    if (!set || !card) return;
    if (setId === 'jumbled') {
      openModal('<button class="modal-x" data-close aria-label="Close">×</button><div class="empty" style="padding:24px">Jumbled Mess cards can’t be gifted.</div>');
      return;
    }
    var st = ps(set), e = st.cards[card.id];
    if (!e || !e.n) return;
    openModal('<div class="muted" style="padding:24px">Loading…</div>');
    try {
      var players = await CPS.cloud.call('list_players');
      var others = players.filter(function (p) { return !p.is_me; });
      if (!others.length) {
        openModal('<button class="modal-x" data-close aria-label="Close">×</button><div class="empty" style="padding:24px">No other players to gift to yet.</div>');
        return;
      }
      await ensureVariants();
      var serials = mySerials(setId, cardId);
      var hand = onHand(e);
      /* Numbered copies — vaulted or not — are never regular copies
         (same rule as the composers): reserve against ALL of them. */
      var allSerials = (S.myVariants || []).filter(function (v) { return v.set_id === setId && v.card_id === cardId; }).length;
      var regulars = Math.max(0, hand - allSerials);
      if (!regulars && !serials.length) {
        openModal('<button class="modal-x" data-close aria-label="Close">×</button><div class="empty" style="padding:24px">Every copy of this card is in your Vault 🔒 — release one before gifting it.</div>');
        return;
      }
      var holoOn = Math.max(0, e.h - (e.vh || 0));
      var plainOn = Math.max(0, (e.n - e.h) - ((e.v || 0) - (e.vh || 0)));
      var holoOnly = regulars > 0 && holoOn > 0 && plainOn === 0;
      var canChoose = regulars > 0 && holoOn > 0 && plainOn > 0;
      var holo = holoOnly;
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
          ' · ' + hand + ' on hand' + (e.h ? ' (' + e.h + ' holo)' : '') + ((e.v || 0) ? ' · ' + e.v + ' in Vault' : '') + '</span></div></div>' +
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
          var picked = document.querySelector('#modal input[name=giftCopy]:checked');
          var vid = picked ? picked.value || null : null;
          var vtext = null;
          if (vid) { var vv = serials.filter(function (s) { return s.id === vid; })[0];
            if (vv) vtext = CPS.cards.VARIANTS[vv.tier].name + ' #' + vv.serial + '/' + CPS.cards.VARIANTS[vv.tier].run; }
          showConfirm(toId, to ? to.display_name : '', holo, vid, vtext);
        });
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

  CPS.gift = { open: openGiftModal };
})(window.CPS);

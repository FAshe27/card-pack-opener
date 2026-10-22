/* Shared Market composer (Phase 2): ONE skeleton hosting the three
   Market forms — post a bounty, list a card, make an offer — so the
   picker / offer-builder / review behaviour can't drift apart again.
   Bounties.js and trading.js keep their boards, claim/cancel/detail
   modals, and thin openers (CPS.bounties.openPost /
   CPS.trading.openListing / CPS.trading.openOffer) that assemble this
   composer with a host adapter: open counts, card-face renderers, and
   the post-success board refresh. RPC params are byte-identical to the
   Phase 1 composers (pinned by the golden-params harness).
   Consumes CPS.appCtx. Loads after js/app.js, before bounties/trading. */
(function (CPS) {
  var ctx = CPS.appCtx;

  function esc(s) { return ctx.esc(s); }
  function setObj(id) { return window.CardSets.get(id); }
  function cardObj(sid, cid) { var s = setObj(sid); return s && s.byId.get(cid); }
  function sortByName(a) {
    return a.slice().sort(function (x, y) {
      var n = (x.name || '').toLowerCase(), m = (y.name || '').toLowerCase();
      return n < m ? -1 : (n > m ? 1 : 0);
    });
  }
  function sortByRarity(a, b) {
    var ra = (ctx.R.INDEX[a.rarity] || 0), rb = (ctx.R.INDEX[b.rarity] || 0);
    if (rb !== ra) return rb - ra;
    var n = (a.name || '').toLowerCase(), m = (b.name || '').toLowerCase();
    return n < m ? -1 : (n > m ? 1 : 0);
  }
  function lsGet(k) { try { return window.localStorage.getItem(k) || ''; } catch (e) { return ''; } }
  function lsSet(k, v) { try { window.localStorage.setItem(k, v); } catch (e) { /* storage unavailable */ } }
  function countLine(total, shown, searching) {
    if (searching) return total + (total === 1 ? ' match' : ' matches') + (shown < total ? ' · showing ' + shown : '');
    if (shown < total) return total + ' cards · showing the ' + shown + ' rarest — type to search';
    return total + (total === 1 ? ' card' : ' cards');
  }
  function variantCountMap() {
    if (ctx.variantCountMap) return ctx.variantCountMap();
    var m = {};
    (ctx.S.myVariants || []).forEach(function (v) {
      var k = v.set_id + ':' + v.card_id;
      m[k] = (m[k] || 0) + 1;
    });
    return m;
  }
  function myVariants() { return (ctx.S.myVariants || []).filter(function (v) { return !v.vaulted; }); }
  function variantLabel(tier, serial) {
    var v = CPS.cards.VARIANTS[tier];
    return v ? v.name + ' #' + serial + '/' + v.run : tier + ' #' + serial;
  }
  /* Gifting-style copy math: copies of a card actually on hand. */
  function plainOn(e) { return Math.max(0, (e.n - (e.h || 0)) - ((e.v || 0) - (e.vh || 0))); }
  function holoOn(e) { return Math.max(0, (e.h || 0) - (e.vh || 0)); }

  /* ------------------------------------------------ inline errors */
  /* One error area per form: validation problems land here in plain
     words at the point of failure (no toast stacks); toasts remain
     for success. Server rejections get plain-word translations for
     the known cases, the raw message only as fallback. */
  function showErrors(box, id, msgs) {
    var t = box.querySelector('#' + id); if (!t) return;
    if (!msgs || !msgs.length) { t.hidden = true; t.innerHTML = ''; t.classList.remove('cmp-note'); return; }
    t.classList.remove('cmp-note');
    t.innerHTML = msgs.map(function (m) { return '<div>' + esc(m) + '</div>'; }).join('');
    t.hidden = false;
  }
  function showNote(box, id, msg) {
    var t = box.querySelector('#' + id); if (!t) return;
    t.classList.add('cmp-note');
    t.innerHTML = '<div>' + esc(msg) + '</div>';
    t.hidden = false;
  }
  function translateError(e) {
    var m = String((e && e.message) || e || '');
    if (/already/i.test(m) && /(list|escrow|offer|bounty)/i.test(m)) {
      return 'That copy is already listed or in escrow.';
    }
    if (/(5 open|five open|cap|limit|maximum|too many)/i.test(m)) {
      return 'You already have 5 open — close one before posting another.';
    }
    if (/(no longer|not own|don\'t have|do not have|no more|not enough|insufficient)/i.test(m)) {
      return 'Your collection changed since you opened this form — check the amounts and try again.';
    }
    return m;
  }

  /* ------------------------------------------- return navigation */
  /* §2.3: a composer opened from the card modal (prefill.fromCard)
     captures CPS.cardBack at open; Cancel (with a discard confirm when
     dirty) and success restore it and re-open the origin card. */
  function makeSession(prefill) {
    if (!prefill || !prefill.fromCard) return null;
    return {
      fromCard: prefill.fromCard,
      savedBack: (prefill.cardBack !== undefined ? prefill.cardBack : CPS.cardBack),
      stash: null, snapshot: ''
    };
  }
  function returnToCard(sess) {
    if (!sess || !sess.fromCard) return;
    CPS.cardBack = sess.savedBack;
    var f = sess.fromCard;
    ctx.openCardModal(f.setId, f.cardId, f.holo, f.variant);
  }
  async function guardDiscard(sess, dirty) {
    if (!sess || !sess.fromCard || !dirty) return true;
    return !!(await ctx.confirmDialog('Discard this draft?',
      '<p>Go back to the card and throw away what you\'ve entered here?</p>', 'Discard'));
  }
  /* app.js ALSO closes the modal on any [data-close] click (a
     delegated #modal handler) and dismisses a pending confirmDialog
     as abort while doing so. The composer's [data-close] buttons are
     bound to its own CloseForm functions above, so their clicks must
     never reach that handler — otherwise a clean Cancel's return to
     the card is instantly closed again, and a dirty Cancel's discard
     dialog is aborted in the same event (the live Phase 3 spot-check
     defect). bindClose is the ONLY way composer modals bind
     [data-close]. */
  function bindClose(box, fn) {
    box.querySelectorAll('[data-close]').forEach(function (x) {
      x.addEventListener('click', function (e) { e.stopPropagation(); fn(); });
    });
  }
  function sanePrefill(p) {
    return (p && typeof p === 'object' &&
      (p.setId || p.cardId || p.copy || p.fromCard || p.cards || p.tokens != null)) ? p : null;
  }

  /* ================================================================ */
  /*                          POST A BOUNTY                          */
  /* ================================================================ */
  var HB = null;        // bounty host adapter
  var BD = null;        // bounty draft (survives stray closes)
  var BS = null;        // bounty return-nav session

  function allSets() {
    return sortByName(window.CardSets.all());
  }
  function freshBounty(sets) {
    return {
      sets: sets, wantSet: sets[0] ? sets[0].id : '', wantCard: null, q: '',
      offerSet: '', offerQ: '',
      holo: 'any', tier: '', serial: '', anyMode: false, numOpen: false,
      tokens: 0, tickets: 0, packSet: '', packs: 0,
      offerCards: [], _note: ''
    };
  }
  function seedBountyRemembered(d) {
    var rw = lsGet('cps.composerSet.want');
    if (d.sets.some(function (s) { return s.id === rw; })) d.wantSet = rw;
    var ro = lsGet('cps.composerSet.offer'), oSets = HB.offerSets();
    d.offerSet = oSets.some(function (s) { return s.id === ro; }) ? ro : (oSets[0] ? oSets[0].id : '');
  }
  function applyBountyPrefill(d, p) {
    if (p.setId && d.sets.some(function (s) { return s.id === p.setId; })) d.wantSet = p.setId;
    if (p.cardId) {
      if (cardObj(d.wantSet, p.cardId)) d.wantCard = { set: d.wantSet, id: p.cardId };
      else d._note = 'That card could not be found.';
    }
    if (p.copy) {
      if (p.copy.tier) {
        d.tier = p.copy.tier; d.numOpen = true;
        if (p.copy.serial != null) { d.serial = String(p.copy.serial); d.anyMode = false; }
        else d.anyMode = true;
      } else if (p.copy.holo) d.holo = 'holo';
    }
  }
  function snapBounty() {
    return JSON.stringify({
      w: BD.wantCard, h: BD.holo, t: BD.tier, s: BD.serial, a: BD.anyMode,
      tk: BD.tokens, ti: BD.tickets, ps: BD.packSet, pk: BD.packs, oc: BD.offerCards
    });
  }

  /* Lazy sets (boot diet): the bounty want-picker spans every set;
     listing/offer pickers span the sets the player owns cards in (plus
     the listing's own set for offers). Each opener loads what it
     needs first and re-enters itself when the data lands. */
  function ownedStubsPending() {
    var psets = (ctx.S && ctx.S.player && ctx.S.player.sets) || {};
    return Object.keys(psets).some(function (id) {
      var s = window.CardSets.get(id), st = psets[id];
      return !!(s && s.stub && st && st.cards && Object.keys(st.cards).length);
    });
  }

  function openBounty(host, prefill) {
    if (window.CardSets && window.CardSets.pending && window.CardSets.pending()) {
      ctx.openModal('<div class="muted" style="padding:24px">Loading set data…</div>');
      var hb = host, pf = prefill;
      window.CardSets.loadAll().then(function () { openBounty(hb, pf); });
      return;
    }
    HB = host;
    prefill = sanePrefill(prefill);
    var sets = allSets();
    if (prefill) {
      BS = makeSession(prefill);
      if (BS) BS.stash = BD;
      BD = freshBounty(sets);
      seedBountyRemembered(BD);
      applyBountyPrefill(BD, prefill);
      if (BS) BS.snapshot = snapBounty();
    } else {
      BS = null;
      if (!BD) { BD = freshBounty(sets); seedBountyRemembered(BD); }
      BD.sets = sets;
      if (!sets.some(function (s) { return s.id === BD.wantSet; })) BD.wantSet = sets[0] ? sets[0].id : '';
    }
    pbShowForm();
  }

  function pbShowForm() {
    ctx.openModal(
      '<button class="modal-x" data-close aria-label="Close">×</button>' +
      '<h3>Post a bounty</h3>' +
      (HB.myOpen() != null ? '<div class="muted small">Open bounties: ' + HB.myOpen() + ' of 5</div>' : '') +
      '<div class="cmp-errors" id="pbErrors" hidden></div>' +
      '<div class="bounty-form">' +
      '<h4>You want</h4>' +
      '<div class="row wrap"><label>Set <select id="pbSet"></select></label>' +
      '<label>Search <input id="pbSearch" placeholder="card name or #" size="18"></label></div>' +
      '<div id="pbWantSel" class="pb-pin"></div>' +
      '<div id="pbCardCount" class="muted small picker-count"></div>' +
      '<div id="pbCardResults" class="bounty-pick-grid"></div>' +
      '<div class="row wrap cmp-copyrow"><span class="muted small">Copy needed:</span>' +
      '<span class="cmp-seg" id="pbSeg">' +
      '<button type="button" data-mode="any">Any copy</button>' +
      '<button type="button" data-mode="holo">Holo only</button>' +
      '<button type="button" data-mode="numbered">Numbered…</button></span></div>' +
      '<div class="row wrap cmp-tierrow" id="pbTierRow">' +
      '<span class="muted small">Variant:</span>' +
      '<select id="pbTier"><option value="">—</option><option value="rainbow">Rainbow /50</option>' +
      '<option value="prism">Prism /10</option><option value="obsidian">Obsidian /5</option>' +
      '<option value="oneofone">One-of-One</option></select>' +
      '<span class="cmp-seg small" id="pbSubSeg">' +
      '<button type="button" data-sub="any">Any #</button>' +
      '<button type="button" data-sub="specific">Specific #</button></span>' +
      '<input id="pbSerial" type="number" min="1" placeholder="#" style="width:64px;flex:none">' +
      '<span class="muted small" id="pbTierHint"></span></div>' +
      '<h4>You offer</h4>' +
      '<div class="row wrap"><label>🪙 Tokens <input id="pbTokens" type="number" min="0" max="' + (ctx.S.gameTokens || 0) +
        '" value="0" style="width:80px"></label><span class="muted small" id="pbTokensHave"></span>' +
      '<label>🎟️ Tickets <input id="pbTickets" type="number" min="0" max="' + (ctx.S.spins || 0) +
        '" value="0" style="width:80px"></label><span class="muted small" id="pbTicketsHave"></span></div>' +
      '<div class="row wrap"><label>🎁 Packs <select id="pbPackSet"></select></label>' +
      '<input id="pbPacks" type="number" min="0" value="0" style="width:70px"><span class="muted small" id="pbPacksHave"></span></div>' +
      '<div class="row wrap"><label>🃏 Card <select id="pbCardSet"></select></label>' +
      '<label>Search <input id="pbCardSearch" placeholder="card name or #" size="18"></label></div>' +
      '<div id="pbOfferCount" class="muted small picker-count"></div>' +
      '<div id="pbOfferGrid" class="bounty-pick-grid"></div>' +
      '<div id="pbVariantHead" class="muted small" style="margin-top:8px"></div>' +
      '<div id="pbVariantGrid" class="bounty-pick-grid"></div>' +
      '<div class="row wrap"><span class="muted small">tap Add — or Add ✦ for a holo copy (up to 5 cards)</span></div>' +
      '<div id="pbOfferCards" class="bounty-offer-chips"></div>' +
      '<p class="muted small">Your offer is held in escrow until the bounty is claimed, cancelled, or expires (7 days).</p>' +
      '<div class="bounty-footer"><span class="bounty-recap" id="pbRecap"></span>' +
      '<button class="btn primary big" id="pbGo">Review bounty →</button>' +
      '<button class="btn" data-close>Cancel</button>' +
      '<button class="btn small" id="pbStartOver">Start over</button></div>' +
      '</div>',
      bindBountyForm);
  }

  /* Collect every DOM field into BD (the review screen replaces the
     form, so the submit path reads state, never the DOM). */
  function pbCollect(box) {
    BD.tokens = Math.max(0, parseInt(box.querySelector('#pbTokens').value, 10) || 0);
    BD.tickets = Math.max(0, parseInt(box.querySelector('#pbTickets').value, 10) || 0);
    BD.packSet = box.querySelector('#pbPackSet').value || '';
    BD.packs = Math.max(0, parseInt(box.querySelector('#pbPacks').value, 10) || 0);
    BD.serial = box.querySelector('#pbSerial').value || '';
    pbClampSerial(box);
  }

  /* The Phase 1 checks, same order, same words — now collected and
     shown together in the inline error area. */
  function pbValidate() {
    var msgs = [];
    if (!BD.wantCard) msgs.push('Pick the card you want first.');
    if (BD.packSet && !BD.packs) msgs.push('Set the pack count for your pack offer.');
    var packs = BD.packSet ? BD.packs : 0;
    if (!BD.tokens && !BD.tickets && !packs && !BD.offerCards.length) {
      msgs.push('Your bounty needs an offer — tokens, tickets, packs, or cards.');
    }
    var serial = (BD.serial || '').trim();
    // Any number (migration 141) satisfies a tier on its own; a serial
    // still needs a tier, and a tier alone still needs one or the other.
    if ((!BD.tier && serial) || (BD.tier && !serial && !BD.anyMode)) {
      msgs.push('A numbered serial needs both a tier and a number.');
    }
    return msgs;
  }

  function pbReview(box) {
    pbCollect(box);
    var msgs = pbValidate();
    if (msgs.length) { showErrors(box, 'pbErrors', msgs); return; }
    var serial = (BD.serial || '').trim();
    var offer = {
      offer_tokens: BD.tokens, offer_tickets: BD.tickets,
      offer_packs: BD.packSet ? BD.packs : 0, offer_pack_set: BD.packSet || null,
      offer_cards: BD.offerCards.map(function (o) { var c = { set_id: o.set, card_id: o.card, holo: o.holo }; if (o.tier) { c.tier = o.tier; c.serial = o.serial; } return c; })
    };
    var want = {
      want_set: BD.wantCard.set, want_card: BD.wantCard.id, want_holo: BD.holo,
      want_tier: BD.tier || null, want_serial: BD.anyMode ? null : (serial || null)
    };
    ctx.openModal(
      '<button class="modal-x" data-close aria-label="Close">×</button>' +
      '<h3>Review your bounty</h3>' +
      '<div class="cmp-errors" id="pbErrors" hidden></div>' +
      '<div class="bounty-tradebox"><div><span class="bounty-want-label">YOU GIVE</span><div>' + HB.offerBodyHtml(offer) + '</div></div>' +
      '<div class="bounty-trade-arrow">⇄</div>' +
      '<div><span class="bounty-want-label">YOU GET</span><div class="bounty-want">' + HB.wantFace(want) + '</div>' +
      '<div class="bounty-req">' + esc(HB.wantReq(want)) + '</div></div></div>' +
      '<p class="muted small">Your offer is held in escrow until the bounty is claimed, cancelled, or expires (7 days).</p>' +
      '<div class="row wrap"><button class="btn" id="pbBack">← Back</button>' +
      '<button class="btn primary big" id="pbConfirm">Post bounty — escrow my offer</button></div>',
      function (rbox) {
        bindClose(rbox, pbCloseForm);
        HB.bindCardClicks(rbox);
        rbox.querySelector('#pbBack').addEventListener('click', function () { pbShowForm(); });
        rbox.querySelector('#pbConfirm').addEventListener('click', function () { pbDoSubmit(rbox, this); });
      });
  }

  /* The Phase 1 submit body, reading BD instead of the DOM. The RPC
     params are byte-identical to the pre-composer submit (pinned by
     the golden-params harness). */
  async function pbDoSubmit(box, btn) {
    var serial = (BD.serial || '').trim();
    btn.disabled = true;
    try {
      await CPS.cloud.call('post_bounty', {
        p_want: { set: BD.wantCard.set, card: BD.wantCard.id, holo: BD.holo,
                  tier: BD.tier || null, serial: BD.anyMode ? null : (serial || null) },
        p_offer: { tokens: BD.tokens, tickets: BD.tickets, pack_set: BD.packSet || null,
                   packs: BD.packSet ? BD.packs : 0,
                   cards: BD.offerCards.map(function (o) { var c = { set: o.set, card: o.card, holo: o.holo }; if (o.tier) { c.tier = o.tier; c.serial = o.serial; } return c; }) }
      });
    } catch (e) {
      btn.disabled = false;
      showErrors(box, 'pbErrors', [translateError(e)]);
      return;
    }
    var sess = BS; BS = null;
    ctx.toast('Bounty posted!', 'good');
    ctx.audio.coin();
    if (sess && sess.fromCard) {
      BD = sess.stash || null;
      await HB.onPosted();
      await ctx.refreshCloud();
      returnToCard(sess);
    } else {
      BD = null;   // posted — the next open starts fresh
      ctx.closeModal();
      await HB.onPosted();
      await ctx.refreshCloud();
    }
  }

  async function pbCloseForm() {
    if (BS && BS.fromCard) {
      var dirty = snapBounty() !== BS.snapshot;
      /* A declined discard re-shows the form: app.js's confirmDialog
         closes the modal as it resolves, so returning bare would
         strand the user with no form. State is intact in BD. */
      if (!(await guardDiscard(BS, dirty))) { pbShowForm(); return; }
      var sess = BS; BS = null;
      BD = sess.stash || null;
      returnToCard(sess);
    } else {
      ctx.closeModal();
    }
  }

  function pbRecap(box) {
    var t = box.querySelector('#pbRecap'); if (!t) return;
    var want = 'Nothing wanted yet';
    if (BD.wantCard) {
      var c = cardObj(BD.wantCard.set, BD.wantCard.id);
      want = 'Wanting ' + (c ? c.name : BD.wantCard.id);
    }
    var bits = [];
    if (BD.tokens > 0) bits.push('🪙 ' + BD.tokens + ' token' + (BD.tokens === 1 ? '' : 's'));
    if (BD.tickets > 0) bits.push('🎟️ ' + BD.tickets + ' ticket' + (BD.tickets === 1 ? '' : 's'));
    if (BD.packSet && BD.packs > 0) {
      var ps = setObj(BD.packSet);
      bits.push('🎁 ' + BD.packs + ' ' + (ps ? ps.name : BD.packSet) + ' pack' + (BD.packs === 1 ? '' : 's'));
    }
    BD.offerCards.forEach(function (o) {
      var oc = cardObj(o.set, o.card);
      bits.push('🃏 ' + (oc ? oc.name : o.card) + (o.tier ? ' ' + pbVariantLabel(o) : (o.holo ? ' ✦' : '')));
    });
    t.textContent = want + ' · Offering ' + (bits.length ? bits.join(' + ') : 'nothing yet');
  }

  function pbRenderMoneyHints(box) {
    var th = box.querySelector('#pbTokensHave'), kh = box.querySelector('#pbTicketsHave');
    if (th) th.textContent = 'You have ' + (ctx.S.gameTokens || 0) + ' · ' + Math.max(0, (ctx.S.gameTokens || 0) - BD.tokens) + ' left after';
    if (kh) kh.textContent = 'You have ' + (ctx.S.spins || 0) + ' · ' + Math.max(0, (ctx.S.spins || 0) - BD.tickets) + ' left after';
  }

  function pbWantCard() { return BD.wantCard ? cardObj(BD.wantCard.set, BD.wantCard.id) : null; }
  function pbRarePlus() {
    var card = pbWantCard();
    return !!card && (ctx.R.INDEX[card.rarity] || 0) >= (ctx.R.INDEX.rare || 2);
  }
  function pbClearNumbered(box) {
    BD.tier = ''; BD.serial = ''; BD.anyMode = false;
    var tierSel = box.querySelector('#pbTier'), serialInp = box.querySelector('#pbSerial');
    if (tierSel) tierSel.value = '';
    if (serialInp) serialInp.value = '';
  }

  /* The segmented Copy-needed control (§2.5's four end states): Any
     copy / Holo only are the plain dimension; the Numbered segment
     expands in place to tier + Any # / Specific #. Numbered overlays
     the plain dimension rather than replacing it — a holo numbered
     want still submits holo + tier + serial, exactly like Phase 1. */
  function pbSyncCopy(box) {
    var tierSel = box.querySelector('#pbTier'), serialInp = box.querySelector('#pbSerial');
    var hint = box.querySelector('#pbTierHint');
    if (!tierSel || !serialInp) return;
    var rarePlus = pbRarePlus();
    if (!rarePlus && BD.tier) {
      pbClearNumbered(box);
      pbRenderWantSel(box);
    }
    if (!BD.tier) {
      BD.anyMode = false;
      if (BD.serial) {   // a serial without its tier is meaningless — clear it too
        BD.serial = '';
        var si0 = box.querySelector('#pbSerial'); if (si0) si0.value = '';
      }
    }
    var numberedOpen = BD.numOpen || !!BD.tier;
    var seg = box.querySelector('#pbSeg');
    if (seg) {
      seg.querySelector('[data-mode="any"]').classList.toggle('on', !numberedOpen && BD.holo === 'any');
      seg.querySelector('[data-mode="holo"]').classList.toggle('on', !numberedOpen && BD.holo === 'holo');
      var nb = seg.querySelector('[data-mode="numbered"]');
      nb.classList.toggle('on', numberedOpen);
      nb.disabled = !rarePlus;
    }
    var row = box.querySelector('#pbTierRow');
    if (row) row.classList.toggle('cmp-hidden', !numberedOpen);
    var sub = box.querySelector('#pbSubSeg');
    if (sub) {
      var anyBtn = sub.querySelector('[data-sub="any"]'), specBtn = sub.querySelector('[data-sub="specific"]');
      anyBtn.classList.toggle('on', !!BD.anyMode);
      anyBtn.disabled = !rarePlus || !BD.tier;
      specBtn.classList.toggle('on', !!BD.tier && !BD.anyMode);
      specBtn.disabled = !rarePlus || !BD.tier;
    }
    tierSel.disabled = !rarePlus;
    serialInp.disabled = !rarePlus || !BD.tier || BD.anyMode;
    serialInp.classList.toggle('cmp-hidden', !!BD.anyMode || !BD.tier);
    if (hint) hint.textContent = pbWantCard() && !rarePlus ? 'Numbered serials need a Rare or better card.' : '';
    pbClampSerial(box);
  }

  /* Numbered-serial sanity (Phase 1 §1.5): the serial can't exceed
     the tier's run. */
  function pbClampSerial(box) {
    if (!BD.tier) return;
    var v = CPS.cards.VARIANTS[BD.tier]; if (!v) return;
    var n = parseInt(BD.serial, 10);
    if (isNaN(n)) return;
    var c = Math.max(1, Math.min(v.run, n));
    if (String(c) !== String(BD.serial).trim()) {
      BD.serial = String(c);
      var inp = box.querySelector('#pbSerial'); if (inp) inp.value = BD.serial;
      pbRenderWantSel(box);
    }
  }

  function bindBountyForm(box) {
    bindClose(box, pbCloseForm);
    if (BD._note) { showNote(box, 'pbErrors', BD._note); BD._note = ''; }
    var setSel = box.querySelector('#pbSet');
    setSel.innerHTML = BD.sets.map(function (s) {
      return '<option value="' + esc(s.id) + '">' + esc(s.name) + '</option>';
    }).join('');
    setSel.value = BD.wantSet;
    setSel.addEventListener('change', function () {
      BD.wantSet = setSel.value; lsSet('cps.composerSet.want', BD.wantSet);
      BD.q = ''; box.querySelector('#pbSearch').value = ''; pbRenderResults(box);
    });

    var q = box.querySelector('#pbSearch');
    q.value = BD.q;
    q.addEventListener('input', function () { BD.q = q.value; pbRenderResults(box); });

    /* --- Copy needed: segmented control --- */
    var seg = box.querySelector('#pbSeg');
    seg.querySelector('[data-mode="any"]').addEventListener('click', function () {
      BD.holo = 'any'; pbClearNumbered(box); BD.numOpen = false;
      pbSyncCopy(box); pbRenderWantSel(box);
    });
    seg.querySelector('[data-mode="holo"]').addEventListener('click', function () {
      BD.holo = 'holo'; pbClearNumbered(box); BD.numOpen = false;
      pbSyncCopy(box); pbRenderWantSel(box);
    });
    seg.querySelector('[data-mode="numbered"]').addEventListener('click', function () {
      if (BD.numOpen || BD.tier) { pbClearNumbered(box); BD.numOpen = false; }
      else {
        BD.numOpen = true;
        if (!BD.tier) { BD.tier = 'rainbow'; box.querySelector('#pbTier').value = 'rainbow'; }
      }
      pbSyncCopy(box); pbRenderWantSel(box);
    });
    var sub = box.querySelector('#pbSubSeg');
    sub.querySelector('[data-sub="any"]').addEventListener('click', function () {
      BD.anyMode = true; pbSyncCopy(box); pbRenderWantSel(box);
    });
    sub.querySelector('[data-sub="specific"]').addEventListener('click', function () {
      BD.anyMode = false; pbSyncCopy(box); pbRenderWantSel(box);
      var si = box.querySelector('#pbSerial'); if (si) si.focus();
    });
    var tierSel = box.querySelector('#pbTier');
    tierSel.value = BD.tier;
    tierSel.addEventListener('change', function (e) { BD.tier = e.target.value; pbSyncCopy(box); pbRenderWantSel(box); });
    var serialInp = box.querySelector('#pbSerial');
    serialInp.value = BD.serial;
    serialInp.addEventListener('input', function (e) { BD.serial = e.target.value; pbRenderWantSel(box); });
    serialInp.addEventListener('change', function () { pbClampSerial(box); });

    // currency: keep BD in sync as you type; clamp to balance on change
    function bindMoney(inputSel, key, balance) {
      var inp = box.querySelector(inputSel);
      inp.value = BD[key];
      inp.addEventListener('input', function () {
        BD[key] = Math.max(0, parseInt(inp.value, 10) || 0);
        pbRenderMoneyHints(box); pbRecap(box);
      });
      inp.addEventListener('change', function () {
        var v = Math.max(0, Math.min(balance, parseInt(inp.value, 10) || 0));
        inp.value = v; BD[key] = v;
        pbRenderMoneyHints(box); pbRecap(box);
      });
    }
    bindMoney('#pbTokens', 'tokens', ctx.S.gameTokens || 0);
    bindMoney('#pbTickets', 'tickets', ctx.S.spins || 0);

    // pack offer: count disabled until a set is chosen, clamped to holdings
    var packSet = box.querySelector('#pbPackSet'), packsHave = box.querySelector('#pbPacksHave');
    var packsInp = box.querySelector('#pbPacks');
    var invSets = BD.sets.filter(function (s) { return s.id !== 'jumbled' && (ctx.ps({ id: s.id }).packs || 0) > 0; });
    packSet.innerHTML = '<option value="">—</option>' + invSets.map(function (s) {
      return '<option value="' + esc(s.id) + '">' + esc(s.name) + ' (' + ctx.ps({ id: s.id }).packs + ')</option>';
    }).join('');
    packSet.value = BD.packSet;
    function syncPacks() {
      BD.packSet = packSet.value;
      var n = BD.packSet ? (ctx.ps({ id: BD.packSet }).packs || 0) : 0;
      packsHave.textContent = BD.packSet ? 'you have ' + n : '';
      packsInp.disabled = !BD.packSet;
      packsInp.max = n;
      BD.packs = Math.max(0, Math.min(n, BD.packs || 0));
      packsInp.value = BD.packs;
      pbRecap(box);
    }
    packSet.addEventListener('change', syncPacks);
    packsInp.addEventListener('input', function () {
      BD.packs = Math.max(0, parseInt(packsInp.value, 10) || 0);
      pbRecap(box);
    });
    packsInp.addEventListener('change', syncPacks);
    syncPacks();

    // offer-card picker (same pick-grid pattern as "You want")
    var oSets = HB.offerSets();
    if (!oSets.some(function (s) { return s.id === BD.offerSet; })) BD.offerSet = oSets[0] ? oSets[0].id : '';
    var oSetSel = box.querySelector('#pbCardSet');
    oSetSel.innerHTML = oSets.map(function (s) {
      return '<option value="' + esc(s.id) + '">' + esc(s.name) + '</option>';
    }).join('');
    oSetSel.value = BD.offerSet;
    oSetSel.addEventListener('change', function () {
      BD.offerSet = oSetSel.value; lsSet('cps.composerSet.offer', BD.offerSet);
      BD.offerQ = '';
      box.querySelector('#pbCardSearch').value = '';
      pbRenderOfferGrid(box);
    });
    var oSearch = box.querySelector('#pbCardSearch');
    oSearch.value = BD.offerQ;
    oSearch.addEventListener('input', function (e) {
      BD.offerQ = e.target.value; pbRenderOfferGrid(box);
    });
    pbRenderOfferGrid(box);

    box.querySelector('#pbGo').addEventListener('click', function () { pbReview(box); });
    box.querySelector('#pbStartOver').addEventListener('click', function () {
      if (BS && BS.fromCard) {
        var keepSets = BD.sets;
        BD = freshBounty(keepSets); seedBountyRemembered(BD);
        BS.snapshot = snapBounty();
        pbShowForm();
      } else {
        BD = null; openBounty(HB, null);
      }
    });
    pbRenderResults(box);
    pbRenderOfferCards(box);
    pbRenderMoneyHints(box);
    pbSyncCopy(box);
    pbRecap(box);
    q.focus();
  }

  function pbRenderResults(box) {
    var s = setObj(BD.wantSet), grid = box.querySelector('#pbCardResults');
    if (!s) { grid.innerHTML = ''; return; }
    var q = BD.q.trim().toLowerCase(), list = [];
    s.cards.forEach(function (c) {
      if (q) {
        var hay = ('#' + c.num + ' ' + c.num + ' ' + c.name + ' ' + (c.subtitle || '')).toLowerCase();
        if (hay.indexOf(q) < 0) return;
      }
      list.push(c);
    });
    list.sort(sortByRarity);
    var matched = list.length;
    list = list.slice(0, 40);
    var cl = box.querySelector('#pbCardCount');
    if (cl) cl.textContent = countLine(matched, list.length, !!q);
    grid.innerHTML = list.map(function (c) {
      var sel = BD.wantCard && BD.wantCard.set === s.id && BD.wantCard.id === c.id;
      return '<button class="bounty-pick' + (sel ? ' selected' : '') + '" data-card="' + esc(c.id) + '">' +
        '<span class="bounty-pick-name">' + esc(c.name) + '</span>' +
        '<span><span class="muted small">#' + c.num + '</span> ' +
        '<span class="pill r-' + c.rarity + '">' + esc(c.rarity) + '</span></span></button>';
    }).join('') || '<div class="muted small">No matches.</div>';
    grid.querySelectorAll('[data-card]').forEach(function (btn) {
      btn.addEventListener('click', function () {
        var card = s.byId.get(btn.getAttribute('data-card'));
        BD.wantCard = { set: s.id, id: card.id };
        pbRenderResults(box); pbRenderWantSel(box); pbSyncCopy(box);
      });
    });
    pbRenderWantSel(box);
  }

  function pbRenderWantSel(box) {
    var t = box.querySelector('#pbWantSel');
    if (!BD.wantCard) { t.innerHTML = '<span class="muted small">No card selected yet.</span>'; pbRecap(box); return; }
    var card = cardObj(BD.wantCard.set, BD.wantCard.id);
    var extra = '';
    var v = BD.tier && CPS.cards.VARIANTS[BD.tier];
    if (BD.tier && BD.anyMode) extra = ' · ' + esc(v ? v.name : BD.tier) + ' — any number';
    else if (BD.tier && BD.serial) extra = ' · ' + esc(v ? v.name + ' #' + BD.serial + '/' + v.run : BD.tier + ' #' + BD.serial);
    else if (BD.tier || BD.serial) extra = ' · <span class="warn">serial needs both tier and number</span>';
    var shaped = {
      want_set: BD.wantCard.set, want_card: BD.wantCard.id, want_holo: BD.holo,
      want_tier: BD.tier || null, want_serial: BD.anyMode ? null : (BD.serial || null)
    };
    t.innerHTML = '<div class="bounty-want">' + HB.wantFace(shaped) + '</div>' +
      '<div class="pb-pin-text"><b>' + esc(card ? card.name : BD.wantCard.id) + '</b>' +
      (card ? ' <span class="pill r-' + card.rarity + '">' + esc(card.rarity) + '</span>' : '') +
      '<div class="muted small">Wanting (' + (BD.holo === 'holo' ? 'holo only' : 'any copy') + ')' + extra + '</div></div>';
    HB.bindCardClicks(t);
    pbRecap(box);
  }

  function pbOfferEntry(sid, cid) {
    var st = ctx.ps({ id: sid });
    return st.cards[cid] || { n: 0, h: 0 };
  }
  function pbHoloLeft(sid, cid) {
    var e = pbOfferEntry(sid, cid);
    var used = BD.offerCards.filter(function (o) { return o.set === sid && o.card === cid && o.holo && !o.tier; }).length;
    return holoOn(e) - used;
  }

  function pbRenderOfferCards(box) {
    var t = box.querySelector('#pbOfferCards');
    t.innerHTML = BD.offerCards.map(function (o, i) {
      var card = cardObj(o.set, o.card), s = setObj(o.set);
      var e = pbOfferEntry(o.set, o.card);
      var plainUsed = BD.offerCards.filter(function (x) { return x.set === o.set && x.card === o.card && !x.holo && !x.tier; }).length - (o.holo ? 0 : 1);
      var holoUsed = BD.offerCards.filter(function (x) { return x.set === o.set && x.card === o.card && x.holo && !x.tier; }).length - (o.holo ? 1 : 0);
      var canFlip = o.tier ? false : (o.holo ? (plainUsed < plainOn(e)) : (holoUsed < holoOn(e)));
      return '<span class="trade-chip"><b>' + esc(card ? card.name : o.card) + '</b>' +
        (o.tier ? ' ' + pbVariantLabel(o) : (o.holo ? ' ✦' : '')) +
        ' <span class="muted small">(' + esc(s ? s.name : o.set) + ')</span>' +
        (canFlip ? '<button class="chip-flip" data-flip="' + i + '" title="Flip between plain and holo">' + (o.holo ? 'make plain' : 'make ✦') + '</button>' : '') +
        '<button class="chip-x" data-rm="' + i + '" title="Remove">×</button></span>';
    }).join('') || '<span class="muted small">No cards offered yet.</span>';
    t.querySelectorAll('[data-rm]').forEach(function (x) {
      x.addEventListener('click', function () {
        BD.offerCards.splice(+x.getAttribute('data-rm'), 1);
        pbRenderOfferCards(box);
        pbRenderOfferGrid(box);
      });
    });
    t.querySelectorAll('[data-flip]').forEach(function (x) {
      x.addEventListener('click', function () {
        var o = BD.offerCards[+x.getAttribute('data-flip')];
        if (o) o.holo = !o.holo;
        pbRenderOfferCards(box);
        pbRenderOfferGrid(box);
      });
    });
    pbRecap(box);
  }

  function pbRenderOfferGrid(box) {
    var s = setObj(BD.offerSet), grid = box.querySelector('#pbOfferGrid');
    if (!s) { grid.innerHTML = '<div class="muted small">No cards to offer.</div>'; return; }
    var q = (BD.offerQ || '').trim().toLowerCase();
    var vmap = variantCountMap(), st = ctx.ps({ id: s.id }), list = [];
    s.cards.forEach(function (c) {
      var e = st.cards[c.id];
      var avail = e ? e.n - (e.v || 0) - (vmap[s.id + ':' + c.id] || 0) : 0;
      if (avail <= 0) return;
      var used = BD.offerCards.filter(function (o) { return o.set === s.id && o.card === c.id && !o.tier; }).length;
      if (avail - used <= 0) return;
      var usedPlain = BD.offerCards.filter(function (o) { return o.set === s.id && o.card === c.id && !o.holo && !o.tier; }).length;
      if (q) {
        var hay = ('#' + c.num + ' ' + c.num + ' ' + c.name + ' ' + (c.subtitle || '')).toLowerCase();
        if (hay.indexOf(q) < 0) return;
      }
      list.push({ card: c, left: avail - used, plainLeft: plainOn(e) - usedPlain, holo: (e.h || 0) - (e.vh || 0) > 0, holoLeft: pbHoloLeft(s.id, c.id) });
    });
    list.sort(function (x, y) { return sortByRarity(x.card, y.card); });
    var matched = list.length;
    list = list.slice(0, 40);
    var cl = box.querySelector('#pbOfferCount');
    if (cl) cl.textContent = countLine(matched, list.length, !!q);
    grid.innerHTML = list.map(function (o) {
      return '<div class="bounty-pick" data-card="' + esc(o.card.id) + '">' +
        '<span class="bounty-pick-name">' + esc(o.card.name) + (o.holo ? ' ✦' : '') + '</span>' +
        '<span class="cmp-rowacts"><span class="muted small">#' + o.card.num + '</span> ' +
        '<span class="pill r-' + o.card.rarity + '">' + esc(o.card.rarity) + '</span>' +
        ' <span class="muted small">×' + o.left + '</span>' +
        (o.plainLeft > 0 ? '<button type="button" class="btn small" data-add="' + esc(o.card.id) + '">Add</button>' : '') +
        (o.holoLeft > 0 ? '<button type="button" class="btn small" data-addholo="' + esc(o.card.id) + '">Add ✦</button>' : '') +
        '</span></div>';
    }).join('') || '<div class="muted small">No matches.</div>';
    grid.querySelectorAll('[data-add]').forEach(function (btn) {
      btn.addEventListener('click', function (ev) { ev.stopPropagation(); pbOfferAdd(box, s.id, btn.getAttribute('data-add'), false); });
    });
    grid.querySelectorAll('[data-addholo]').forEach(function (btn) {
      btn.addEventListener('click', function (ev) { ev.stopPropagation(); pbOfferAdd(box, s.id, btn.getAttribute('data-addholo'), true); });
    });
    grid.querySelectorAll('[data-card]').forEach(function (row) {
      row.addEventListener('click', function () { pbOfferAdd(box, s.id, row.getAttribute('data-card'), false); });
    });
    pbRenderVariantGrid(box);
  }

  function pbOfferAdd(box, sid, cid, asHolo) {
    if (BD.offerCards.length >= 5) { showErrors(box, 'pbErrors', ['At most 5 cards per bounty.']); return; }
    var st = ctx.ps({ id: sid }), e = st.cards[cid] || { n: 0, h: 0 };
    var vmap = variantCountMap();
    var avail = e.n - (e.v || 0) - (vmap[sid + ':' + cid] || 0);
    var used = BD.offerCards.filter(function (o) { return o.set === sid && o.card === cid && !o.tier; }).length;
    if (used >= avail) { showErrors(box, 'pbErrors', ['No more copies to offer.']); return; }
    if (asHolo) {
      var holoUsed = BD.offerCards.filter(function (o) { return o.set === sid && o.card === cid && o.holo && !o.tier; }).length;
      if (holoUsed >= holoOn(e)) { showErrors(box, 'pbErrors', ['You don\'t have another holo copy on hand.']); return; }
      BD.offerCards.push({ set: sid, card: cid, holo: true });
    } else {
      // A plain add needs a plain copy on hand — (n - h) - (v - vh).
      // This is the client half of the migration-139 incident: offering
      // the plain copy of a holo-only card used to sail through and
      // die on the server.
      var plainUsed = BD.offerCards.filter(function (o) { return o.set === sid && o.card === cid && !o.holo && !o.tier; }).length;
      if (plainUsed >= plainOn(e)) { showErrors(box, 'pbErrors', ['You don\'t have another plain copy on hand.']); return; }
      BD.offerCards.push({ set: sid, card: cid, holo: false });
    }
    showErrors(box, 'pbErrors', null);
    pbRenderOfferCards(box);
    pbRenderOfferGrid(box);
  }

  function pbVariantLabel(o) {
    var v = CPS.cards.VARIANTS[o.tier];
    return v ? v.emoji + ' #' + o.serial + '/' + v.run : o.tier + ' #' + o.serial;
  }

  /* Your numbered copies in the offer set (151): each row is ONE
     specific copy, offered as itself -- the server escrows that exact
     serial. Vaulted copies are not offerable (release them first). */
  function pbRenderVariantGrid(box) {
    var head = box.querySelector('#pbVariantHead'), grid = box.querySelector('#pbVariantGrid');
    if (!head || !grid) return;
    var s = setObj(BD.offerSet);
    var mine = (ctx.S.myVariants || []).filter(function (v) {
      return s && v.set_id === s.id && !v.vaulted;
    });
    var q = (BD.offerQ || '').trim().toLowerCase();
    if (q) mine = mine.filter(function (v) {
      var c = cardObj(v.set_id, v.card_id);
      var hay = ('#' + (c ? c.num : '') + ' ' + (c ? c.name : v.card_id) + ' ' + v.tier + ' #' + v.serial).toLowerCase();
      return hay.indexOf(q) >= 0;
    });
    mine.sort(function (x, y) {
      var cx = cardObj(x.set_id, x.card_id), cy = cardObj(y.set_id, y.card_id);
      var nx = cx ? cx.num : 0, ny = cy ? cy.num : 0;
      if (nx !== ny) return nx - ny;
      if (x.tier !== y.tier) return x.tier < y.tier ? -1 : 1;
      return x.serial - y.serial;
    });
    head.textContent = mine.length ? 'Your numbered copies in this set — each is a specific copy, offered as itself:' : '';
    grid.innerHTML = mine.map(function (v) {
      var c = cardObj(v.set_id, v.card_id), vt = CPS.cards.VARIANTS[v.tier];
      var inOffer = BD.offerCards.some(function (o) { return o.tier === v.tier && o.serial === v.serial && o.set === v.set_id && o.card === v.card_id; });
      return '<div class="bounty-pick">' +
        '<span class="bounty-pick-name">' + (vt ? vt.emoji : '') + ' ' + esc(c ? c.name : v.card_id) + ' <b>#' + v.serial + '/' + (vt ? vt.run : '') + '</b></span>' +
        '<span class="cmp-rowacts"><span class="pill r-' + (c ? c.rarity : 'rare') + '">' + esc(c ? c.rarity : '') + '</span> ' +
        (inOffer ? '<span class="muted small">in offer ✓</span>' : '<button type="button" class="btn small" data-vadd="' + esc(v.tier + ':' + v.serial + ':' + v.card_id) + '">Add</button>') +
        '</span></div>';
    }).join('');
    grid.querySelectorAll('[data-vadd]').forEach(function (btn) {
      btn.addEventListener('click', function (ev) {
        ev.stopPropagation();
        var parts = btn.getAttribute('data-vadd').split(':');
        var v = (ctx.S.myVariants || []).filter(function (x) {
          return x.set_id === BD.offerSet && x.card_id === parts[2] && x.tier === parts[0] && x.serial === +parts[1];
        })[0];
        if (v) pbVariantAdd(box, v);
      });
    });
  }

  function pbVariantAdd(box, v) {
    if (BD.offerCards.length >= 5) { showErrors(box, 'pbErrors', ['At most 5 cards per bounty.']); return; }
    if (v.vaulted) { showErrors(box, 'pbErrors', ['That numbered copy is in your Vault — release it first.']); return; }
    var dup = BD.offerCards.some(function (o) { return o.tier === v.tier && o.serial === v.serial && o.set === v.set_id && o.card === v.card_id; });
    if (dup) { showErrors(box, 'pbErrors', ['That numbered copy is already in your offer.']); return; }
    BD.offerCards.push({ set: v.set_id, card: v.card_id, holo: false, tier: v.tier, serial: v.serial });
    showErrors(box, 'pbErrors', null);
    pbRenderOfferCards(box);
    pbRenderOfferGrid(box);
  }

  /* ================================================================ */
  /*                          LIST A CARD                            */
  /* ================================================================ */
  var HT = null;        // trading host adapter (shared with offers)
  var LD = null;        // listing draft
  var LS = null;        // listing return-nav session

  function freshListing(sets) {
    return { sets: sets, set: sets[0] ? sets[0].id : '', card: null, q: '', holo: false, copy: 'regular', note: '', _note: '' };
  }
  function seedListingRemembered(d) {
    var rl = lsGet('cps.composerSet.list');
    if (d.sets.some(function (s) { return s.id === rl; })) d.set = rl;
  }
  function snapListing() {
    return JSON.stringify({ c: LD.card, cp: LD.copy, h: LD.holo, n: LD.note });
  }

  function openListing(host, prefill) {
    if (ctx.ensureOwnedSets && window.CardSets && window.CardSets.pending && ownedStubsPending()) {
      ctx.openModal('<div class="muted" style="padding:24px">Loading set data…</div>');
      var ht = host, pf2 = prefill;
      ctx.ensureOwnedSets().then(function () { openListing(ht, pf2); });
      return;
    }
    HT = host;
    prefill = sanePrefill(prefill);
    var sets = HT.ownedSets();
    if (prefill) {
      LS = makeSession(prefill);
      if (LS) LS.stash = LD;
      LD = freshListing(sets);
      seedListingRemembered(LD);
      applyListingPrefill(LD, prefill);
      if (LS) LS.snapshot = snapListing();
    } else {
      LS = null;
      if (!LD) { LD = freshListing(sets); seedListingRemembered(LD); }
      LD.sets = sets;
      if (!sets.some(function (s) { return s.id === LD.set; })) {
        LD.set = sets[0] ? sets[0].id : '';
        if (LD.card && LD.card.set !== LD.set) { LD.card = null; LD.copy = 'regular'; }
      }
    }
    plShowForm();
  }

  function applyListingPrefill(d, p) {
    if (p.setId && d.sets.some(function (s) { return s.id === p.setId; })) d.set = p.setId;
    if (!p.cardId) return;
    var s = setObj(d.set), st = s ? ctx.ps({ id: d.set }) : null;
    var e = st && st.cards[p.cardId];
    if (!s || !e || e.n - (e.v || 0) <= 0) {
      d._note = 'You don\'t have that card on hand any more.';
      return;
    }
    d.card = { set: d.set, id: p.cardId };
    if (!p.copy) return;
    var copies = plCopiesFor(d);
    if (p.copy.tier) {
      var key = p.copy.tier + ':' + p.copy.serial;
      if (copies.some(function (c) { return c.key === key; })) {
        d.copy = key;
        d.holo = !!p.copy.holo;
      } else {
        d._note = 'That numbered copy isn\'t on hand any more — pick the copy to list.';
      }
    } else if (p.copy.holo) {
      if (copies.some(function (c) { return c.key === 'regular'; })) {
        d.copy = 'regular'; d.holo = true;
      } else {
        d._note = 'That plain copy isn\'t on hand any more — pick the copy to list.';
      }
    }
  }

  function plShowForm() {
    ctx.openModal(
      '<button class="modal-x" data-close aria-label="Close">×</button>' +
      '<h3>List a card</h3>' +
      (HT.myOpen() != null ? '<div class="muted small">Open listings: ' + HT.myOpen() + ' of 5</div>' : '') +
      '<div class="cmp-errors" id="tpErrors" hidden></div>' +
      '<div class="trade-form">' +
      '<div class="row wrap"><label>Set <select id="tpSet"></select></label>' +
      '<label>Search <input id="tpSearch" placeholder="card name or #" size="18"></label></div>' +
      '<div id="tpCardSel" class="tp-pin"></div>' +
      '<div id="tpCardCount" class="muted small picker-count"></div>' +
      '<div id="tpCardGrid" class="tp-pick-grid"></div>' +
      '<div id="tpCopyRows" class="cmp-copyrows"></div>' +
      '<div class="row wrap"><label>What are you looking for? (optional) <input id="tpNote" placeholder="e.g. Detroit Tigers cards" size="30" maxlength="140"></label></div>' +
      '<p class="muted small">Your card is escrowed until the listing is accepted, cancelled, or expires (7 days).</p>' +
      '<div class="trade-footer"><span class="trade-recap" id="tpRecap"></span>' +
      '<button class="btn primary big" id="tpGo">Review listing →</button>' +
      '<button class="btn" data-close>Cancel</button>' +
      '<button class="btn small" id="tpStartOver">Start over</button></div>' +
      '</div>',
      bindListingForm);
  }

  function plCopyDesc(c0) {
    if (c0 && c0.tier) return variantLabel(c0.tier, c0.serial);
    return LD.holo ? 'Holo copy' : 'Plain copy';
  }

  function plReview(box) {
    LD.note = box.querySelector('#tpNote').value || '';
    if (!LD.card) { showErrors(box, 'tpErrors', ['Pick a card to list first.']); return; }
    var copies = plCopiesFor(LD);
    var c0 = copies.filter(function (c) { return c.key === LD.copy; })[0] || { tier: null, serial: null };
    var card = cardObj(LD.card.set, LD.card.id), s = setObj(LD.card.set);
    var note = (LD.note || '').trim();
    var shaped = {
      set_id: LD.card.set, card_id: LD.card.id, holo: LD.holo,
      variant_tier: c0.tier || null, variant_serial: c0.serial || null,
      card_name: card ? card.name : LD.card.id, set_name: s ? s.name : LD.card.set,
      rarity: card ? card.rarity : ''
    };
    ctx.openModal(
      '<button class="modal-x" data-close aria-label="Close">×</button>' +
      '<h3>Review your listing</h3>' +
      '<div class="cmp-errors" id="tpErrors" hidden></div>' +
      '<div class="trade-reviewbox"><div class="trade-face">' + HT.listingFace(shaped) + '</div>' +
      '<div><div class="trade-cardname">' + esc(shaped.card_name) + '</div>' +
      '<div class="muted small">' + esc(shaped.set_name) + ' · ' + esc(shaped.rarity) + '</div>' +
      '<div>' + esc(plCopyDesc(c0)) + '</div>' +
      (note ? '<div class="trade-note"><span class="muted small">Looking for: </span>“' + esc(note) + '”</div>' : '') +
      '</div></div>' +
      '<p class="muted small">Your card is escrowed until the listing is accepted, cancelled, or expires (7 days).</p>' +
      '<div class="row wrap"><button class="btn" id="tpBack">← Back</button>' +
      '<button class="btn primary big" id="tpConfirm">List it — escrow my card</button></div>',
      function (rbox) {
        bindClose(rbox, plCloseForm);
        HT.bindCardClicks(rbox);
        rbox.querySelector('#tpBack').addEventListener('click', function () { plShowForm(); });
        rbox.querySelector('#tpConfirm').addEventListener('click', function () { plDoSubmit(rbox, this); });
      });
  }

  /* The Phase 1 submit body, reading LD instead of the DOM. Params
     byte-identical to the pre-composer submit (golden-pinned). */
  async function plDoSubmit(box, btn) {
    var copies = plCopiesFor(LD);
    var c0 = copies.filter(function (c) { return c.key === LD.copy; })[0] || { tier: null, serial: null };
    btn.disabled = true;
    try {
      await CPS.cloud.call('trade_post', {
        p_card: { set: LD.card.set, card: LD.card.id, holo: LD.holo,
                  tier: c0.tier || null, serial: c0.serial || null },
        p_note: (LD.note || '').trim()
      });
    } catch (e) {
      btn.disabled = false;
      showErrors(box, 'tpErrors', [translateError(e)]);
      return;
    }
    var sess = LS; LS = null;
    ctx.toast('Card listed!', 'good');
    ctx.audio.coin();
    if (sess && sess.fromCard) {
      LD = sess.stash || null;
      await ctx.refreshCloud();
      returnToCard(sess);
    } else {
      LD = null;   // listed — the next open starts fresh
      HT.onListed();
      await ctx.refreshCloud();
    }
  }

  async function plCloseForm() {
    if (LS && LS.fromCard) {
      var dirty = snapListing() !== LS.snapshot;
      if (!(await guardDiscard(LS, dirty))) { plShowForm(); return; }
      var sess = LS; LS = null;
      LD = sess.stash || null;
      returnToCard(sess);
    } else {
      ctx.closeModal();
    }
  }

  function plRecap(box) {
    var t = box.querySelector('#tpRecap'); if (!t) return;
    if (!LD || !LD.card) { t.textContent = 'No card picked yet'; return; }
    var card = cardObj(LD.card.set, LD.card.id);
    var copies = plCopiesFor(LD);
    var c0 = copies.filter(function (c) { return c.key === LD.copy; })[0];
    var suffix = '';
    if (c0 && c0.tier) suffix = ' (' + variantLabel(c0.tier, c0.serial) + ')';
    else if (LD.holo) suffix = ' (holo)';
    t.textContent = 'Listing ' + (card ? card.name : LD.card.id) + suffix;
  }

  function bindListingForm(box) {
    bindClose(box, plCloseForm);
    if (LD._note) { showNote(box, 'tpErrors', LD._note); LD._note = ''; }
    var setSel = box.querySelector('#tpSet');
    setSel.innerHTML = LD.sets.map(function (s) {
      return '<option value="' + esc(s.id) + '">' + esc(s.name) + '</option>';
    }).join('');
    setSel.value = LD.set;
    setSel.addEventListener('change', function () {
      LD.set = setSel.value; lsSet('cps.composerSet.list', LD.set);
      LD.card = null; LD.q = '';
      box.querySelector('#tpSearch').value = '';
      plRenderGrid(box); plRenderSel(box);
    });
    var search = box.querySelector('#tpSearch');
    search.value = LD.q;
    search.addEventListener('input', function (e) {
      LD.q = e.target.value; plRenderGrid(box);
    });
    var noteInp = box.querySelector('#tpNote');
    noteInp.value = LD.note;
    noteInp.addEventListener('input', function (e) { LD.note = e.target.value; });
    box.querySelector('#tpGo').addEventListener('click', function () { plReview(box); });
    box.querySelector('#tpStartOver').addEventListener('click', function () {
      if (LS && LS.fromCard) {
        var keepSets = LD.sets;
        LD = freshListing(keepSets); seedListingRemembered(LD);
        LS.snapshot = snapListing();
        plShowForm();
      } else {
        LD = null; openListing(HT, null);
      }
    });
    plRenderGrid(box); plRenderSel(box);
    search.focus();
  }

  function plRenderGrid(box) {
    var s = setObj(LD.set), grid = box.querySelector('#tpCardGrid');
    if (!s) { grid.innerHTML = ''; return; }
    var q = LD.q.trim().toLowerCase(), st = ctx.ps({ id: s.id }), list = [];
    s.cards.forEach(function (c) {
      var e = st.cards[c.id];
      if (!e || e.n - (e.v || 0) <= 0) return;
      if (q) {
        var hay = ('#' + c.num + ' ' + c.num + ' ' + c.name + ' ' + (c.subtitle || '')).toLowerCase();
        if (hay.indexOf(q) < 0) return;
      }
      list.push({ card: c, left: e.n - (e.v || 0) });
    });
    list.sort(function (x, y) { return sortByRarity(x.card, y.card); });
    var matched = list.length;
    list = list.slice(0, 40);
    var cl = box.querySelector('#tpCardCount');
    if (cl) cl.textContent = countLine(matched, list.length, !!q);
    grid.innerHTML = list.map(function (o) {
      var sel = LD.card && LD.card.set === s.id && LD.card.id === o.card.id;
      return '<button class="tp-pick' + (sel ? ' selected' : '') + '" data-card="' + esc(o.card.id) + '">' +
        '<span class="tp-pick-name">' + esc(o.card.name) + '</span>' +
        '<span><span class="muted small">#' + o.card.num + '</span> ' +
        '<span class="pill r-' + o.card.rarity + '">' + esc(o.card.rarity) + '</span>' +
        ' <span class="muted small">×' + o.left + '</span></span></button>';
    }).join('') || '<div class="muted small">No matches.</div>';
    grid.querySelectorAll('[data-card]').forEach(function (btn) {
      btn.addEventListener('click', function () {
        var card = s.byId.get(btn.getAttribute('data-card'));
        LD.card = { set: s.id, id: card.id };
        LD.copy = 'regular';
        plRenderGrid(box); plRenderSel(box);
      });
    });
  }

  /* Which physical copies of the picked card can be listed — the
     Phase 1 plCopies() enumeration (variant instances + a regular
     bucket), unchanged. */
  function plCopiesFor(d) {
    if (!d.card) return [];
    var st = ctx.ps({ id: d.card.set }), e = st.cards[d.card.id] || { n: 0, h: 0 };
    var out = [];
    var vmap = {};
    myVariants().forEach(function (v) {
      if (v.set_id === d.card.set && v.card_id === d.card.id) {
        vmap[v.tier + ':' + v.serial] = v;
        out.push({ key: v.tier + ':' + v.serial, label: variantLabel(v.tier, v.serial), tier: v.tier, serial: v.serial });
      }
    });
    var vcount = Object.keys(vmap).length;
    if (e.n - (e.v || 0) - vcount > 0) out.unshift({ key: 'regular', label: 'Regular copy (×' + (e.n - (e.v || 0) - vcount) + ')', tier: null, serial: null });
    return out;
  }

  /* The pinned pick + per-copy rows. The old (copy <select> + global
     holo checkbox) pair becomes one row per physical copy: the regular
     bucket splits into plain / ✦ holo rows when both are on hand, and
     a variant row carries its own ✦ toggle (variant + holo stays
     expressible, as it was in Phase 1). */
  function plRenderSel(box) {
    var t = box.querySelector('#tpCardSel'), rows = box.querySelector('#tpCopyRows');
    if (!LD.card) {
      t.innerHTML = '<span class="muted small">No card selected yet.</span>';
      if (rows) rows.innerHTML = '';
      plRecap(box); return;
    }
    var card = cardObj(LD.card.set, LD.card.id), s = setObj(LD.card.set);
    var copies = plCopiesFor(LD);
    if (!copies.some(function (c) { return c.key === LD.copy; })) LD.copy = copies[0] ? copies[0].key : 'regular';
    var c0 = copies.filter(function (c) { return c.key === LD.copy; })[0];
    var shaped = {
      set_id: LD.card.set, card_id: LD.card.id, holo: LD.holo,
      variant_tier: c0 && c0.tier ? c0.tier : null, variant_serial: c0 && c0.serial ? c0.serial : null,
      card_name: card ? card.name : LD.card.id, set_name: s ? s.name : LD.card.set,
      rarity: card ? card.rarity : ''
    };
    t.innerHTML = '<div class="trade-face">' + HT.listingFace(shaped) + '</div>' +
      '<div class="tp-pin-text"><b>' + esc(card ? card.name : LD.card.id) + '</b>' +
      (card ? ' <span class="pill r-' + card.rarity + '">' + esc(card.rarity) + '</span>' : '') +
      '<div class="muted small">Listing' +
      (c0 && c0.tier ? ' · ' + esc(variantLabel(c0.tier, c0.serial)) : '') +
      (LD.holo ? ' · ✦ holo' : '') + '</div></div>';
    HT.bindCardClicks(t);

    if (rows) {
      var st = ctx.ps({ id: LD.card.set }), e = st.cards[LD.card.id] || { n: 0, h: 0 };
      var holoAvail = holoOn(e) > 0;
      var html = '<div class="muted small cmp-copyrows-label">Which copy?</div>';
      copies.forEach(function (c) {
        if (c.key === 'regular') {
          html += '<div class="cmp-copyrow' + (LD.copy === 'regular' && !LD.holo ? ' selected' : '') + '">' +
            '<button type="button" class="cmp-copybtn" data-copy="regular" data-holo="0">' + esc(c.label) + '</button></div>';
          if (holoAvail) {
            html += '<div class="cmp-copyrow' + (LD.copy === 'regular' && LD.holo ? ' selected' : '') + '">' +
              '<button type="button" class="cmp-copybtn" data-copy="regular" data-holo="1">Regular copy ✦ holo</button></div>';
          }
        } else {
          html += '<div class="cmp-copyrow' + (LD.copy === c.key ? ' selected' : '') + '">' +
            '<button type="button" class="cmp-copybtn" data-copy="' + esc(c.key) + '">' + esc(c.label) + '</button>' +
            (holoAvail ? '<button type="button" class="cmp-holo-toggle' + (LD.copy === c.key && LD.holo ? ' on' : '') + '" data-vholo="' + esc(c.key) + '" title="This copy is a holo">✦ holo</button>' : '') +
            '</div>';
        }
      });
      rows.innerHTML = html;
      rows.querySelectorAll('[data-copy]').forEach(function (btn) {
        btn.addEventListener('click', function () {
          LD.copy = btn.getAttribute('data-copy');
          var h = btn.getAttribute('data-holo');
          if (h != null) LD.holo = (h === '1');
          plRenderSel(box);
        });
      });
      rows.querySelectorAll('[data-vholo]').forEach(function (btn) {
        btn.addEventListener('click', function () {
          LD.copy = btn.getAttribute('data-vholo');
          LD.holo = !LD.holo;
          plRenderSel(box);
        });
      });
    }
    plRecap(box);
  }

  /* ================================================================ */
  /*                          MAKE AN OFFER                          */
  /* ================================================================ */
  var OD = null;        // offer form state (fresh every open, as today)
  var OS = null;        // offer return-nav session

  function openOffer(host, listing, prefill) {
    var lset = listing && listing.set_id ? window.CardSets.get(listing.set_id) : null;
    if ((ctx.ensureOwnedSets && ownedStubsPending()) || (lset && lset.stub)) {
      ctx.openModal('<div class="muted" style="padding:24px">Loading set data…</div>');
      var ho = host, li = listing, pf3 = prefill;
      var jobs = [];
      if (ctx.ensureOwnedSets) jobs.push(ctx.ensureOwnedSets());
      if (lset && lset.stub) jobs.push(window.CardSets.load(listing.set_id));
      Promise.all(jobs).then(function () { openOffer(ho, li, pf3); });
      return;
    }
    HT = host;
    prefill = sanePrefill(prefill);
    var sets = HT.ownedSets();
    OD = {
      listing: listing, sets: sets, set: sets[0] ? sets[0].id : '', q: '',
      tokens: 0, tickets: 0, packSet: '', packs: 0,
      cards: []   // {set, card, holo, tier, serial, label}
    };
    var ro = lsGet('cps.composerSet.offer');
    if (sets.some(function (s) { return s.id === ro; })) OD.set = ro;
    OS = makeSession(prefill);
    if (prefill) applyOfferPrefill(prefill);
    if (OS) OS.snapshot = snapOffer();
    ofShowForm();
  }

  function applyOfferPrefill(p) {
    if (p.tokens != null) OD.tokens = Math.max(0, parseInt(p.tokens, 10) || 0);
    if (p.tickets != null) OD.tickets = Math.max(0, parseInt(p.tickets, 10) || 0);
    if (p.packSet) OD.packSet = p.packSet;
    if (p.packs != null) OD.packs = Math.max(0, parseInt(p.packs, 10) || 0);
    (p.cards || []).forEach(function (c) {
      var card = cardObj(c.set, c.card);
      if (!card) return;
      var label = card.name + (c.tier ? ' — ' + variantLabel(c.tier, c.serial) : '');
      OD.cards.push({ set: c.set, card: c.card, holo: !!c.holo, tier: c.tier || null, serial: c.serial || null, label: label });
    });
    if (p.copy && p.setId && p.cardId) {
      var card2 = cardObj(p.setId, p.cardId);
      if (card2 && !OD.cards.some(function (o) { return o.set === p.setId && o.card === p.cardId; })) {
        OD.cards.push({
          set: p.setId, card: p.cardId, holo: !!p.copy.holo,
          tier: p.copy.tier || null, serial: p.copy.serial || null,
          label: card2.name + (p.copy.tier ? ' — ' + variantLabel(p.copy.tier, p.copy.serial) : '')
        });
      }
    }
  }
  function snapOffer() {
    return JSON.stringify({ tk: OD.tokens, ti: OD.tickets, ps: OD.packSet, pk: OD.packs, c: OD.cards });
  }

  function ofShowForm() {
    var l = OD.listing;
    ctx.openModal(
      '<button class="modal-x" data-close aria-label="Close">×</button>' +
      '<h3>Make an offer</h3>' +
      '<p class="muted small">For <b>' + esc(l.card_name || l.card_id) + '</b>' +
      (l.variant_tier ? ' (' + esc(variantLabel(l.variant_tier, l.variant_serial)) + ')' : '') +
      ' — everything you offer is escrowed until the listing closes.</p>' +
      '<div class="cmp-errors" id="ofErrors" hidden></div>' +
      '<div class="trade-form">' +
      '<div class="row wrap"><label>🪙 Tokens <input id="ofTokens" type="number" min="0" max="' + (ctx.S.gameTokens || 0) +
        '" value="0" style="width:80px"></label><span class="muted small" id="ofTokensHave"></span>' +
      '<label>🎟️ Tickets <input id="ofTickets" type="number" min="0" max="' + (ctx.S.spins || 0) +
        '" value="0" style="width:80px"></label><span class="muted small" id="ofTicketsHave"></span></div>' +
      '<div class="row wrap"><label>🎁 Packs <select id="ofPackSet"></select></label>' +
      '<input id="ofPacks" type="number" min="0" value="0" style="width:70px"><span class="muted small" id="ofPacksHave"></span></div>' +
      '<div class="row wrap"><label>🃏 Card <select id="ofCardSet"></select></label>' +
      '<label>Search <input id="ofCardSearch" placeholder="card name or #" size="18"></label></div>' +
      '<div id="ofCardCount" class="muted small picker-count"></div>' +
      '<div id="ofCardGrid" class="tp-pick-grid"></div>' +
      '<div class="row wrap"><span class="muted small">tap Add — or Add ✦ for a holo copy (up to 5 — numbered serials listed separately)</span></div>' +
      '<div id="ofCards" class="trade-offer-chips"></div>' +
      '<div class="trade-footer"><span class="trade-recap" id="ofRecap"></span>' +
      '<button class="btn primary big" id="ofGo">Submit offer</button>' +
      '<button class="btn" data-close>Cancel</button></div>' +
      '</div>',
      bindOfferForm);
  }

  function ofRecap(box) {
    var t = box.querySelector('#ofRecap'); if (!t) return;
    var bits = [];
    if (OD.tokens > 0) bits.push('🪙 ' + OD.tokens + ' token' + (OD.tokens === 1 ? '' : 's'));
    if (OD.tickets > 0) bits.push('🎟️ ' + OD.tickets + ' ticket' + (OD.tickets === 1 ? '' : 's'));
    if (OD.packSet && OD.packs > 0) {
      var ps = setObj(OD.packSet);
      bits.push('🎁 ' + OD.packs + ' ' + (ps ? ps.name : OD.packSet) + ' pack' + (OD.packs === 1 ? '' : 's'));
    }
    OD.cards.forEach(function (o) { bits.push('🃏 ' + o.label + (o.holo ? ' ✦' : '')); });
    var l = OD.listing;
    t.textContent = 'For ' + (l.card_name || l.card_id) + ' · Offering ' + (bits.length ? bits.join(' + ') : 'nothing yet');
  }

  function bindOfferForm(box) {
    bindClose(box, ofCloseForm);
    // pack picker
    var packSet = box.querySelector('#ofPackSet'), packsHave = box.querySelector('#ofPacksHave');
    var invSets = OD.sets.filter(function (s) { return (ctx.ps({ id: s.id }).packs || 0) > 0; });
    packSet.innerHTML = '<option value="">—</option>' + invSets.map(function (s) {
      return '<option value="' + esc(s.id) + '">' + esc(s.name) + ' (' + ctx.ps({ id: s.id }).packs + ')</option>';
    }).join('');
    packSet.value = OD.packSet;
    var packsInp = box.querySelector('#ofPacks');
    function syncPacks() {
      OD.packSet = packSet.value;
      var n = OD.packSet ? (ctx.ps({ id: OD.packSet }).packs || 0) : 0;
      packsHave.textContent = OD.packSet ? 'you have ' + n : '';
      packsInp.disabled = !OD.packSet;
      packsInp.max = n;
      OD.packs = Math.max(0, Math.min(n, parseInt(packsInp.value, 10) || 0));
      packsInp.value = OD.packs;
      ofRecap(box);
    }
    packSet.addEventListener('change', syncPacks);
    packsInp.addEventListener('input', function () { OD.packs = Math.max(0, parseInt(packsInp.value, 10) || 0); ofRecap(box); });
    packsInp.addEventListener('change', syncPacks);
    packsInp.value = OD.packs;
    syncPacks();
    // currency: keep OD in sync as you type; clamp to balance on change
    function ofMoney(inputSel, hintSel, key, balance) {
      var inp = box.querySelector(inputSel), hint = box.querySelector(hintSel);
      function paint() {
        var v = Math.max(0, parseInt(inp.value, 10) || 0);
        OD[key] = v;
        if (hint) hint.textContent = 'You have ' + balance + ' · ' + Math.max(0, balance - v) + ' left after';
        ofRecap(box);
      }
      inp.addEventListener('input', paint);
      inp.addEventListener('change', function () {
        var v = Math.max(0, Math.min(balance, parseInt(inp.value, 10) || 0));
        inp.value = v; paint();
      });
      inp.value = OD[key];
      paint();
    }
    ofMoney('#ofTokens', '#ofTokensHave', 'tokens', ctx.S.gameTokens || 0);
    ofMoney('#ofTickets', '#ofTicketsHave', 'tickets', ctx.S.spins || 0);

    // card picker
    var oSetSel = box.querySelector('#ofCardSet');
    oSetSel.innerHTML = OD.sets.map(function (s) {
      return '<option value="' + esc(s.id) + '">' + esc(s.name) + '</option>';
    }).join('');
    oSetSel.value = OD.set;
    oSetSel.addEventListener('change', function () {
      OD.set = oSetSel.value; lsSet('cps.composerSet.offer', OD.set); OD.q = '';
      box.querySelector('#ofCardSearch').value = '';
      ofRenderGrid(box);
    });
    var oSearch = box.querySelector('#ofCardSearch');
    oSearch.value = OD.q;
    oSearch.addEventListener('input', function (e) {
      OD.q = e.target.value; ofRenderGrid(box);
    });
    ofRenderGrid(box); ofRenderCards(box);
    box.querySelector('#ofGo').addEventListener('click', function () { ofSubmit(box, this); });
    oSearch.focus();
  }

  function ofGridRows() {
    // pickable rows: one per non-variant availability + one per owned serial
    var s = setObj(OD.set); if (!s) return [];
    var q = OD.q.trim().toLowerCase(), st = ctx.ps({ id: s.id }), rows = [];
    var vmap = {};
    myVariants().forEach(function (v) {
      if (v.set_id !== s.id) return;
      (vmap[v.card_id] = vmap[v.card_id] || []).push(v);
    });
    s.cards.forEach(function (c) {
      var e = st.cards[c.id];
      if (!e || e.n - (e.v || 0) <= 0) return;
      if (q) {
        var hay = ('#' + c.num + ' ' + c.num + ' ' + c.name + ' ' + (c.subtitle || '')).toLowerCase();
        if (hay.indexOf(q) < 0) return;
      }
      var vs = vmap[c.id] || [];
      var plainLeft = e.n - (e.v || 0) - vs.length;
      var usedPlain = OD.cards.filter(function (o) { return o.set === s.id && o.card === c.id && !o.tier; }).length;
      var holoLeft = holoOn(e) - OD.cards.filter(function (o) { return o.set === s.id && o.card === c.id && o.holo; }).length;
      if (plainLeft - usedPlain > 0) {
        rows.push({ set: s.id, card: c, kind: 'plain', left: plainLeft - usedPlain,
                    plainAdd: plainOn(e) - OD.cards.filter(function (o) { return o.set === s.id && o.card === c.id && !o.tier && !o.holo; }).length > 0,
                    holo: holoOn(e) > 0, holoLeft: Math.max(0, holoLeft), label: c.name, tier: null, serial: null });
      }
      vs.forEach(function (v) {
        var usedV = OD.cards.some(function (o) { return o.set === s.id && o.card === c.id && o.tier === v.tier && o.serial === v.serial; });
        if (!usedV) {
          rows.push({ set: s.id, card: c, kind: 'variant', left: 1,
                      holo: holoOn(e) > 0, holoLeft: Math.max(0, holoLeft), label: c.name + ' — ' + variantLabel(v.tier, v.serial),
                      tier: v.tier, serial: v.serial });
        }
      });
    });
    rows.sort(function (x, y) { return sortByRarity(x.card, y.card); });
    OD._rowTotal = rows.length;
    return rows.slice(0, 40);
  }

  function ofRenderGrid(box) {
    var grid = box.querySelector('#ofCardGrid');
    var rows = ofGridRows();
    var cl = box.querySelector('#ofCardCount');
    if (cl) cl.textContent = countLine(OD._rowTotal || rows.length, rows.length, !!OD.q.trim());
    grid.innerHTML = rows.map(function (r, i) {
      return '<div class="tp-pick" data-row="' + i + '">' +
        '<span class="tp-pick-name">' + esc(r.label) + (r.kind === 'plain' && r.holo ? ' ✦' : '') + '</span>' +
        '<span class="cmp-rowacts"><span class="muted small">#' + r.card.num + '</span> <span class="pill r-' + r.card.rarity + '">' + esc(r.card.rarity) + '</span>' +
        (r.kind === 'plain' ? ' <span class="muted small">×' + r.left + '</span>' : '') +
        (r.kind === 'variant' || r.plainAdd ? '<button type="button" class="btn small" data-add="' + i + '">Add</button>' : '') +
        (r.holoLeft > 0 ? '<button type="button" class="btn small" data-addholo="' + i + '">Add ✦</button>' : '') +
        '</span></div>';
    }).join('') || '<div class="muted small">No matches.</div>';
    grid.querySelectorAll('[data-add]').forEach(function (btn) {
      btn.addEventListener('click', function (ev) { ev.stopPropagation(); ofAdd(box, rows[+btn.getAttribute('data-add')], false); });
    });
    grid.querySelectorAll('[data-addholo]').forEach(function (btn) {
      btn.addEventListener('click', function (ev) { ev.stopPropagation(); ofAdd(box, rows[+btn.getAttribute('data-addholo')], true); });
    });
    grid.querySelectorAll('[data-row]').forEach(function (rowEl) {
      rowEl.addEventListener('click', function () { ofAdd(box, rows[+rowEl.getAttribute('data-row')], false); });
    });
  }

  function ofAdd(box, r, asHolo) {
    if (!r) return;
    if (OD.cards.length >= 5) { showErrors(box, 'ofErrors', ['At most 5 cards per offer.']); return; }
    if (!r.tier && !asHolo) {
      // Plain add: needs a plain copy on hand — (n - h) - (v - vh) —
      // mirroring pbOfferAdd (the client half of the 139 incident).
      var st2 = ctx.ps({ id: r.set }), e2 = st2.cards[r.card.id] || { n: 0, h: 0 };
      var plainUsed2 = OD.cards.filter(function (o) { return o.set === r.set && o.card === r.card.id && !o.tier && !o.holo; }).length;
      if (plainUsed2 >= plainOn(e2)) { showErrors(box, 'ofErrors', ['You don\'t have another plain copy on hand.']); return; }
    }
    if (asHolo && r.holoLeft <= 0) { showErrors(box, 'ofErrors', ['You don\'t have another holo copy on hand.']); return; }
    OD.cards.push({ set: r.set, card: r.card.id, holo: !!asHolo,
                    tier: r.tier, serial: r.serial, label: r.label });
    showErrors(box, 'ofErrors', null);
    ofRenderCards(box); ofRenderGrid(box);
  }

  function ofRenderCards(box) {
    var t = box.querySelector('#ofCards');
    t.innerHTML = OD.cards.map(function (o, i) {
      var s2 = setObj(o.set);
      var flipBtn = '';
      if (o.tier) {
        flipBtn = '<button class="chip-flip" data-flip="' + i + '" title="Flip between plain and holo">' + (o.holo ? 'make plain' : 'make ✦') + '</button>';
      } else {
        var e = (ctx.ps({ id: o.set }).cards[o.card]) || { n: 0, h: 0 };
        var pUsed = OD.cards.filter(function (x) { return x.set === o.set && x.card === o.card && !x.tier && !x.holo; }).length - (o.holo ? 0 : 1);
        var hUsed = OD.cards.filter(function (x) { return x.set === o.set && x.card === o.card && !x.tier && x.holo; }).length - (o.holo ? 1 : 0);
        var canFlip = o.holo ? (pUsed < plainOn(e)) : (hUsed < holoOn(e));
        if (canFlip) flipBtn = '<button class="chip-flip" data-flip="' + i + '" title="Flip between plain and holo">' + (o.holo ? 'make plain' : 'make ✦') + '</button>';
      }
      return '<span class="trade-chip"><b>' + esc(o.label) + '</b>' +
        (o.holo ? ' ✦' : '') +
        ' <span class="muted small">(' + esc(s2 ? s2.name : o.set) + ')</span>' +
        flipBtn +
        '<button class="chip-x" data-rm="' + i + '" title="Remove">×</button></span>';
    }).join('') || '<span class="muted small">No cards offered yet.</span>';
    t.querySelectorAll('[data-rm]').forEach(function (x) {
      x.addEventListener('click', function () {
        OD.cards.splice(+x.getAttribute('data-rm'), 1);
        ofRenderCards(box); ofRenderGrid(box);
      });
    });
    t.querySelectorAll('[data-flip]').forEach(function (x) {
      x.addEventListener('click', function () {
        var o = OD.cards[+x.getAttribute('data-flip')];
        if (o) o.holo = !o.holo;
        ofRenderCards(box); ofRenderGrid(box);
      });
    });
    ofRecap(box);
  }

  /* The Phase 1 submit, reading OD (kept in sync by the binders; the
     DOM is re-collected first so the params match exactly). */
  async function ofSubmit(box, btn) {
    OD.tokens = Math.max(0, parseInt(box.querySelector('#ofTokens').value, 10) || 0);
    OD.tickets = Math.max(0, parseInt(box.querySelector('#ofTickets').value, 10) || 0);
    OD.packSet = box.querySelector('#ofPackSet').value || '';
    OD.packs = Math.max(0, parseInt(box.querySelector('#ofPacks').value, 10) || 0);
    var msgs = [];
    if (OD.packSet && !OD.packs) msgs.push('Set the pack count for your pack offer.');
    var packs = OD.packSet ? OD.packs : 0;
    if (!OD.tokens && !OD.tickets && !packs && !OD.cards.length) {
      msgs.push('Your offer needs tokens, tickets, packs, or cards.');
    }
    if (msgs.length) { showErrors(box, 'ofErrors', msgs); return; }
    btn.disabled = true;
    try {
      await CPS.cloud.call('trade_offer', {
        p_listing: OD.listing.id,
        p_offer: { tokens: OD.tokens, tickets: OD.tickets, pack_set: OD.packSet || null, packs: packs,
                   cards: OD.cards.map(function (o) { return { set: o.set, card: o.card, holo: o.holo, tier: o.tier, serial: o.serial }; }) }
      });
    } catch (e) {
      btn.disabled = false;
      showErrors(box, 'ofErrors', [translateError(e)]);
      return;
    }
    var sess = OS; OS = null;
    ctx.toast('Offer submitted — escrowed until the listing closes.', 'good');
    ctx.audio.coin();
    if (sess && sess.fromCard) {
      await ctx.refreshCloud();
      returnToCard(sess);
    } else {
      HT.onOffered();
      await ctx.refreshCloud();
    }
  }

  async function ofCloseForm() {
    if (OS && OS.fromCard) {
      var dirty = snapOffer() !== OS.snapshot;
      if (!(await guardDiscard(OS, dirty))) { ofShowForm(); return; }
      var sess = OS; OS = null;
      returnToCard(sess);
    } else {
      ctx.closeModal();
    }
  }

  CPS.composer = {
    openBounty: openBounty,
    openListing: openListing,
    openOffer: openOffer,
    _util: {
      plainOn: plainOn, holoOn: holoOn, translateError: translateError,
      variantLabel: variantLabel, countLine: countLine
    }
  };
})(window.CPS);

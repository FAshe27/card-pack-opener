// js/tradecopies.js — direct-trade builder: the "Numbered copies"
// section (migration 154). Base-card tiles in the trade grid are
// plain-only now; each numbered copy gets its own tile here, on BOTH
// steps (your copies in step 1, the partner's in step 2), and picking
// one adds that exact copy to the trade as a pinned pick
// ({setId, cardId, holo:false, h:0, tier, serial}).
// app.js hooks: tbRenderGrid calls CPS.tradeCopies.render(TB, tbRenderGrid)
// after drawing; renderTradeBuilder's step 3 calls .hide().
(function (CPS) {
  'use strict';
  var cache = {};   // accountId -> Promise<rows>
  var myIdP = null;  // Promise<account id | null>
  var seq = 0;       // render generation — stale async renders drop out

  function ctx() { return CPS.appCtx; }
  function esc(s) { return ctx().esc(s); }
  function $(s) { return document.querySelector(s); }

  function myId() {
    if (!myIdP) {
      myIdP = CPS.cloud.call('list_players').then(function (ps) {
        var me = (ps || []).filter(function (p) { return p.is_me; })[0];
        return me ? me.id : null;
      }).catch(function () { return null; });
    }
    return myIdP;
  }
  function variantsOf(accountId) {
    if (!cache[accountId]) {
      cache[accountId] = CPS.cloud.call('list_player_variants', { p_account: accountId })
        .then(function (rows) { return rows || []; })
        .catch(function () { delete cache[accountId]; return []; });
    }
    return cache[accountId];
  }

  function ensureStyle() {
    if (document.getElementById('tcStyle')) return;
    var st = document.createElement('style');
    st.id = 'tcStyle';
    st.textContent =
      '#tradeNumWrap { margin-top: 14px; }' +
      '.tc-head { font-weight: 700; margin: 4px 0 8px; }' +
      '.tc-head .muted { font-weight: 400; }' +
      '.tc-pick { display: block; width: 100%; }' +
      '.tc-pick[disabled] { opacity: .55; cursor: default; }' +
      '.tc-cap { padding: 4px 2px 2px; font-size: 13px; line-height: 1.35; }' +
      '.tc-tag { display: inline-block; margin-left: 6px; padding: 0 6px; border-radius: 999px; background: #2c2c34; font-size: 11px; }';
    document.head.appendChild(st);
  }

  function wrapEl() {
    var w = $('#tradeNumWrap');
    if (w) return w;
    var grid = $('#tradeGrid');
    if (!grid || !grid.parentNode) return null;
    w = document.createElement('div');
    w.id = 'tradeNumWrap';
    w.className = 'hidden';
    grid.parentNode.insertBefore(w, grid.nextSibling);
    return w;
  }

  function hide() {
    seq++;
    var w = $('#tradeNumWrap');
    if (w) { w.innerHTML = ''; w.classList.add('hidden'); }
  }

  function matches(TB, v, set, card) {
    if (TB.setId && v.set_id !== TB.setId) return false;
    if (TB.rarity && card.rarity !== TB.rarity) return false;
    var q = (TB.q || '').trim().toLowerCase();
    if (q) {
      var U = ctx().U;
      var hay = '#' + U.pad(card.num, set.numWidth) + ' ' + card.num + ' ' + card.name + ' ' + (card.subtitle || '');
      if (hay.toLowerCase().indexOf(q) < 0) return false;
    }
    return true;
  }

  function toggle(TB, refresh, v) {
    var idx = TB.picks.findIndex(function (p) {
      return p.setId === v.set_id && p.cardId === v.card_id && p.tier === v.tier && p.serial === v.serial;
    });
    if (idx >= 0) TB.picks.splice(idx, 1);
    else {
      if (TB.picks.length >= 10) { ctx().toast('Up to 10 cards per side.'); return; }
      TB.picks.push({ setId: v.set_id, cardId: v.card_id, holo: false, h: 0, tier: v.tier, serial: v.serial });
    }
    refresh();
  }

  async function render(TB, refresh) {
    ensureStyle();
    var w = wrapEl();
    if (!w) return;
    var mySeq = ++seq;
    if (!TB || TB.step === 3) { w.innerHTML = ''; w.classList.add('hidden'); return; }
    var accountId = TB.step === 1 ? await myId() : TB.to;
    if (mySeq !== seq) return;
    if (!accountId) { w.innerHTML = ''; w.classList.add('hidden'); return; }
    if (!cache[accountId]) {
      w.innerHTML = '<div class="muted small">Loading numbered copies…</div>';
      w.classList.remove('hidden');
    }
    var rows = await variantsOf(accountId);
    if (mySeq !== seq) return;
    var items = [];
    rows.forEach(function (v) {
      var set = window.CardSets && window.CardSets.get(v.set_id);
      var card = set && set.byId.get(v.card_id);
      if (!set || !card) return;
      if (!matches(TB, v, set, card)) return;
      items.push({ v: v, set: set, card: card });
    });
    if (!items.length) { w.innerHTML = ''; w.classList.add('hidden'); return; }
    var head = TB.step === 1 ? 'Numbered copies — yours' : 'Numbered copies — ' + (TB.toName || 'theirs');
    var html = '<div class="tc-head">' + esc(head) +
      ' <span class="muted small">Pick a specific copy to trade exactly that one.</span></div><div class="coll-grid">';
    items.forEach(function (it, i) {
      var v = it.v;
      var sel = TB.picks.some(function (p) {
        return p.setId === v.set_id && p.cardId === v.card_id && p.tier === v.tier && p.serial === v.serial;
      });
      var off = v.vaulted || v.escrowed;
      html += '<button class="trade-pick tc-pick' + (sel ? ' selected' : '') + '" data-tc="' + i + '"' +
        (off ? ' disabled' : '') + '>' +
        CPS.cards.render(it.set, it.card, { variant: { tier: v.tier, serial: v.serial } }) +
        '<div class="tc-cap"><b>' + esc(CPS.cards.variantLabel(v.tier, v.serial)) + '</b> · ' + esc(it.card.name) +
        (TB.setId ? '' : ' <span class="muted">' + esc(it.set.name) + '</span>') +
        (v.vaulted ? '<span class="tc-tag">in Vault</span>' : '') +
        (v.escrowed ? '<span class="tc-tag">in escrow</span>' : '') +
        '</div></button>';
    });
    html += '</div>';
    w.innerHTML = html;
    w.classList.remove('hidden');
    w.querySelectorAll('[data-tc]').forEach(function (b) {
      b.addEventListener('click', function () {
        var it = items[+b.getAttribute('data-tc')];
        if (it) toggle(TB, refresh, it.v);
      });
    });
  }

  CPS.tradeCopies = { render: render, hide: hide };
})(window.CPS = window.CPS || {});

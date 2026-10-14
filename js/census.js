/* js/census.js — the card modal's variant census block (#vcensus).
   Moved out of app.js (at its push ceiling) for the clickable-census
   feature (migration 143). Renders the per-tier "N/run found" rows
   exactly as app.js's fillCensus did, plus: any tier with at least
   one minted copy is clickable and opens the owners list
   (cps_variant_owners), and a card carrying misprinted numbered
   copies — variants on a Common/Uncommon card, the pre-134 mistaken
   mints — gets the explainer line, itself clickable to the list of
   every misprinted copy's owner (cps_variant_misprints). */
(function (CPS) {
  'use strict';
  var ORDER = ['oneofone', 'obsidian', 'prism', 'rainbow'];

  async function ensureCensus(setId) {
    var C = CPS.appCtx, S = C.S;
    if (!C.isCloud()) return {};
    S.variantCensus = S.variantCensus || {};
    if (!S.variantCensus[setId]) {
      try { S.variantCensus[setId] = await CPS.cloud.call('variant_census', { p_set: setId }); }
      catch (e) { S.variantCensus[setId] = {}; }
    }
    return S.variantCensus[setId];
  }
  async function ensureMisprints(setId) {
    var C = CPS.appCtx, S = C.S;
    if (!C.isCloud()) return {};
    S.variantMisprints = S.variantMisprints || {};
    if (!S.variantMisprints[setId]) {
      try { S.variantMisprints[setId] = await CPS.cloud.call('variant_misprints', { p_set: setId }); }
      catch (e) { S.variantMisprints[setId] = {}; }
    }
    return S.variantMisprints[setId];
  }
  function myVariantSerials(setId, cardId) {
    var S = CPS.appCtx.S;
    return (S.myVariants || []).filter(function (v) { return v.set_id === setId && v.card_id === cardId; })
      .sort(function (a, b) { return a.serial - b.serial; });
  }

  async function fill(box, set, card, variant) {
    var C = CPS.appCtx, R = C.R, esc = C.esc;
    var el = box.querySelector('#vcensus');
    if (!el || !C.isCloud()) return;
    var got = await Promise.all([ensureCensus(set.id), ensureMisprints(set.id)]);
    if (!box.isConnected) return;
    var census = got[0], misprints = got[1];
    var c = census[card.id] || { rainbow: 0, prism: 0, obsidian: 0, oneofone: 0, oneofone_by: null };
    // Variants mint rare+ only, but a numbered copy can sit on any rarity
    // (set regrades, grants, trades). Show the census whenever this card was
    // opened as a numbered copy, the player owns one, any exist in the wild,
    // or the card is rare+ (the original zero-count display).
    if (R.INDEX[card.rarity] < 2 && !variant && !myVariantSerials(set.id, card.id).length &&
        !(c.rainbow || c.prism || c.obsidian || c.oneofone)) return;
    var mcount = misprints[card.id] || 0;
    // Misprint card (Franklin, 2026-10-14): no tier listing at all — the
    // explainer sentence IS the census, and it opens the misprint owners.
    if (mcount > 0) {
      el.innerHTML = '<div class="vc-row vc-link" data-owners="misprint"><span class="vc-misprint-note">Early in PackRipper history, this card mistakenly had ' +
        mcount + ' numbered card' + (mcount === 1 ? '' : 's') + ' minted.</span><span class="vc-go">›</span></div>';
      el.style.display = '';
      el.onclick = function (ev) {
        var row = ev.target.closest('[data-owners]');
        if (row && el.contains(row)) openOwners(set, card, 'misprint');
      };
      return;
    }
    var rows = ORDER.map(function (t) {
      var vt = CPS.cards.VARIANTS[t];
      if (t === 'oneofone') {
        return '<div class="vc-row"><span>One-of-one variant</span><span class="vc-n ' + (c.oneofone_by ? 'vc-done' : '') + '">' +
          (c.oneofone_by ? 'found by <b>' + esc(c.oneofone_by) + '</b>' : 'not found') + '</span></div>';
      }
      var n = c[t] || 0;
      if (n >= 1) {
        return '<div class="vc-row vc-link" data-owners="' + t + '"><span>' + vt.name + ' variants</span><span class="vc-n ' + (n >= vt.run ? 'vc-done' : '') + '">' +
          n + '/' + vt.run + ' found <span class="vc-go">›</span></span></div>';
      }
      return '<div class="vc-row"><span>' + vt.name + ' variants</span><span class="vc-n">' +
        n + '/' + vt.run + ' found</span></div>';
    }).join('');
    var mine = myVariantSerials(set.id, card.id);
    if (mine.length) {
      rows += '<div class="vc-row"><span>Your serials</span><span class="vc-mine">' +
        mine.map(function (v) { return CPS.cards.VARIANTS[v.tier].name + ' #' + v.serial; }).join(', ') + '</span></div>';
    }
    el.innerHTML = rows;
    el.style.display = '';
    el.onclick = function (ev) {
      var row = ev.target.closest('[data-owners]');
      if (row && el.contains(row)) openOwners(set, card, row.getAttribute('data-owners'));
    };
  }

  function openOwners(set, card, tier) {
    var C = CPS.appCtx, esc = C.esc;
    var V = CPS.cards.VARIANTS;
    var title = tier === 'misprint' ? 'Misprinted numbered copies'
      : V[tier].emoji + ' ' + V[tier].name + ' variants — who owns each one';
    var html = '<button class="modal-x" data-close aria-label="Close">×</button>' +
      '<h3 style="margin-top:0">' + esc(title) + '</h3>' +
      '<p class="muted" style="margin:2px 0 0">' + esc(card.name) + ' · ' + esc(set.name) + '</p>' +
      '<div class="owners-list" id="ownersList"><p class="muted">Loading…</p></div>' +
      '<div style="margin-top:14px"><button class="btn small" data-owners-back>← Back to card</button></div>';
    C.openModal(html, function (box) {
      var back = box.querySelector('[data-owners-back]');
      if (back) back.addEventListener('click', function () { C.openCardModal(set.id, card.id); });
      CPS.cloud.call('variant_owners', { p_set: set.id, p_card: card.id, p_tier: tier }).then(function (rows) {
        var list = box.querySelector('#ownersList');
        if (!list) return;
        if (!rows || !rows.length) { list.innerHTML = '<p class="muted">No minted copies yet.</p>'; return; }
        list.innerHTML = rows.map(function (r) {
          var serial = tier === 'misprint'
            ? (V[r.tier] ? V[r.tier].name : r.tier) + ' #' + r.serial
            : '#' + r.serial + '/' + (V[r.tier] ? V[r.tier].run : '');
          var tags = '';
          if (r.misprint && tier !== 'misprint') tags += ' <span class="owners-misprint">MISPRINT</span>';
          if (r.vaulted) tags += ' <span class="owners-tag">in Vault</span>';
          return '<div class="owners-row"><span class="owners-serial">' + esc(serial) + tags + '</span>' +
            '<span class="owners-name">' + esc(r.owner) + (r.mine ? ' <span class="owners-you">(you)</span>' : '') + '</span></div>';
        }).join('');
      }).catch(function (e) {
        var list = box.querySelector('#ownersList');
        if (list) list.innerHTML = '<p class="muted">Could not load the owners list.</p>';
        C.cloudError(e);
      });
    });
  }

  CPS.census = { fill: fill, openOwners: openOwners };
})(window.CPS = window.CPS || {});

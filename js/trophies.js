/* js/trophies.js — Trophy Case rendering (profile overhaul, migration 130).
   Consumes CPS.appCtx; registers CPS.trophies. The server returns raw facts
   (cps_get_trophies); tier tables, titles, and descriptions live here.

   Franklin's trophy art: drop square images in images/trophies/ and fill in
   ART below (key -> path). Until a key has art, that trophy renders as a
   placeholder medallion (emoji in a tier-colored ring). Set-completion
   trophies never need art: they reuse the set's own pack emblem in a gold
   ring. The case is display-only — there is nothing to edit or claim. */
(function (CPS) {
  'use strict';
  var ctx = CPS.appCtx;

  var ART = {
    turned_1000: '', turned_2500: '', turned_5000: '', turned_10000: '',
    packs_10: '', packs_100: '', packs_1000: '', packs_2500: '', packs_5000: '', packs_10000: '',
    oneofone: '', cotd: ''
  };

  /* Ring color per tier index within a line: stone, bronze, silver, gold,
     ice, prismatic. */
  var RINGS = ['#8a8f98', '#cd7f32', '#b8c0cc', '#ffb21e', '#7ee8fa', 'prism'];

  var LINES = {
    turned: {
      emoji: '♻️', tiers: [1000, 2500, 5000, 10000],
      title: function (t) { return ctx.U.fmt(t) + ' Cards Turned In'; },
      desc: function (total) { return ctx.U.fmt(total) + ' turned in'; }
    },
    packs: {
      emoji: '🎁', tiers: [10, 100, 1000, 2500, 5000, 10000],
      title: function (t) { return ctx.U.fmt(t) + ' Packs Opened'; },
      desc: function (total) { return ctx.U.fmt(total) + ' opened'; }
    }
  };

  function medal(emoji, ring, locked) {
    var prism = ring === 'prism';
    return '<div class="trophy-medal' + (prism ? ' prism' : '') + '"' +
      (prism ? '' : ' style="border-color:' + ring + '"') + '><span>' + emoji + '</span></div>';
  }

  function visual(artKey, emoji, ring, locked) {
    var art = ART[artKey];
    if (art) {
      var prism = ring === 'prism';
      return '<img class="trophy-img" src="' + ctx.esc(art) + '" alt=""' +
        (prism ? '' : ' style="border-color:' + ring + '"') + '>';
    }
    return medal(emoji, ring, locked);
  }

  function tile(o) {
    return '<div class="trophy' + (o.locked ? ' locked' : '') + '">' + o.img +
      '<div class="trophy-title">' + ctx.esc(o.title) + '</div>' +
      '<div class="trophy-desc">' + ctx.esc(o.desc) + '</div></div>';
  }

  function tierTiles(key, total) {
    var L = LINES[key], out = [], earned = 0, i;
    for (i = 0; i < L.tiers.length; i++) if (total >= L.tiers[i]) earned = L.tiers[i];
    function ringFor(t) { return RINGS[Math.min(L.tiers.indexOf(t), RINGS.length - 1)]; }
    if (earned) {
      out.push(tile({
        img: visual(key + '_' + earned, L.emoji, ringFor(earned)),
        title: L.title(earned), desc: L.desc(total)
      }));
    }
    var next = null;
    for (i = 0; i < L.tiers.length; i++) if (L.tiers[i] > earned) { next = L.tiers[i]; break; }
    if (next != null && total > 0) {
      out.push(tile({
        locked: true,
        img: visual(key + '_' + next, L.emoji, ringFor(next), true),
        title: L.title(next), desc: ctx.U.fmt(total) + ' / ' + ctx.U.fmt(next)
      }));
    }
    return out;
  }

  /* data = the cps_get_trophies payload. Returns the case's inner HTML. */
  function render(data) {
    if (!data) return '<div class="empty">Trophies unavailable right now.</div>';
    var tiles = [];
    (data.sets || []).forEach(function (s) {
      var set = window.CardSets.get(s.set_id);
      var emblem = (set && set.pack && set.pack.emblem) || '🏆';
      tiles.push(tile({
        img: medal(emblem, '#ffb21e'),
        title: s.set_name, desc: '100% turned in'
      }));
    });
    tiles = tiles.concat(tierTiles('turned', data.turned_total || 0));
    tiles = tiles.concat(tierTiles('packs', data.packs_opened || 0));
    if (data.oneofone) {
      tiles.push(tile({
        img: visual('oneofone', '💠', 'prism'),
        title: 'One-of-One Pull',
        desc: (data.oneofone.card_name || 'A 1-of-1') +
          (data.oneofone.set_name ? ' · ' + data.oneofone.set_name : '')
      }));
    }
    if ((data.cotd_days || 0) > 0) {
      tiles.push(tile({
        img: visual('cotd', '⭐', '#ffb21e'),
        title: 'Card of the Day',
        desc: 'Pulled Card of the Day on ' + ctx.U.fmt(data.cotd_days) +
          (data.cotd_days === 1 ? ' day' : ' days')
      }));
    }
    if (!tiles.length) {
      return '<div class="empty">No trophies yet — complete a set or hit a milestone to earn your first.</div>';
    }
    return '<div class="trophy-grid">' + tiles.join('') + '</div>';
  }

  CPS.trophies = { render: render };
})(window.CPS = window.CPS || {});

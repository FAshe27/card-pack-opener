/* Trophy Case (js/trophies.js) — v2: the WHOLE catalog is visible.
   Earned trophies are lit with their earn date underneath; unearned ones
   are greyed with progress. All facts come from cps_get_trophies
   (migration 130 + dates/progress from 132); titles, tiers, and layout
   live here. Tier lines show EVERY tier as its own tile. */
(function () {
  'use strict';

  /* Trophy art: when Franklin's images land in images/trophies/, put the
     path here per key — that tile swaps its placeholder medallion for the
     real art. Set trophies never need art (they use the set emblem). */
  var ART = {
    turned_1000: '', turned_2500: '', turned_5000: '', turned_10000: '',
    packs_10: '', packs_100: '', packs_1000: '', packs_2500: '', packs_5000: '', packs_10000: '',
    oneofone: '', cotd: ''
  };

  var TURNED_TIERS = [
    { n: 1000, ring: '#cd7f32' },   // bronze
    { n: 2500, ring: '#b8c0cc' },   // silver
    { n: 5000, ring: '#ffb21e' },   // gold
    { n: 10000, ring: 'prism' }     // prismatic
  ];
  var PACK_TIERS = [
    { n: 10, ring: '#8a8f98' },     // stone
    { n: 100, ring: '#cd7f32' },    // bronze
    { n: 1000, ring: '#b8c0cc' },   // silver
    { n: 2500, ring: '#ffb21e' },   // gold
    { n: 5000, ring: '#7ee8fa' },   // ice
    { n: 10000, ring: 'prism' }     // prismatic
  ];

  function U() { return (window.CPS && CPS.appCtx && CPS.appCtx.U) || null; }
  function esc(s) { var u = U(); return u ? u.esc(s) : String(s == null ? '' : s); }
  function fmt(n) { var u = U(); return u ? u.fmt(n) : String(n); }

  var MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  function fmtDate(iso) {
    if (!iso) return '';
    var s = String(iso);
    if (/^\d{4}-\d{2}-\d{2}$/.test(s)) {
      var m = s.split('-');
      return MONTHS[+m[1] - 1] + ' ' + (+m[2]) + ', ' + m[0];
    }
    var d = new Date(s);
    if (isNaN(d.getTime())) return '';
    return d.toLocaleDateString('en-US', { timeZone: 'America/Chicago', month: 'short', day: 'numeric', year: 'numeric' });
  }

  function medal(artKey, emoji, ring) {
    var art = ART[artKey];
    if (art) return '<div class="trophy-medal art"><img src="' + esc(art) + '" alt=""></div>';
    if (ring === 'prism') return '<div class="trophy-medal prism"><span>' + emoji + '</span></div>';
    return '<div class="trophy-medal" style="border-color:' + ring + '"><span>' + emoji + '</span></div>';
  }
  function emblemMedal(emblem) {
    return '<div class="trophy-medal emblem" style="border-color:#ffb21e"><span>' + esc(emblem || '🏆') + '</span></div>';
  }

  function tile(medalHtml, title, descHtml, dateIso, locked) {
    var date = !locked && dateIso ? fmtDate(dateIso) : '';
    return '<div class="trophy' + (locked ? ' locked' : '') + '">' + medalHtml +
      '<div class="trophy-title">' + esc(title) + '</div>' +
      '<div class="trophy-desc">' + descHtml + '</div>' +
      (date ? '<div class="trophy-date">Earned ' + esc(date) + '</div>' : '') + '</div>';
  }

  function tierTiles(tiers, dates, total, keyPrefix, emoji, earnedNoun, titleNoun) {
    var earned = 0;
    var html = tiers.map(function (t) {
      var isEarned = total >= t.n;
      if (isEarned) earned++;
      var desc = isEarned ? fmt(total) + ' ' + earnedNoun : fmt(total) + ' / ' + fmt(t.n);
      return tile(medal(keyPrefix + '_' + t.n, emoji, t.ring), fmt(t.n) + ' ' + titleNoun,
        desc, dates ? dates[String(t.n)] : null, !isEarned);
    }).join('');
    return { html: html, earned: earned };
  }

  function render(t) {
    t = t || {};
    var doneSets = {};   // set_id -> completion date (or null pre-132)
    (t.sets || []).forEach(function (s) { doneSets[s.set_id] = s.at || null; });
    var prog = {};       // set_id -> {turned, total}
    (t.progress || []).forEach(function (p) { prog[p.set_id] = p; });
    var hasProgress = !!t.progress;

    /* ---- set completions: every set on the site ---- */
    var setRows = [];
    if (window.CardSets && window.CardSets.all) {
      window.CardSets.all().forEach(function (set) {
        if (!set || set.id === 'jumbled') return;
        var p = prog[set.id];
        var total = p ? p.total : (set.total || (set.cards ? set.cards.length : 0));
        setRows.push({ id: set.id, name: set.name || set.id, emblem: set.emblem, turned: p ? p.turned : 0, total: total, done: set.id in doneSets, at: doneSets[set.id] });
      });
    }
    // Sets the server reports but the registry doesn't know (shouldn't
    // happen) still show as earned rather than vanishing.
    (t.sets || []).forEach(function (s) {
      if (!setRows.some(function (r) { return r.id === s.set_id; })) {
        setRows.push({ id: s.set_id, name: s.set_name || s.set_id, emblem: null, turned: s.turned, total: s.total, done: true, at: s.at || null });
      }
    });
    setRows.sort(function (a, b) {
      if (a.done !== b.done) return a.done ? -1 : 1;
      if (a.done && b.done) return String(b.at || '').localeCompare(String(a.at || ''));
      var pa = a.total ? a.turned / a.total : 0, pb = b.total ? b.turned / b.total : 0;
      if (pb !== pa) return pb - pa;
      return a.name.localeCompare(b.name);
    });
    var earnedSets = 0;
    var setsHtml = setRows.map(function (r) {
      if (r.done) {
        earnedSets++;
        return tile(emblemMedal(r.emblem), r.name, '100% turned in', r.at, false);
      }
      if (!hasProgress) return '';  // pre-132 server: unearned sets unknown
      var pct = r.total ? Math.floor(1000 * r.turned / r.total) / 10 : 0;
      var desc = fmt(r.turned) + ' / ' + fmt(r.total) + ' turned in · ' + pct + '%' +
        '<span class="trophy-bar"><i style="width:' + Math.min(100, pct) + '%"></i></span>';
      return tile(emblemMedal(r.emblem), r.name, desc, null, true);
    }).join('');

    /* ---- tiered lines ---- */
    var turned = tierTiles(TURNED_TIERS, t.turned_dates, t.turned_total || 0, 'turned', '♻️', 'turned in', 'Cards Turned In');
    var packs = tierTiles(PACK_TIERS, t.packs_dates, t.packs_opened || 0, 'packs', '🎁', 'opened', 'Packs Opened');

    /* ---- special ---- */
    var specialHtml = '', specialEarned = 0;
    if (t.oneofone) {
      specialEarned++;
      var oo = t.oneofone;
      var desc = 'You pulled ' + esc(oo.card_name || 'a one-of-one') + (oo.set_name ? ' · ' + esc(oo.set_name) : '') +
        (oo.serial ? ' · #' + esc(oo.serial) + '/1' : '');
      specialHtml += tile(medal('oneofone', '👑', 'prism'), 'One-of-One Pull', desc, oo.at, false);
    } else {
      specialHtml += tile(medal('oneofone', '👑', 'prism'), 'One-of-One Pull', 'Pull a One-of-One variant', null, true);
    }
    var cotdDays = t.cotd_days || 0;
    if (cotdDays > 0) {
      specialEarned++;
      specialHtml += tile(medal('cotd', '⭐', '#ffb21e'), 'Card of the Day',
        'Pulled Card of the Day on ' + fmt(cotdDays) + (cotdDays === 1 ? ' day' : ' days'), t.cotd_first, false);
    } else {
      specialHtml += tile(medal('cotd', '⭐', '#ffb21e'), 'Card of the Day', 'Pull the Card of the Day', null, true);
    }

    var totalTiles = setRows.length + TURNED_TIERS.length + PACK_TIERS.length + 2;
    var earnedTotal = earnedSets + turned.earned + packs.earned + specialEarned;

    return '<div class="trophy-count">' + earnedTotal + ' earned · ' + (totalTiles - earnedTotal) + ' to go</div>' +
      '<h4 class="trophy-sec">Set completions — 100% turned in</h4><div class="trophy-grid">' + setsHtml + '</div>' +
      '<h4 class="trophy-sec">Cards turned in</h4><div class="trophy-grid">' + turned.html + '</div>' +
      '<h4 class="trophy-sec">Packs opened</h4><div class="trophy-grid">' + packs.html + '</div>' +
      '<h4 class="trophy-sec">Special</h4><div class="trophy-grid">' + specialHtml + '</div>';
  }

  window.CPS = window.CPS || {};
  CPS.trophies = { render: render, TURNED_TIERS: TURNED_TIERS, PACK_TIERS: PACK_TIERS, ART: ART };
})();

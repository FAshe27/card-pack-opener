/* Card rendering: procedural placeholder art, card front/back, silhouettes. */
(function (CPS) {
  var U = CPS.util, R = window.CPSRarities, esc = U.esc;
  var uid = 0;

  function art(set, card) {
    var rng = U.seeded(U.hashStr(set.id + ':' + card.id));
    var h1 = Math.floor(rng() * 360), h2 = (h1 + 60 + Math.floor(rng() * 180)) % 360;
    var g = 'cg' + (++uid), s = '';
    var type = Math.floor(rng() * 5), n = 6 + Math.floor(rng() * 5);
    for (var i = 0; i < n; i++) {
      var x = (rng() * 100).toFixed(1), y = (rng() * 72).toFixed(1), r = (5 + rng() * 22).toFixed(1);
      var hue = ((rng() < 0.5 ? h1 : h2) + Math.floor(rng() * 40 - 20) + 360) % 360;
      var fill = 'hsla(' + hue + ',90%,' + (55 + Math.floor(rng() * 25)) + '%,' + (0.14 + rng() * 0.32).toFixed(2) + ')';
      var rot = Math.floor(rng() * 360);
      if (type === 0) s += '<circle cx="' + x + '" cy="' + y + '" r="' + r + '" fill="' + fill + '"/>';
      else if (type === 1) s += '<rect x="' + (x - r / 2) + '" y="' + (y - r / 2) + '" width="' + r + '" height="' + r + '" rx="3" fill="' + fill + '" transform="rotate(' + rot + ' ' + x + ' ' + y + ')"/>';
      else if (type === 2) s += '<polygon points="' + x + ',' + (y - r) + ' ' + (+x + +r) + ',' + (+y + r * 0.8) + ' ' + (x - r) + ',' + (+y + r * 0.8) + '" fill="' + fill + '" transform="rotate(' + rot + ' ' + x + ' ' + y + ')"/>';
      else if (type === 3) s += '<circle cx="' + x + '" cy="' + y + '" r="' + r + '" fill="none" stroke="' + fill + '" stroke-width="' + (2 + rng() * 5).toFixed(1) + '"/>';
      else s += '<rect x="-20" y="' + y + '" width="140" height="' + (3 + rng() * 9).toFixed(1) + '" fill="' + fill + '" transform="rotate(' + (rot % 60 - 30) + ' 50 36)"/>';
    }
    var ri = R.INDEX[card.rarity], extra = '';
    if (ri >= 4) { // sunburst for legendary / chase
      for (var k = 0; k < 16; k++) extra += '<polygon points="50,36 ' + (50 + 90 * Math.cos(k * Math.PI / 8)).toFixed(1) + ',' + (36 + 90 * Math.sin(k * Math.PI / 8)).toFixed(1) + ' ' + (50 + 90 * Math.cos(k * Math.PI / 8 + 0.12)).toFixed(1) + ',' + (36 + 90 * Math.sin(k * Math.PI / 8 + 0.12)).toFixed(1) + '" fill="rgba(255,255,255,.10)"/>';
    }
    if (ri >= 2) { // sparkles for rare+
      for (var m = 0; m < ri * 2; m++) {
        var sx = (rng() * 100).toFixed(1), sy = (rng() * 72).toFixed(1), sz = (1 + rng() * 2).toFixed(1);
        extra += '<path d="M' + sx + ' ' + (sy - sz * 2) + 'L' + (+sx + +sz * 0.5) + ' ' + (sy - sz * 0.5) + 'L' + (+sx + sz * 2) + ' ' + sy + 'L' + (+sx + +sz * 0.5) + ' ' + (+sy + sz * 0.5) + 'L' + sx + ' ' + (+sy + sz * 2) + 'L' + (sx - sz * 0.5) + ' ' + (+sy + sz * 0.5) + 'L' + (sx - sz * 2) + ' ' + sy + 'L' + (sx - sz * 0.5) + ' ' + (sy - sz * 0.5) + 'Z" fill="rgba(255,255,255,.85)"/>';
      }
    }
    var num = '#' + U.pad(card.num, set.numWidth);
    return '<svg class="art-svg" viewBox="0 0 100 72" preserveAspectRatio="xMidYMid slice" aria-hidden="true">' +
      '<defs><linearGradient id="' + g + '" x1="0" y1="0" x2="1" y2="1">' +
      '<stop offset="0" stop-color="hsl(' + h1 + ',70%,32%)"/><stop offset="1" stop-color="hsl(' + h2 + ',70%,18%)"/></linearGradient></defs>' +
      '<rect width="100" height="72" fill="url(#' + g + ')"/>' + extra + s +
      '<text x="50" y="44" text-anchor="middle" font-family="system-ui,-apple-system,Segoe UI,sans-serif" font-size="' + (num.length > 5 ? 20 : 25) + '" font-weight="900" fill="#fff" fill-opacity=".92" stroke="rgba(0,0,0,.25)" stroke-width=".6">' + num + '</text>' +
      '<text x="50" y="66" text-anchor="middle" font-family="system-ui,sans-serif" font-size="4.2" letter-spacing="1.2" fill="#fff" fill-opacity=".55">PLACEHOLDER ART</text>' +
      '</svg>';
  }

  function artOrImage(set, card) {
    if (card.image) return '<img src="' + esc(card.image) + '" alt="' + esc(card.name) + '" loading="lazy" draggable="false">';
    return art(set, card);
  }

  /* Details box: text, a brand logo, or both (small logo beside the text). */
  function detailsBox(card) {
    var text = String(card.details || '').trim();
    if (!card.logo) return '<div class="cf-details">' + esc(card.details) + '</div>';
    var img = '<img src="' + esc(card.logo) + '" alt="" loading="lazy" draggable="false">';
    if (!text) return '<div class="cf-details cf-logo-strip"><div class="cf-logo">' + img + '</div></div>';
    return '<div class="cf-details cf-with-logo"><span class="cf-logo cf-logo-sm">' + img + '</span>' + esc(card.details) + '</div>';
  }

  function front(set, card, holo) {
    var r = R.RARITIES[R.INDEX[card.rarity]];
    var layout = card.logo ? (String(card.details || '').trim() ? ' cf-has-logo' : ' cf-logo-only') : '';
    return '<div class="face front"><div class="cf' + layout + '">' +
      '<div class="cf-top"><span class="cf-name">' + esc(card.name) + '</span><span class="cf-gem" title="' + r.label + '"></span></div>' +
      '<div class="cf-art">' + artOrImage(set, card) + '</div>' +
      '<div class="cf-type"><span class="cf-sub">' + esc(card.subtitle) + '</span><span class="cf-rar">' + r.label + '</span></div>' +
      detailsBox(card) +
      '<div class="cf-foot"><span>' + esc(set.code) + '</span>' + (holo ? '<span class="foil">HOLO</span>' : '') +
      '<span>' + U.pad(card.num, set.numWidth) + '/' + U.pad(set.cards.length, set.numWidth) + '</span></div>' +
      '</div></div>';
  }

  function back(set) {
    return '<div class="face back"><div class="cb"><div class="cb-emblem"><span>' + esc(set.code) + '</span></div>' +
      '<div class="cb-name">' + esc(set.name) + '</div></div></div>';
  }

  function themeStyle(set) { return '--p1:' + set.theme.primary + ';--p2:' + set.theme.secondary + ';'; }

  /* opts: {holo, flippable, isNew, count, holoCount, cls} */
  function render(set, card, opts) {
    opts = opts || {};
    var cls = ['card', 'r-' + card.rarity];
    if (opts.holo) cls.push('holo');
    if (opts.flippable) cls.push('flippable');
    if (opts.cls) cls.push(opts.cls);
    var badges = '';
    if (opts.isNew) badges += '<span class="badge-new">NEW</span>';
    if (opts.count > 1) badges += '<span class="badge-count">×' + opts.count + '</span>';
    if (opts.holoCount > 0) badges += '<span class="badge-holo" title="' + opts.holoCount + ' holo">✦' + (opts.holoCount > 1 ? opts.holoCount : '') + '</span>';
    return '<div class="' + cls.join(' ') + '" data-set="' + esc(set.id) + '" data-card="' + esc(card.id) + '" style="' + themeStyle(set) + '">' +
      '<div class="card-inner">' + front(set, card, opts.holo) + (opts.flippable ? back(set) : '') + '</div>' + badges + '</div>';
  }

  function silhouette(set, card) {
    var r = R.RARITIES[R.INDEX[card.rarity]];
    return '<div class="card missing r-' + card.rarity + '" data-set="' + esc(set.id) + '" data-card="' + esc(card.id) + '" style="' + themeStyle(set) + '">' +
      '<div class="card-inner"><div class="face sil"><div class="sil-q">?</div>' +
      '<div class="sil-num">#' + U.pad(card.num, set.numWidth) + '</div><div class="sil-r">' + r.label + '</div></div></div></div>';
  }

  /* Pack wrapper art */
  function pack(set, extraCls) {
    return '<div class="pack ' + (extraCls || '') + '" style="' + themeStyle(set) + '">' +
      '<div class="pack-top"><div class="crimp"></div></div>' +
      '<div class="pack-body"><div class="pack-shine"></div>' +
      '<div class="pack-code">' + esc(set.code) + '</div>' +
      '<div class="pack-emblem">✦</div>' +
      '<div class="pack-name">' + esc(set.name) + '</div>' +
      '<div class="pack-sub">' + esc(set.pack.name) + ' · ' + set.pack.size + ' cards</div>' +
      '<div class="crimp bottom"></div></div></div>';
  }

  CPS.cards = { render: render, silhouette: silhouette, pack: pack, art: art, themeStyle: themeStyle };
})(window.CPS);

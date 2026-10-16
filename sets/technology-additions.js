/* Technology set image fixes — overrides applied after technology-collection.js.
   (technology-collection.js exceeds the push size limit, so fixes to existing
   cards live here. Must stay directly after 'technology-collection.js' in
   sets/manifest.js.) */
(function () {
  var S = window.CardSets && window.CardSets.get('technology-collection');
  if (!S) return;
  var fixes = {
    /* Deep-dive image-weight fix (2026-10-16): the Minolta SRT 201 photo
       was a 1.39 MB 4K JPEG shown at card size. Recompressed wrapper
       (same photo, 800px); original stays at assets/sets/misc/. */
    'minolta-srt-201': 'assets/sets/misc/minolta-srt-201-sm.svg'
  };
  Object.keys(fixes).forEach(function (id) {
    var c = S.byId.get(id);
    if (c) c.image = fixes[id];
  });
})();

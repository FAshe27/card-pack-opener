/* Formula 1 set fixes — image overrides applied after formula-1-collection.js.
   (formula-1-collection.js exceeds the push size limit, so fixes to existing
   cards live here instead of being edited into it. Must stay directly after
   'formula-1-collection.js' in sets/manifest.js.) */
(function () {
  var S = window.CardSets && window.CardSets.get('formula-1-collection');
  if (!S) return;
  var fixes = {
    /* #298 Flat Spot: was an http:// f1i.com link, which browsers block as
       mixed content on the https site, so the card showed no image.
       Franklin's photo of a flat-spotted tire lives in the repo instead. */
    'flat-spot': 'assets/sets/misc/flat-spot.jpg',
    /* 2026-10-15 referer audit: f1i.com 403s any request carrying the
       site's Referer (and two of these were http://, doubly blocked),
       so ERS, Blue Flags and Wheel Nut showed placeholder art. Their
       photos are repo-hosted now. Nose Cone pointed at a forum
       attachment behind a login wall; it now uses a Wikimedia photo
       of a Renault R30 nose cone + front wing in the pit lane. */
    'ers': 'assets/sets/f1/ers.svg',
    'blue-flags': 'assets/sets/f1/blue-flags.svg',
    'wheel-nut': 'assets/sets/f1/wheel-nut.svg',
    'nose-cone': 'https://thumb.wikimedia.org/wikipedia/commons/thumb/8/83/Renault_R30_front_wing_Canada_2010.jpg/1280px-Renault_R30_front_wing_Canada_2010.jpg'
  };
  Object.keys(fixes).forEach(function (id) {
    var c = S.byId.get(id);
    if (c) c.image = fixes[id];
  });
})();

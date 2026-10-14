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
    'flat-spot': 'assets/sets/misc/flat-spot.jpg'
  };
  Object.keys(fixes).forEach(function (id) {
    var c = S.byId.get(id);
    if (c) c.image = fixes[id];
  });
})();

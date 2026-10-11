/* MLB set additions — cards appended after mlb.js.
   (mlb.js exceeds the push size limit, so new cards live here instead of being
   edited into it. Must stay directly after 'mlb.js' in sets/manifest.js.) */
(function () {
  var S = window.CardSets && window.CardSets.get('mlb');
  if (!S) return;
  var extra = [
    {
      id: 'alan-trammell',
      name: 'Alan Trammell',
      rarity: 'epic',
      subtitle: 'Shortstop, Detroit Tigers · 1977–1996',
      details: '1984 World Series MVP; Hall of Fame shortstop who spent all 20 seasons in Detroit.',
      image: 'assets/sets/mlb/alan-trammell.svg',
      logo: ''
    }
  ];
  extra.forEach(function (x) {
    if (S.byId.has(x.id)) return;
    var c = {
      id: x.id,
      num: S.cards.length + 1,
      name: x.name,
      rarity: x.rarity,
      subtitle: x.subtitle,
      details: x.details,
      image: x.image,
      logo: x.logo || ''
    };
    S.cards.push(c);
    S.byId.set(c.id, c);
    if (S.pools[c.rarity]) S.pools[c.rarity].push(c);
  });
})();

/* Fast Food set additions — cards appended after fast-food.js.
   (Additions pattern: new cards append at the end of the set so existing
   card numbers never shift. Must stay directly after 'fast-food.js' in
   sets/manifest.js.) */
(function () {
  var S = window.CardSets && window.CardSets.get('fast-food');
  if (!S) return;
  var extra = [
    {id: "bk-bacon-king", name: "Bacon King", rarity: "rare", subtitle: "Burger King", image: "assets/sets/misc/IMG_6038.webp", logo: "assets/sets/fast-food/logos/burger-king.png"}
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

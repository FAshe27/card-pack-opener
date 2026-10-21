/* Card set: Jumbled Mess Exclusives (migration 169).
   Cards that can ONLY be pulled from Jumbled Mess packs — they live in
   no other set and no other pack can deal them. The set is registered
   under the existing 'jumbled' id so pulls (set_id 'jumbled'), the
   collection, turn-ins and the card modal all line up; the pack itself
   is still dealt by the server (cps_open_pack, p_set='jumbled') and
   the pack screen still uses CPS.jumbled's pseudo-set for its art.
   The pack block below mirrors how a Jumbled pack is actually dealt
   (4x Uncommon-or-better + 1x Rare-or-better) for size/display only. */
CardSets.register({"id":"jumbled","name":"Jumbled Mess","code":"JUMBLED","description":"Cards that live nowhere else — pullable only from Jumbled Mess packs, where every set collides.","theme":{"primary":"#a855f7","secondary":"#ec4899"},"pack":{"name":"Jumbled Mess","emblem":"🎲","skin":"jumbled","slots":[{"count":4,"label":"Uncommon or better","odds":{"uncommon":62,"rare":26,"epic":10,"legendary":2}},{"count":1,"label":"Rare or better (guaranteed)","odds":{"rare":80,"epic":14,"legendary":5,"chase":1}}],"holo":{"common":1,"uncommon":1.5,"rare":3,"epic":5,"legendary":7.5,"chase":12.5}},"cards":[{"name":"PackRipper","rarity":"chase","id":"packripper","subtitle":"Meta","details":"The game itself, hiding in its own messiest pack. A Jumbled Mess Chase found only where every set collides — one pack in a thousand.","image":"assets/sets/jumbled/images/packripper.webp"},{"name":"Irwin","rarity":"legendary","id":"irwin","subtitle":"Cat","details":"A goofy orange menace.","image":"assets/sets/jumbled/images/irwin.webp"},{"name":"Henry","rarity":"legendary","id":"henry","subtitle":"Cat","details":"A goofy shadowy menace.","image":"assets/sets/jumbled/images/henry.webp"},{"name":"This Elephant","rarity":"uncommon","id":"this-elephant","subtitle":"Elephant","details":"An elephant.","image":"assets/sets/jumbled/images/this-elephant.webp"}]});

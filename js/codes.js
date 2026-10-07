/* Prize pack codes (UMD: used by the app and by tools/make-codes.js).
   Format: PACK-<packs>-<NONCE>-<CHECK>   e.g. PACK-3-K7QZ2-9XH4M
   The CHECK is a hash of (secret, set id, pack count, nonce).

   !!! This is CLIENT-SIDE ONLY. Anyone who reads this file can mint codes.
   It's fine for friendly game nights; real prize codes need a server
   that issues codes and marks them redeemed. Change SECRET before sharing. */
(function (root, factory) {
  var api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.CPSCodes = api;
})(typeof self !== 'undefined' ? self : this, function () {
  var SECRET = 'change-me-before-sharing';
  var ALPH = '23456789ABCDEFGHJKMNPQRSTUVWXYZ'; // no 0/O/1/I/L confusion

  function hash(str) { // cyrb53
    var h1 = 0xdeadbeef, h2 = 0x41c6ce57;
    for (var i = 0; i < str.length; i++) {
      var ch = str.charCodeAt(i);
      h1 = Math.imul(h1 ^ ch, 2654435761);
      h2 = Math.imul(h2 ^ ch, 1597334677);
    }
    h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909);
    h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909);
    return 4294967296 * (2097151 & h2) + (h1 >>> 0);
  }
  function enc(num, len) {
    var s = '';
    for (var i = 0; i < len; i++) { s += ALPH[num % ALPH.length]; num = Math.floor(num / ALPH.length); }
    return s;
  }
  function check(setId, packs, nonce) { return enc(hash(SECRET + '|' + setId + '|' + packs + '|' + nonce), 5); }
  function randomNonce() {
    var s = '';
    for (var i = 0; i < 5; i++) s += ALPH[Math.floor(Math.random() * ALPH.length)];
    return s;
  }
  function make(setId, packs, nonce) {
    packs = Math.max(1, Math.min(99, packs | 0));
    nonce = nonce || randomNonce();
    return 'PACK-' + packs + '-' + nonce + '-' + check(setId, packs, nonce);
  }
  function parse(code) {
    var m = String(code || '').toUpperCase().replace(/\s+/g, '').match(/^PACK-(\d{1,2})-([A-Z0-9]{5})-([A-Z0-9]{5})$/);
    if (!m) return null;
    var packs = parseInt(m[1], 10);
    return { packs: packs, nonce: m[2], check: m[3], normalized: 'PACK-' + packs + '-' + m[2] + '-' + m[3] };
  }
  /* Returns {setId, packs, code} if the code is valid for one of setIds, else null. */
  function validate(code, setIds) {
    var p = parse(code);
    if (!p || p.packs < 1) return null;
    for (var i = 0; i < setIds.length; i++) {
      if (check(setIds[i], p.packs, p.nonce) === p.check) return { setId: setIds[i], packs: p.packs, code: p.normalized };
    }
    return null;
  }
  return { make: make, parse: parse, validate: validate, usingDefaultSecret: SECRET === 'change-me-before-sharing' };
});

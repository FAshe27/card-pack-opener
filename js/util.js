/* Small helpers shared across the app. */
window.CPS = window.CPS || {};
(function (CPS) {
  function hashStr(str, seed) {
    var h1 = 0xdeadbeef ^ (seed || 0), h2 = 0x41c6ce57 ^ (seed || 0);
    for (var i = 0; i < str.length; i++) {
      var ch = str.charCodeAt(i);
      h1 = Math.imul(h1 ^ ch, 2654435761); h2 = Math.imul(h2 ^ ch, 1597334677);
    }
    h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909);
    h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909);
    return 4294967296 * (2097151 & h2) + (h1 >>> 0);
  }
  CPS.util = {
    hashStr: hashStr,
    /* deterministic PRNG (mulberry32) for procedural art */
    seeded: function (seed) {
      var a = seed >>> 0;
      return function () {
        a |= 0; a = a + 0x6D2B79F5 | 0;
        var t = Math.imul(a ^ a >>> 15, 1 | a);
        t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
        return ((t ^ t >>> 14) >>> 0) / 4294967296;
      };
    },
    /* real randomness for pack pulls */
    rand: function () {
      var b = new Uint32Array(1); crypto.getRandomValues(b); return b[0] / 4294967296;
    },
    esc: function (s) {
      return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
        return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
      });
    },
    pad: function (n, w) { return String(n).padStart(w || 3, '0'); },
    $: function (sel, root) { return (root || document).querySelector(sel); },
    $$: function (sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); },
    h: function (html) { var t = document.createElement('template'); t.innerHTML = html.trim(); return t.content.firstElementChild; },
    sleep: function (ms) { return new Promise(function (r) { setTimeout(r, ms); }); },
    pct: function (p, digits) {
      if (p >= 0.9995) return '100%';
      if (p <= 0) return '0%';
      var v = p * 100;
      if (v < 0.1) return v.toFixed(3).replace(/0+$/, '') + '%';
      if (v < 1) return v.toFixed(2) + '%';
      return v.toFixed(digits == null ? 1 : digits) + '%';
    },
    oneIn: function (p) {
      if (p <= 0) return '—';
      var n = 1 / p;
      if (n < 1.05) return 'every pack';
      return '1 in ' + (n < 10 ? n.toFixed(1) : Math.round(n).toLocaleString());
    },
    download: function (filename, text, type) {
      var a = document.createElement('a');
      a.href = URL.createObjectURL(new Blob([text], { type: type || 'text/plain' }));
      a.download = filename; document.body.appendChild(a); a.click();
      setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 500);
    }
  };
})(window.CPS);

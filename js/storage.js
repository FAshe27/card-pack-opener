/* Storage module. Everything the app persists locally goes through
   CPS.Store. Accounts and game state live on the server (online-only);
   what remains here is UI preferences plus the legacy in-browser set
   importer tail (list/delete) so old imported sets can still be cleared. */
(function (CPS) {
  var NS = 'cps:v1:';
  var ls = {
    get: function (k, d) {
      try { var v = localStorage.getItem(NS + k); return v == null ? d : JSON.parse(v); } catch (e) { return d; }
    },
    set: function (k, v) {
      try { localStorage.setItem(NS + k, JSON.stringify(v)); } catch (e) { console.warn('Storage failed', e); }
    },
    del: function (k) { try { localStorage.removeItem(NS + k); } catch (e) {} }
  };
  CPS.Store = {
    kind: 'localStorage',

    /* ---- sets imported in the browser from CSV (legacy) ---- */
    listCustomSets: async function () { return ls.get('customSets', []); },
    deleteCustomSet: async function (id) {
      ls.set('customSets', ls.get('customSets', []).filter(function (s) { return s.id !== id; }));
    },

    /* ---- UI preferences (always local) ---- */
    getPref: function (k, d) { return ls.get('pref:' + k, d); },
    setPref: function (k, v) { ls.set('pref:' + k, v); }
  };
})(window.CPS);

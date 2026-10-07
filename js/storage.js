/* Storage module. Everything the app persists goes through CPS.Store.
   This version keeps data in localStorage (per browser). To add real accounts /
   trading later, replace this file with one that calls a server API but keeps the
   same async method names — the rest of the app doesn't need to change. */
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
  function newId() { return 'p_' + Date.now().toString(36) + Math.random().toString(36).slice(2, 7); }

  CPS.Store = {
    kind: 'localStorage',

    /* ---- players / profiles ---- */
    listPlayers: async function () { return ls.get('players', []); },
    loadPlayer: async function (id) { return ls.get('player:' + id, null); },
    savePlayer: async function (p) {
      ls.set('player:' + p.id, p);
      var list = ls.get('players', []);
      var i = list.findIndex(function (x) { return x.id === p.id; });
      var entry = { id: p.id, name: p.name };
      if (i < 0) list.push(entry); else list[i] = entry;
      ls.set('players', list);
    },
    createPlayer: async function (name) {
      var p = { id: newId(), name: name || 'Player', created: Date.now(), sets: {} };
      await this.savePlayer(p);
      return p;
    },
    deletePlayer: async function (id) {
      ls.del('player:' + id);
      ls.set('players', ls.get('players', []).filter(function (x) { return x.id !== id; }));
    },
    getActivePlayerId: function () { return ls.get('activePlayer', null); },
    setActivePlayerId: function (id) { ls.set('activePlayer', id); },

    /* ---- prize codes (a server should own this later) ---- */
    isCodeRedeemed: async function (code) { return !!ls.get('redeemed', {})[code]; },
    markCodeRedeemed: async function (code, playerId) {
      var r = ls.get('redeemed', {}); r[code] = { by: playerId, at: Date.now() }; ls.set('redeemed', r);
    },

    /* ---- sets imported in the browser from CSV ---- */
    listCustomSets: async function () { return ls.get('customSets', []); },
    saveCustomSet: async function (raw) {
      var list = ls.get('customSets', []).filter(function (s) { return s.id !== raw.id; });
      list.push(raw); ls.set('customSets', list);
    },
    deleteCustomSet: async function (id) {
      ls.set('customSets', ls.get('customSets', []).filter(function (s) { return s.id !== id; }));
    },

    /* ---- UI preferences (always local) ---- */
    getPref: function (k, d) { return ls.get('pref:' + k, d); },
    setPref: function (k, v) { ls.set('pref:' + k, v); }
  };
})(window.CPS);

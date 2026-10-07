/* Online accounts: a tiny client for the cps_* RPC functions in Supabase.
   No Supabase Auth / supabase-js needed: players log in with a username, the
   server returns a random session token, and every call sends that token. */
(function (CPS) {
  var cfg = window.CPS_CONFIG || {};
  var enabled = !!(cfg.onlineEnabled && cfg.supabaseUrl && cfg.supabaseKey && window.fetch);
  var KEY = 'cps:v1:token';

  function getToken() {
    try { return localStorage.getItem(KEY) || sessionStorage.getItem(KEY); } catch (e) { return null; }
  }
  function clearToken() {
    try { localStorage.removeItem(KEY); sessionStorage.removeItem(KEY); } catch (e) {}
  }
  function setToken(t, remember) {
    clearToken();
    try { (remember ? localStorage : sessionStorage).setItem(KEY, t); } catch (e) {}
  }

  async function rpc(fn, args) {
    if (!enabled) throw Object.assign(new Error('Online play is turned off.'), { kind: 'disabled' });
    var ctl = window.AbortController ? new AbortController() : null;
    var timer = ctl && setTimeout(function () { ctl.abort(); }, 20000);
    var res;
    try {
      res = await fetch(cfg.supabaseUrl.replace(/\/+$/, '') + '/rest/v1/rpc/' + fn, {
        method: 'POST',
        headers: { apikey: cfg.supabaseKey, 'Content-Type': 'application/json', Accept: 'application/json' },
        body: JSON.stringify(args || {}),
        signal: ctl ? ctl.signal : undefined
      });
    } catch (e) {
      throw Object.assign(new Error("Can't reach the server. Check your connection."), { kind: 'network' });
    } finally { if (timer) clearTimeout(timer); }
    var text = await res.text(), data = null;
    try { data = text ? JSON.parse(text) : null; } catch (e) { data = null; }
    if (!res.ok) {
      var code = data && data.code;
      var err = new Error((data && data.message) || ('Server error (' + res.status + ')'));
      err.status = res.status; err.code = code;
      err.kind = code === 'PGRST202' || res.status === 404 ? 'missing' : code === '28000' ? 'auth' : code === '42501' ? 'forbidden' : 'server';
      if (err.kind === 'missing') err.message = 'Online accounts are not set up on the server yet.';
      throw err;
    }
    return data;
  }

  /* Call a user RPC with the stored session token: call('open_pack', {p_set: 'x'}) */
  function call(name, args) {
    return rpc('cps_' + name, Object.assign({ p_token: getToken() }, args || {}));
  }

  async function login(username, remember) {
    var r = await rpc('cps_login', { p_username: username, p_user_agent: (navigator.userAgent || '').slice(0, 200) });
    if (r && r.ok) setToken(r.token, remember);
    return r;
  }
  async function logout() {
    var t = getToken();
    clearToken();
    if (t) { try { await rpc('cps_logout', { p_token: t }); } catch (e) { /* offline: token is gone locally anyway */ } }
  }

  CPS.cloud = { enabled: enabled, config: cfg, rpc: rpc, call: call, login: login, logout: logout,
                getToken: getToken, clearToken: clearToken, hasToken: function () { return !!getToken(); } };
})(window.CPS);

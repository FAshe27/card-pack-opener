/* Who's Online (migration 157): presence heartbeat + the admin box.
   While a player is logged in, a heartbeat RPC (cps_heartbeat) stamps
   their session's last_used_at every 60s (visible tab only). The
   admin panel box asks cps_admin_online_now who's been seen in the
   last 5 minutes. Everything fails silently: before 157 runs, the
   RPCs don't exist and both halves simply do nothing. */
(function (CPS) {
  'use strict';
  var started = false, timer = null, pollTimer = null, fetching = false;

  function ctx() { return CPS.appCtx || {}; }
  function cloudReady() {
    return !!(CPS.cloud && CPS.cloud.call && ctx().isCloud && ctx().isCloud());
  }

  function beat() {
    if (!cloudReady()) return;
    if (document.visibilityState && document.visibilityState !== 'visible') return;
    try {
      var p = CPS.cloud.call('heartbeat', {});
      if (p && p.catch) p.catch(function () { /* pre-157 / offline: fine */ });
    } catch (e) { /* never let presence break the page */ }
  }

  function start() {
    if (started) return;
    started = true;
    beat();
    timer = setInterval(beat, 60000);
    document.addEventListener('visibilitychange', function () {
      if (document.visibilityState === 'visible') beat();
    });
  }

  function ago(s) {
    if (s == null) return '';
    if (s < 45) return 'just now';
    var m = Math.round(s / 60);
    return m <= 1 ? '1m ago' : m + 'm ago';
  }

  function ensureBox() {
    var c = ctx(), $ = c.$;
    if (!$) return null;
    var body = $('#adminBody');
    if (!body) return null;
    var box = $('#onlineBox');
    if (!box) {
      box = document.createElement('div');
      box.className = 'panel wide';
      box.id = 'onlineBox';
      box.innerHTML = '<h2>🟢 Who&rsquo;s Online</h2><div class="small muted">Loading&hellip;</div>';
      body.insertBefore(box, body.firstChild);
    }
    return box;
  }

  function render(box, r) {
    var c = ctx(), esc = c.esc || function (x) { return String(x); };
    var list = (r && r.online) || [];
    var html = '<h2>🟢 Who&rsquo;s Online (' + list.length + ')</h2>';
    if (!list.length) {
      html += '<p class="small muted" style="margin:0">Nobody has been active in the last 5 minutes.</p>';
    } else {
      html += list.map(function (p) {
        var bits = ['<b>' + esc(p.name) + '</b>'];
        if (p.is_me) bits.push('<span class="muted small">(you)</span>');
        if (p.is_admin) bits.push('<span class="muted small">admin</span>');
        var meta = [ago(p.seconds_ago)];
        if (p.device) meta.push(esc(p.device));
        if (p.devices > 1) meta.push(p.devices + ' devices');
        return '<div class="row" style="justify-content:space-between;padding:3px 0">' +
          '<span>' + bits.join(' ') + '</span>' +
          '<span class="muted small">' + meta.filter(Boolean).join(' · ') + '</span></div>';
      }).join('');
    }
    box.innerHTML = html;
  }

  async function tick() {
    var c = ctx();
    if (!c.isAdmin || !c.isAdmin()) { stopPoll(); return; }
    if (!cloudReady()) return;
    var box = ensureBox();
    if (!box) { stopPoll(); return; }
    if (fetching) return;
    fetching = true;
    try {
      var r = await CPS.cloud.call('admin_online_now', {});
      if (r && box.isConnected) render(box, r);
    } catch (e) { /* pre-157: box keeps its Loading line, poll retries */ }
    fetching = false;
  }

  function stopPoll() {
    if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
  }

  function adminTick() {
    tick();
    if (!pollTimer) pollTimer = setInterval(tick, 30000);
  }

  CPS.online = { start: start, adminTick: adminTick };
})(window.CPS = window.CPS || {});

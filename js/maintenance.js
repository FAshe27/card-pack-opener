/* Maintenance mode (migration 187): a full-screen tune-up screen for
   players while big pushes/migrations happen, backed by server-side
   enforcement in cps.auth. This module is the UX layer:
     * It polls public.cps_site_status (publishable key, session NOT
       required) on load and every 60s (+ when the tab becomes
       visible again), with the current session token if there is one.
     * If maintenance is on and the visitor is NOT an admin, it shows
       the overlay. Admins never see it (the status RPC reports
       is_admin for their token, and cps.auth lets them through).
     * Polling continues under the overlay. When the flag turns off:
       if the app is entered, the overlay lifts and state refreshes
       in place; if the app never got in (booted during maintenance),
       the page reloads so boot runs cleanly. Either way the session
       token is NEVER cleared by this module — a blocked player is
       still logged in when maintenance ends.
     * Everything fails open: before 187 runs, or offline, the RPC
       errors and the site behaves exactly as it does today.
   The Admin-view panel (enable / message / ETA / Save) is injected
   into #adminBody by adminTick(), which app.js calls from
   renderAdminArea via one guarded hook line (see INTEGRATION.md).
   Follows the js/online.js module pattern (CPS.appCtx, lazy ctx). */
(function (CPS) {
  'use strict';

  var POLL_MS = 60000;
  var DEFAULT_MSG = "We're making some improvements. Back soon!";
  var HEADLINE = 'PackRipper is down for a quick tune-up';

  var state = { maintenance: false, message: '', eta: '', is_admin: false };
  var overlay = null, timer = null, checking = false;
  var dismissed = false;      // "Admin log in" was tapped while logged out
  var wasBlocked = false;     // the overlay has been shown at least once

  function ctx() { return CPS.appCtx || {}; }
  function token() {
    try { return (CPS.cloud && CPS.cloud.getToken) ? CPS.cloud.getToken() : null; }
    catch (e) { return null; }
  }
  function esc(s) {
    var c = ctx();
    return c.esc ? c.esc(s) : String(s == null ? '' : s);
  }

  async function check() {
    if (checking) return state;
    if (!CPS.cloud || !CPS.cloud.enabled || !CPS.cloud.rpc) return state;
    checking = true;
    try {
      var r = await CPS.cloud.rpc('cps_site_status', { p_token: token() });
      if (r) {
        state = {
          maintenance: !!r.maintenance,
          message: r.message || '',
          eta: r.eta || '',
          is_admin: !!r.is_admin
        };
      }
    } catch (e) { /* pre-187 / offline: fail open, keep current state */ }
    checking = false;
    render();
    return state;
  }

  function shouldShow() {
    if (!state.maintenance || state.is_admin) return false;
    if (dismissed && !token()) return false; // admin heading for the gate; stay out of the way while logged out
    return true;
  }

  function ensureOverlay() {
    if (overlay) return overlay;
    overlay = document.createElement('div');
    overlay.id = 'maintenanceOverlay';
    overlay.className = 'maint-overlay';
    overlay.setAttribute('role', 'alertdialog');
    overlay.setAttribute('aria-label', HEADLINE);
    overlay.innerHTML =
      '<div class="maint-box">' +
        '<div class="maint-badge">✦</div>' +
        '<h2 class="maint-title">' + esc(HEADLINE) + '</h2>' +
        '<p class="maint-msg"></p>' +
        '<p class="maint-eta"></p>' +
        '<p class="maint-note">You&rsquo;ll be back in automatically the moment we&rsquo;re done &mdash; no need to log in again.</p>' +
        '<button class="maint-admin-link" type="button">Admin log in</button>' +
      '</div>';
    overlay.querySelector('.maint-admin-link').addEventListener('click', function () {
      dismissed = true;
      hideOverlay();
    });
    document.body.appendChild(overlay);
    return overlay;
  }

  function showOverlay() {
    var el = ensureOverlay();
    el.querySelector('.maint-msg').textContent = state.message || DEFAULT_MSG;
    var eta = el.querySelector('.maint-eta');
    if (state.eta) { eta.textContent = state.eta; eta.style.display = ''; }
    else eta.style.display = 'none';
    el.style.display = '';
    wasBlocked = true;
  }

  function hideOverlay() {
    if (overlay) overlay.style.display = 'none';
  }

  function render() {
    if (token()) dismissed = false; // a session appeared: re-evaluate honestly
    if (shouldShow()) { showOverlay(); return; }
    var wasShown = overlay && overlay.style.display !== 'none';
    hideOverlay();
    if (!state.maintenance && wasBlocked && (wasShown || wasBlocked)) {
      // Maintenance just lifted (or an admin signed in): get the app
      // back without touching the session token.
      wasBlocked = false;
      var c = ctx();
      if (state.is_admin) return; // admin signed in under the overlay: gate flow owns the screen now
      if (c.isCloud && c.isCloud() && c.refreshCloud) {
        try { c.refreshCloud(); } catch (e) { /* state refresh is best-effort */ }
      } else if (c.isLocked && c.isLocked()) {
        // Booted during maintenance and never got in: reload so boot
        // (initAccount -> get_state -> gate) runs cleanly. The token
        // lives in storage and survives the reload untouched.
        try { location.reload(); } catch (e) { /* non-fatal */ }
      }
    }
  }

  /* ------------------------------------------------ admin panel */
  function ensurePanel() {
    var c = ctx(), $ = c.$;
    if (!$) return null;
    var body = $('#adminBody');
    if (!body) return null;
    var panel = $('#maintPanel');
    if (panel) return panel;
    panel = document.createElement('div');
    panel.className = 'panel wide';
    panel.id = 'maintPanel';
    panel.innerHTML =
      '<h2>🛠 Maintenance mode</h2>' +
      '<p class="small muted" id="maintStatus" style="margin-top:0">Loading&hellip;</p>' +
      '<label class="inline" style="display:flex;gap:8px;align-items:center;margin-bottom:10px">' +
        '<input type="checkbox" id="maintEnabled"> <b>Maintenance on</b> &mdash; players are blocked, admins are not</label>' +
      '<label class="field">Message players see ' +
        '<textarea id="maintMsg" rows="2" maxlength="500" placeholder="' + esc(DEFAULT_MSG) + '"></textarea></label>' +
      '<label class="field">Back-by line (optional) ' +
        '<input id="maintEta" type="text" maxlength="200" placeholder="Back around 9 PM"></label>' +
      '<div class="row"><button class="btn primary" id="maintSaveBtn" type="button">Save</button>' +
      '<span class="small muted">Takes effect within about a minute for players already online, instantly on their next action.</span></div>';
    var onlineBox = $('#onlineBox');
    if (onlineBox && onlineBox.parentNode === body) body.insertBefore(panel, onlineBox.nextSibling);
    else body.insertBefore(panel, body.firstChild);
    panel.querySelector('#maintSaveBtn').addEventListener('click', save);
    return panel;
  }

  function fillPanel(panel, force) {
    var c = ctx(), $ = c.$;
    if (!$) return;
    var statusEl = $('#maintStatus');
    if (statusEl) {
      statusEl.textContent = state.maintenance
        ? 'ON — players are seeing the tune-up screen right now.' + (state.eta ? ' ' + state.eta : '')
        : 'Off — the site is open to everyone.';
    }
    var active = document.activeElement;
    var editing = active && panel.contains(active) && (active.id === 'maintMsg' || active.id === 'maintEta');
    if (force || !editing) {
      var en = $('#maintEnabled'); if (en) en.checked = !!state.maintenance;
      var msg = $('#maintMsg'); if (msg && (force || !msg.dataset.touched)) msg.value = state.message || '';
      var eta = $('#maintEta'); if (eta && (force || !eta.dataset.touched)) eta.value = state.eta || '';
    }
  }

  async function save() {
    var c = ctx(), $ = c.$;
    if (!$) return;
    var btn = $('#maintSaveBtn');
    var enabled = !!($('#maintEnabled') && $('#maintEnabled').checked);
    var message = ($('#maintMsg') && $('#maintMsg').value) || '';
    var eta = ($('#maintEta') && $('#maintEta').value) || '';
    if (btn) btn.disabled = true;
    try {
      var r = await CPS.cloud.call('admin_set_maintenance', {
        p_enabled: enabled, p_message: message, p_eta: eta
      });
      if (r) {
        state = { maintenance: !!r.maintenance, message: r.message || '', eta: r.eta || '', is_admin: true };
      }
      if (c.toast) c.toast(enabled ? 'Maintenance mode is ON. Players are blocked.' : 'Maintenance mode is OFF. The site is open.', enabled ? 'warn' : 'good');
      var panel = $('#maintPanel');
      if (panel) { var m = $('#maintMsg'); if (m) m.dataset.touched = ''; var t = $('#maintEta'); if (t) t.dataset.touched = ''; fillPanel(panel, true); }
      render();
    } catch (e) {
      if (c.cloudError) c.cloudError(e);
    }
    if (btn) btn.disabled = false;
  }

  async function adminTick() {
    var c = ctx();
    if (!c.isAdmin || !c.isAdmin()) return;
    var panel = ensurePanel();
    if (!panel) return;
    var $ = c.$;
    ['maintMsg', 'maintEta'].forEach(function (id) {
      var el = $('#' + id);
      if (el && !el.dataset.watchBound) {
        el.dataset.watchBound = '1';
        el.addEventListener('input', function () { el.dataset.touched = '1'; });
      }
    });
    await check();
    fillPanel(panel, false);
  }

  /* ------------------------------------------------ boot */
  function start() {
    if (timer) return;
    check();
    timer = setInterval(check, POLL_MS);
    document.addEventListener('visibilitychange', function () {
      if (document.visibilityState === 'visible') check();
    });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();

  CPS.maintenance = { check: check, adminTick: adminTick, state: function () { return state; } };
})(window.CPS = window.CPS || {});

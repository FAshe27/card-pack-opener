/* Banner system (migration 209): a slim across-the-top announcement
   line Franklin writes, styles and toggles from the Admin panel —
   heads-ups in the run-up to a maintenance window, new-set launches,
   event news. Design mirrors js/maintenance.js:
     * It polls public.cps_site_status (publishable key, session NOT
       required) on load, every 60s, and when the tab becomes visible
       again. The banner rides the 'banner' key 209 adds to that RPC,
       so active players see a new/changed banner within about a
       minute, with no reload. (maintenance.js polls the same RPC for
       its own keys — the call is tiny and read-only.)
     * The bar is the FIRST element in <body>, in normal page flow
       at the very top — deliberately NOT sticky (Franklin,
       2026-10-27: no sticky headers); it scrolls away with the page
       and simply takes its space in the layout while shown, so
       nothing is ever covered. It is plain static colour/gradient
       — NO backdrop-filter, NO animation, NO background-attachment:
       fixed (the Firefox Android paint rule for always-on chrome).
     * A player can dismiss the bar (when Franklin leaves "players
       can dismiss" on): the dismissal is keyed to the banner VERSION
       in localStorage, and the server bumps the version on every
       admin save — so editing the text or re-toggling re-shows it
       to everyone, dismissers included. If Franklin sets a REDISPLAY
       interval (211), a dismissal only lasts that many minutes: the
       stored dismissal carries a timestamp, and once the interval
       has elapsed the regular 60s poll brings the bar back (and a
       fresh dismissal restarts the clock). Interval 0 = the
       dismissal lasts until the banner is edited or turned off.
     * Admins see the banner too (it is information, not a block) —
       which doubles as the admin panel's live preview.
     * AUDIENCE (216): Franklin can aim a banner at 'everyone' (the
       209/211 behaviour) or at 'unlinked' — only logged-in players
       who have not linked a Google account yet, for the Google-
       login migration campaign. An 'unlinked' banner renders ONLY
       when the state payload in CPS.appCtx.S names an account with
       oauth_linked === false: default-deny, so linked players
       never see it (not even a flash before state settles) and
       logged-out visitors don't either. A MutationObserver on
       <body> (the oauth.js watchGate precedent) re-evaluates the
       gate when app rendering settles, so the bar appears as an
       unlinked player lands, vanishes the moment they link
       (oauth.js flips the flag synchronously) or log out — the
       60s poll stays as backstop. Campaign tool: retire the
       'unlinked' choice once the Google migration completes.
     * Everything fails open: before 209 runs, or offline, the RPC
       errors / returns no banner key and the site behaves exactly
       as it does today.
   The Admin-view panel (enable / text / style / dismissible / Save)
   is injected into #adminBody by adminTick(), which app.js calls
   from renderAdminArea via one guarded hook line (see
   INTEGRATION.md). Follows the js/maintenance.js module pattern
   (CPS.appCtx, lazy ctx). */
(function (CPS) {
  'use strict';

  var POLL_MS = 60000;
  var LS_KEY = 'cpsBannerDismissedVersion'; // stores JSON {v: version, t: dismissed-at ms}
  var STYLES = {
    info:   { icon: '📣', label: 'Info' },
    warning:{ icon: '⚠️', label: 'Warning' },
    urgent: { icon: '🚨', label: 'Urgent' }
  };

  var state = { enabled: false, text: '', style: 'info', dismissible: true, version: 0, redisplay: 0, audience: 'everyone' };
  var bar = null, timer = null, checking = false, watching = false, lastGate = null;

  function ctx() { return CPS.appCtx || {}; }
  function token() {
    try { return (CPS.cloud && CPS.cloud.getToken) ? CPS.cloud.getToken() : null; }
    catch (e) { return null; }
  }
  function esc(s) {
    var c = ctx();
    return c.esc ? c.esc(s) : String(s == null ? '' : s);
  }

  /* Map one cps_site_status response onto the banner state. The
     maintenance module owns the 60s poll and pushes every response
     here, so the site-status RPC is fetched once a minute total,
     not once per module. */
  function applyStatus(r) {
    if (r && r.banner) {
      state = {
        enabled: !!r.banner.enabled,
        text: r.banner.text || '',
        style: STYLES[r.banner.style] ? r.banner.style : 'info',
        dismissible: r.banner.dismissible !== false,
        version: r.banner.version | 0,
        redisplay: Math.max(0, r.banner.redisplay_minutes | 0), // absent pre-211 => 0
        audience: r.banner.audience === 'unlinked' ? 'unlinked' : 'everyone' // absent pre-216 => everyone (fail-open)
      };
    }
    render();
  }

  async function check() {
    if (checking) return state;
    if (!CPS.cloud || !CPS.cloud.enabled || !CPS.cloud.rpc) return state;
    checking = true;
    try {
      var r = await CPS.cloud.rpc('cps_site_status', { p_token: token() });
      applyStatus(r);
    } catch (e) { /* pre-209 / offline: fail open, keep current state */ }
    checking = false;
    return state;
  }

  function dismissal() {
    try {
      var raw = window.localStorage.getItem(LS_KEY);
      if (!raw) return null;
      var d = JSON.parse(raw); // pre-211 stored a bare version string: unparseable => no dismissal
      return (d && typeof d.v === 'number' && typeof d.t === 'number') ? d : null;
    } catch (e) { return null; }
  }

  function dismissedNow() {
    var d = dismissal();
    if (!d || d.v !== state.version) return false;
    if (!state.redisplay) return true; // 0: lasts until the banner is edited or off
    return (Date.now() - d.t) < state.redisplay * 60000;
  }

  /* 216 gate: for an 'unlinked'-audience banner, true ONLY for a
     known unlinked player — a landed state payload naming an
     account whose oauth_linked is strictly false. Logged-out and
     not-yet-settled are the same value (S.account === null) and
     both deny, so a linked player can never flash the bar. */
  function accountGate() {
    var S = ctx().S;
    var acct = S && S.account;
    return !!(acct && acct.id && acct.oauth_linked === false);
  }

  function gateSignature() {
    var S = ctx().S;
    var acct = S && S.account;
    if (!acct || !acct.id) return 'out';
    return acct.id + '|' + (acct.oauth_linked === false ? 'unlinked' : acct.oauth_linked === true ? 'linked' : 'unknown');
  }

  function shouldShow() {
    if (!state.enabled || !state.text) return false;
    if (state.audience === 'unlinked' && !accountGate()) return false;
    if (state.dismissible && dismissedNow()) return false;
    return true;
  }

  function ensureBar() {
    if (bar) return bar;
    bar = document.createElement('div');
    bar.id = 'siteBanner';
    bar.className = 'banner-bar';
    bar.setAttribute('role', 'status');
    bar.innerHTML =
      '<span class="banner-ico" aria-hidden="true"></span>' +
      '<span class="banner-text"></span>' +
      '<button class="banner-x" type="button" aria-label="Dismiss announcement">&times;</button>';
    bar.querySelector('.banner-x').addEventListener('click', function () {
      try { window.localStorage.setItem(LS_KEY, JSON.stringify({ v: state.version, t: Date.now() })); } catch (e) { /* private mode: just hide for this page view */ }
      render(true);
    });
    document.body.insertBefore(bar, document.body.firstChild);
    return bar;
  }

  function render(forceHide) {
    if (!document.body) return;
    if (!forceHide && shouldShow()) {
      var el = ensureBar();
      el.className = 'banner-bar banner-' + state.style;
      el.querySelector('.banner-ico').textContent = STYLES[state.style].icon;
      el.querySelector('.banner-text').textContent = state.text;
      el.querySelector('.banner-x').style.display = state.dismissible ? '' : 'none';
      el.style.display = '';
      return;
    }
    if (bar) bar.style.display = 'none';
  }

  /* ------------------------------------------------ admin panel */
  function ensurePanel() {
    var c = ctx(), $ = c.$;
    if (!$) return null;
    var body = $('#adminBody');
    if (!body) return null;
    var panel = $('#bannerPanel');
    if (panel) return panel;
    panel = document.createElement('div');
    panel.className = 'panel wide';
    panel.id = 'bannerPanel';
    panel.innerHTML =
      '<h2>📣 Announcement banner</h2>' +
      '<p class="small muted" id="bannerStatus" style="margin-top:0">Loading&hellip;</p>' +
      '<label class="inline" style="display:flex;gap:8px;align-items:center;margin-bottom:10px">' +
        '<input type="checkbox" id="bannerEnabled"> <b>Banner on</b> &mdash; a line across the top of the page (the Audience choice below decides who sees it)</label>' +
      '<label class="field">Banner text ' +
        '<input id="bannerText" type="text" maxlength="200" placeholder="Heads up — PackRipper goes down for a tune-up tonight around 9 PM Central"></label>' +
      '<label class="field">Style ' +
        '<select id="bannerStyle">' +
          '<option value="info">📣 Info (violet → cyan)</option>' +
          '<option value="warning">⚠️ Warning (amber)</option>' +
          '<option value="urgent">🚨 Urgent (red)</option>' +
        '</select></label>' +
      '<label class="field">Audience ' +
        '<select id="bannerAudience">' +
          '<option value="everyone">Everyone — every visitor</option>' +
          '<option value="unlinked">Only players who haven&rsquo;t linked Google</option>' +
        '</select>' +
        '<span class="small muted" style="display:block;margin-top:4px">“Unlinked only” is the Google-migration campaign tool: the banner shows solely to logged-in players who haven&rsquo;t linked a Google account yet — linked players and logged-out visitors never see it. We can retire this choice once the migration is complete.</span></label>' +
      '<label class="inline" style="display:flex;gap:8px;align-items:center;margin-bottom:10px">' +
        '<input type="checkbox" id="bannerDismissible" checked> Players can dismiss it (editing or re-saving shows it to them again)</label>' +
      '<label class="field">Redisplay every ' +
        '<span style="display:inline-flex;gap:8px;align-items:center"><input id="bannerRedisplay" type="number" min="0" max="10080" step="1" style="width:110px"> minutes</span>' +
        '<span class="small muted" style="display:block;margin-top:4px">After a player dismisses the banner, it comes back once this many minutes pass (checked on the usual once-a-minute refresh). 0 or blank = stays dismissed until you edit or re-save.</span></label>' +
      '<div class="row"><button class="btn primary" id="bannerSaveBtn" type="button">Save</button>' +
      '<span class="small muted">Takes effect within about a minute for players already online, instantly on their next load. You see the banner yourself too — that&rsquo;s your preview.</span></div>';
    var maint = $('#maintPanel');
    if (maint && maint.parentNode === body && maint.nextSibling) body.insertBefore(panel, maint.nextSibling);
    else if (maint && maint.parentNode === body) body.appendChild(panel);
    else body.insertBefore(panel, body.firstChild);
    panel.querySelector('#bannerSaveBtn').addEventListener('click', save);
    return panel;
  }

  function fillPanel(panel, force) {
    var c = ctx(), $ = c.$;
    if (!$) return;
    var statusEl = $('#bannerStatus');
    if (statusEl) {
      statusEl.textContent = state.enabled && state.text
        ? (state.audience === 'unlinked'
            ? 'ON — showing ONLY to players who haven’t linked Google: “' + state.text + '”'
            : 'ON — players are seeing: “' + state.text + '”')
        : 'Off — no banner is showing.';
    }
    var active = document.activeElement;
    var editing = active && panel.contains(active) && (active.id === 'bannerText');
    if (force || !editing) {
      var en = $('#bannerEnabled'); if (en) en.checked = !!state.enabled;
      var tx = $('#bannerText'); if (tx && (force || !tx.dataset.touched)) tx.value = state.text || '';
      var st = $('#bannerStyle'); if (st) st.value = state.style || 'info';
      var au = $('#bannerAudience'); if (au) au.value = state.audience === 'unlinked' ? 'unlinked' : 'everyone'; // missing/pre-216 => Everyone
      var di = $('#bannerDismissible'); if (di) di.checked = state.dismissible !== false;
      var rd = $('#bannerRedisplay'); if (rd && (force || !rd.dataset.touched)) rd.value = state.redisplay ? String(state.redisplay) : '';
    }
  }

  async function save() {
    var c = ctx(), $ = c.$;
    if (!$) return;
    var btn = $('#bannerSaveBtn');
    var enabled = !!($('#bannerEnabled') && $('#bannerEnabled').checked);
    var text = (($('#bannerText') && $('#bannerText').value) || '').trim();
    var style = ($('#bannerStyle') && $('#bannerStyle').value) || 'info';
    var dismissible = !!($('#bannerDismissible') && $('#bannerDismissible').checked);
    var audience = ($('#bannerAudience') && $('#bannerAudience').value) === 'unlinked' ? 'unlinked' : 'everyone';
    var redisplay = parseInt(($('#bannerRedisplay') && $('#bannerRedisplay').value) || '0', 10);
    if (isNaN(redisplay) || redisplay < 0) redisplay = 0;
    if (redisplay > 10080) redisplay = 10080;
    if (enabled && !text) {
      if (c.toast) c.toast('Write the banner text first — an empty banner shows nothing.', 'warn');
      return;
    }
    if (btn) btn.disabled = true;
    try {
      var r = await CPS.cloud.call('admin_set_banner', {
        p_enabled: enabled, p_text: text, p_style: style, p_dismissible: dismissible,
        p_redisplay_minutes: redisplay, p_audience: audience
      });
      if (r) {
        state = {
          enabled: !!r.enabled,
          text: r.text || '',
          style: STYLES[r.style] ? r.style : 'info',
          dismissible: r.dismissible !== false,
          version: r.version | 0,
          redisplay: Math.max(0, r.redisplay_minutes | 0),
          audience: r.audience === 'unlinked' ? 'unlinked' : 'everyone'
        };
      }
      if (c.toast) c.toast(enabled ? 'Banner is ON. Players will see it within about a minute.' : 'Banner is OFF.', enabled ? 'good' : 'warn');
      var panel = $('#bannerPanel');
      if (panel) { var t = $('#bannerText'); if (t) t.dataset.touched = ''; var rEl = $('#bannerRedisplay'); if (rEl) rEl.dataset.touched = ''; fillPanel(panel, true); }
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
    var tx = $('#bannerText');
    if (tx && !tx.dataset.watchBound) {
      tx.dataset.watchBound = '1';
      tx.addEventListener('input', function () { tx.dataset.touched = '1'; });
    }
    var rd = $('#bannerRedisplay');
    if (rd && !rd.dataset.watchBound) {
      rd.dataset.watchBound = '1';
      rd.addEventListener('input', function () { rd.dataset.touched = '1'; });
    }
    await check();
    fillPanel(panel, false);
  }

  /* ------------------------------------------------ account watcher (216) */
  /* Re-evaluate the render gate when app rendering settles (the
     oauth.js watchGate precedent): login landing, a completed link
     and logout all change S.account and re-render the page, so the
     bar appears/vanishes with the session instead of waiting for
     the next 60s poll. The callback early-returns unless the gate
     inputs (account id + linked flag) actually changed — which
     also makes the bar's own insertion a one-pass no-op. */
  function watchAccount() {
    if (watching || !window.MutationObserver || !document.body) return;
    watching = true;
    lastGate = gateSignature();
    var mo = new MutationObserver(function () {
      var sig = gateSignature();
      if (sig === lastGate) return;
      lastGate = sig;
      render();
    });
    mo.observe(document.body, { childList: true, subtree: true });
  }

  /* ------------------------------------------------ boot */
  function start() {
    if (timer) return;
    watchAccount();
    if (CPS.maintenance && CPS.maintenance.check) {
      /* Ride the maintenance module's poll (it pushes each response
         into applyStatus). No second timer, no duplicate RPC. */
      CPS.maintenance.check();
      document.addEventListener('visibilitychange', function () {
        if (document.visibilityState === 'visible') CPS.maintenance.check();
      });
      timer = -1; // started, on the shared poll
      return;
    }
    /* Fallback if the maintenance module ever fails to load. */
    check();
    timer = setInterval(function () { if (!document.hidden) check(); }, POLL_MS);
    document.addEventListener('visibilitychange', function () {
      if (document.visibilityState === 'visible') check();
    });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();

  CPS.banner = { check: check, applyStatus: applyStatus, adminTick: adminTick, state: function () { return state; } };
})(window.CPS = window.CPS || {});

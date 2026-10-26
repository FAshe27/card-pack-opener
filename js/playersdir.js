/* js/playersdir.js — FarmRPG-style Players directory (migration 191).
   The Players tab no longer dumps the full player list. Instead:
     🟢 Players Online — who's been active in the last 5 minutes
        (presence from 157's heartbeat; list from cps_online_now)
     🔍 Search for Players — name search (substring, or Exact Match)
        over the list_players payload renderPlayers already fetches.
   Search results render as the SAME .player-card markup in #playerList,
   so app.js's existing delegated profile-open click keeps working.
   Consumes CPS.appCtx; registers CPS.playersDir. app.js carries only
   the render hook in renderPlayers (old full-list render = fallback). */
(function (CPS) {
  'use strict';
  var ctx = CPS.appCtx;
  var players = [];        // last list_players payload
  var onlineOpen = false, searchOpen = false;
  var onlineTimer = null, fetching = false;

  function $(s) { return document.querySelector(s); }

  function ago(s) {
    if (s == null) return '';
    if (s < 45) return 'just now';
    var m = Math.round(s / 60);
    return m <= 1 ? '1m ago' : m + 'm ago';
  }

  /* Identical markup to the old renderPlayers card (app.js fallback). */
  function cardHtml(p) {
    return '<button class="player-card" data-player="' + ctx.esc(p.id) + '">' +
      '<span class="avatar">' + ctx.esc((p.display_name[0] || 'P').toUpperCase()) + '</span>' +
      '<span class="player-meta"><span class="player-name-row"><b>' + ctx.esc(p.display_name) + '</b>' +
      (p.is_me ? '<span class="pill pill-you">You</span>' : '') + '</span>' +
      '<span class="muted small">' + p.favorites + ' in Vault · ' + p.unique_cards + ' unique cards</span></span>' +
      '<span class="player-go">›</span></button>';
  }

  /* Called from renderPlayers with the fresh list_players payload.
     Resets the results area to the hint instead of the huge list. */
  function render(list) {
    players = Array.isArray(list) ? list : [];
    var box = $('#playerList');
    if (box) box.innerHTML = '<div class="empty">Tap Players Online to see who’s around, or Search for Players to find someone.</div>';
    refreshOnline();
  }

  function onlineHtml(r) {
    var list = (r && r.online) || [];
    var head = '<div class="pdir-online-head">ONLINE NOW (' + list.length + ')</div>';
    if (!list.length) return head + '<p class="muted small" style="margin:0">Nobody has been active in the last 5 minutes.</p>';
    var names = list.map(function (p) {
      return '<button type="button" class="online-name" data-online-player="' + ctx.esc(p.id) + '" title="View ' + ctx.esc(p.name) + '’s profile">' +
        ctx.esc(p.name) + '</button>' +
        (p.is_me ? ' <span class="pill pill-you">You</span>' : '') +
        ' <span class="muted small">' + ago(p.seconds_ago) + '</span>';
    });
    return head + '<p class="online-flow">' + names.join(', ') + '</p>';
  }

  async function refreshOnline() {
    var btnCount = $('#playersOnlineCount');
    var panel = $('#playersOnlinePanel');
    if (!ctx.isCloud()) return;
    if (fetching) return;
    fetching = true;
    try {
      var r = await CPS.cloud.call('online_now', {});
      if (btnCount) btnCount.textContent = (r && r.count != null) ? ' (' + r.count + ')' : '';
      if (panel && onlineOpen) panel.innerHTML = onlineHtml(r);
    } catch (e) { /* pre-191 / offline: button just shows no count */ }
    fetching = false;
  }

  function toggleOnline() {
    onlineOpen = !onlineOpen;
    var panel = $('#playersOnlinePanel'), btn = $('#playersOnlineBtn');
    if (panel) {
      panel.classList.toggle('hidden', !onlineOpen);
      if (onlineOpen) panel.innerHTML = '<div class="muted small">Loading…</div>';
    }
    if (btn) btn.classList.toggle('active', onlineOpen);
    if (onlineOpen) {
      refreshOnline();
      if (!onlineTimer) onlineTimer = setInterval(function () { if (onlineOpen) refreshOnline(); }, 30000);
    }
  }

  function toggleSearch() {
    searchOpen = !searchOpen;
    var panel = $('#playersSearchPanel'), btn = $('#playersSearchBtn');
    if (panel) panel.classList.toggle('hidden', !searchOpen);
    if (btn) btn.classList.toggle('active', searchOpen);
    if (searchOpen) {
      var inp = $('#playerSearchInput');
      if (inp) inp.focus();
    }
  }

  function doSearch() {
    var inp = $('#playerSearchInput'), exact = $('#playerSearchExact');
    var box = $('#playerList');
    if (!box) return;
    var q = ((inp && inp.value) || '').trim().toLowerCase();
    if (!q) {
      box.innerHTML = '<div class="empty">Type a name above, then tap Search for Players.</div>';
      return;
    }
    var isExact = !!(exact && exact.checked);
    var hits = players.filter(function (p) {
      var n = (p.display_name || '').toLowerCase();
      return isExact ? n === q : n.indexOf(q) >= 0;
    });
    box.innerHTML = '<div class="pdir-results-head">SEARCH RESULTS</div>' +
      (hits.length
        ? hits.map(cardHtml).join('')
        : '<div class="empty">No players found for “' + ctx.esc(q) + '”.</div>');
  }

  function init() {
    var ob = $('#playersOnlineBtn'), sb = $('#playersSearchBtn'), go = $('#playerSearchGo');
    if (ob && !ob.dataset.wired) { ob.dataset.wired = '1'; ob.addEventListener('click', toggleOnline); }
    if (sb && !sb.dataset.wired) { sb.dataset.wired = '1'; sb.addEventListener('click', toggleSearch); }
    if (go && !go.dataset.wired) { go.dataset.wired = '1'; go.addEventListener('click', doSearch); }
    var inp = $('#playerSearchInput');
    if (inp && !inp.dataset.wired) {
      inp.dataset.wired = '1';
      inp.addEventListener('keydown', function (e) { if (e.key === 'Enter') { e.preventDefault(); doSearch(); } });
    }
    var panel = $('#playersOnlinePanel');
    if (panel && !panel.dataset.wired) {
      panel.dataset.wired = '1';
      panel.addEventListener('click', function (e) {
        var b = e.target.closest('[data-online-player]');
        if (b && CPS.profile) CPS.profile.openProfile(b.dataset.onlinePlayer);
      });
    }
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();

  CPS.playersDir = { render: render, refreshOnline: refreshOnline, doSearch: doSearch,
                     toggleOnline: toggleOnline, toggleSearch: toggleSearch };
})(window.CPS = window.CPS || {});

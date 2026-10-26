/* js/friends.js — lightweight Friends list (migration 190).
   One-way stars, private to the player who adds them: NO mutual
   consent, NO notification to the other player (Franklin, 2026-10-25).
   The list renders inside the top-right account dropdown (#acctMenu)
   as a quick jump to a friend's profile, gift, or trade.
   Consumes CPS.appCtx; registers CPS.friends. Split module so app.js
   carries only the one-line renderMenu hook in toggleAccountMenu. */
(function (CPS) {
  'use strict';
  var ctx = CPS.appCtx;
  var cache = null;      // null = not loaded yet; otherwise [{id, display_name}]
  var cacheFor = null;   // account id the cache belongs to
  var loading = null;    // in-flight list_friends promise (single-flight)

  function myId() { return ctx.S && ctx.S.account ? ctx.S.account.id : null; }

  function ensureLoaded(force) {
    if (!ctx.isCloud()) return Promise.resolve([]);
    var me = myId();
    if (!force && cache && cacheFor === me) return Promise.resolve(cache);
    if (loading) return loading;
    loading = CPS.cloud.call('list_friends', {}).then(function (rows) {
      cache = Array.isArray(rows) ? rows : [];
      cacheFor = me;
      loading = null;
      return cache;
    }, function (e) { loading = null; throw e; });
    return loading;
  }

  function isFriend(id) {
    return !!(cache && cacheFor === myId() && cache.some(function (f) { return f.id === id; }));
  }

  async function isFriendAsync(id) {
    await ensureLoaded(false);
    return isFriend(id);
  }

  /* Toggle a star server-side, then patch the local cache so the
     dropdown and any open profile button update without a refetch. */
  async function toggle(id, name) {
    var r = await CPS.cloud.call('toggle_friend', { p_friend: id });
    await ensureLoaded(false).catch(function () { cache = null; });
    if (cache) {
      cache = cache.filter(function (f) { return f.id !== id; });
      if (r && r.friended) {
        cache.push({ id: id, display_name: name || 'Player' });
        cache.sort(function (a, b) { return a.display_name.localeCompare(b.display_name); });
      }
    }
    renderMenu();
    return !!(r && r.friended);
  }

  function closeMenu() {
    var m = document.querySelector('#acctMenu');
    if (m) m.classList.add('hidden');
  }

  function rowHtml(f) {
    var id = ctx.esc(f.id), name = ctx.esc(f.display_name);
    return '<div class="friend-row">' +
      '<button type="button" class="friend-main" data-friend-open="' + id + '" title="View ' + name + '’s profile">' +
        '<span class="avatar">' + ctx.esc((f.display_name[0] || 'P').toUpperCase()) + '</span>' +
        '<span class="friend-name">' + name + '</span></button>' +
      '<button type="button" class="friend-act" data-friend-gift="' + id + '" data-name="' + name + '" title="Gift ' + name + '">🎁</button>' +
      '<button type="button" class="friend-act" data-friend-trade="' + id + '" title="Propose a trade with ' + name + '">🔁</button>' +
      '<button type="button" class="friend-act friend-x" data-friend-remove="' + id + '" data-name="' + name + '" title="Remove ' + name + ' from friends">×</button>' +
      '</div>';
  }

  /* Called from app.js toggleAccountMenu (one-line hook) every time
     the account dropdown opens. Renders synchronously from cache when
     warm; otherwise shows a loading line and re-renders on arrival. */
  function renderMenu() {
    var box = document.querySelector('#acctFriends');
    if (!box) return;
    if (!ctx.isCloud()) { box.innerHTML = ''; box.classList.add('hidden'); return; }
    box.classList.remove('hidden');
    var head = '<div class="friends-head">⭐ Friends' +
      (cache ? ' <span class="muted small">' + cache.length + '</span>' : '') + '</div>';
    var foot = '<button type="button" class="acct-menu-item friends-browse" id="friendsBrowseBtn">Browse players ›</button>';
    if (!cache || cacheFor !== myId()) {
      box.innerHTML = head + '<div class="muted small friends-note">Loading…</div>' + foot;
      wireBrowse(box);
      ensureLoaded(false).then(function () { renderMenu(); }, function () {
        var b2 = document.querySelector('#acctFriends');
        if (b2) { b2.innerHTML = head + '<div class="muted small friends-note">Couldn’t load your friends.</div>' + foot; wireBrowse(b2); }
      });
      return;
    }
    box.innerHTML = head +
      (cache.length
        ? '<div class="friends-list">' + cache.map(rowHtml).join('') + '</div>'
        : '<div class="muted small friends-note">No friends yet — open a player’s profile and tap ☆ Add friend.</div>') +
      foot;
    wireBrowse(box);
  }

  function wireBrowse(box) {
    var b = box.querySelector('#friendsBrowseBtn');
    if (b) b.addEventListener('click', function () { closeMenu(); ctx.showView('players'); });
  }

  /* Delegated clicks: the container lives in index.html for the whole
     session, rows are re-rendered — one listener at init covers all. */
  function init() {
    var box = document.querySelector('#acctFriends');
    if (!box || box.dataset.wired) return;
    box.dataset.wired = '1';
    box.addEventListener('click', async function (e) {
      var open = e.target.closest('[data-friend-open]');
      var gift = e.target.closest('[data-friend-gift]');
      var trade = e.target.closest('[data-friend-trade]');
      var remove = e.target.closest('[data-friend-remove]');
      if (open) {
        closeMenu();
        if (CPS.profile) CPS.profile.openProfile(open.dataset.friendOpen);
      } else if (gift) {
        closeMenu();
        if (CPS.giftBundle) CPS.giftBundle.open(gift.dataset.friendGift, gift.dataset.name);
      } else if (trade) {
        closeMenu();
        ctx.openTradeBuilder(trade.dataset.friendTrade);
      } else if (remove) {
        try {
          await toggle(remove.dataset.friendRemove, remove.dataset.name);
          ctx.toast('Removed ' + remove.dataset.name + ' from your friends.', '', 2200);
        } catch (err) { ctx.cloudError(err); }
      }
    });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();

  CPS.friends = { renderMenu: renderMenu, ensureLoaded: ensureLoaded,
                  isFriend: isFriend, isFriendAsync: isFriendAsync, toggle: toggle };
})(window.CPS = window.CPS || {});

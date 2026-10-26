/* js/friends.js — lightweight Friends list (migration 190).
   One-way stars, private to the player who adds them: NO mutual
   consent, NO notification to the other player (Franklin, 2026-10-25).
   The list renders inside the top-right account dropdown (#acctMenu)
   as a quick jump to a friend's profile, gift, or trade.
   Consumes CPS.appCtx; registers CPS.friends. Split module so app.js
   carries only the one-line renderMenu hook in toggleAccountMenu.

   192 (2026-10-25): the dropdown section is COLLAPSIBLE and closed by
   default (Franklin: the always-open list made the menu huge) — the
   header is a toggle, the list only renders when expanded, and the
   section re-collapses every time the account menu is reopened. The
   30-friend cap itself is enforced server-side by cps_toggle_friend
   (migration 192); FRIENDS_CAP here only drives the "list full" note. */
(function (CPS) {
  'use strict';
  var ctx = CPS.appCtx;
  var cache = null;      // null = not loaded yet; otherwise [{id, display_name}]
  var cacheFor = null;   // account id the cache belongs to
  var loading = null;    // in-flight list_friends promise (single-flight)
  var FRIENDS_CAP = 30;  // mirrors migration 192's server-side cap
  var expanded = false;  // dropdown section starts CLOSED (192)

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

  function headHtml() {
    return '<button type="button" class="friends-head-btn" data-friends-toggle aria-expanded="' + (expanded ? 'true' : 'false') + '">⭐ Friends' +
      (cache && cacheFor === myId() ? ' <span class="muted small">' + cache.length + '</span>' : '') +
      '<span class="friends-chev">' + (expanded ? '▾' : '▸') + '</span></button>';
  }

  /* Called from app.js toggleAccountMenu (one-line hook) every time
     the account dropdown opens. Collapsed by default (192): renders
     just the header row; the list appears only after the player taps
     it open, and opening the menu again re-collapses it (see the
     MutationObserver in init). Renders synchronously from cache when
     warm; a cold cache still loads in the background so the count on
     the header is live when it arrives. */
  function renderMenu() {
    var box = document.querySelector('#acctFriends');
    if (!box) return;
    if (!ctx.isCloud()) { box.innerHTML = ''; box.classList.add('hidden'); return; }
    box.classList.remove('hidden');
    var foot = '<button type="button" class="acct-menu-item friends-browse" id="friendsBrowseBtn">Browse players ›</button>';
    if (!expanded) {
      box.innerHTML = headHtml();
      if (!cache || cacheFor !== myId()) ensureLoaded(false).then(function () { renderMenu(); }, function () {});
      return;
    }
    if (!cache || cacheFor !== myId()) {
      box.innerHTML = headHtml() + '<div class="muted small friends-note">Loading…</div>' + foot;
      wireBrowse(box);
      ensureLoaded(false).then(function () { renderMenu(); }, function () {
        var b2 = document.querySelector('#acctFriends');
        if (b2 && expanded) { b2.innerHTML = headHtml() + '<div class="muted small friends-note">Couldn’t load your friends.</div>' + foot; wireBrowse(b2); }
      });
      return;
    }
    box.innerHTML = headHtml() +
      (cache.length
        ? '<div class="friends-list">' + cache.map(rowHtml).join('') + '</div>' +
          (cache.length >= FRIENDS_CAP ? '<div class="muted small friends-note">Friends list full (30) — remove someone to add another.</div>' : '')
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
    /* Re-collapse every time the account menu is reopened (192):
       watch #acctMenu's hidden class; on a hidden -> visible
       transition, reset to closed and re-render. */
    var menu = document.querySelector('#acctMenu');
    if (menu && window.MutationObserver) {
      var wasHidden = menu.classList.contains('hidden');
      new MutationObserver(function () {
        var h = menu.classList.contains('hidden');
        if (wasHidden && !h && expanded) { expanded = false; renderMenu(); }
        wasHidden = h;
      }).observe(menu, { attributes: true, attributeFilter: ['class'] });
    }
    box.addEventListener('click', async function (e) {
      var tog = e.target.closest('[data-friends-toggle]');
      if (tog) { expanded = !expanded; renderMenu(); return; }
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

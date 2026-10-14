/* js/notifsettings.js — Notification Settings (migration 129).
   A settings screen linked from the Notifications box ("⚙ Settings" /
   "⚙ Notification Settings", wired by a two-line hook in app.js's
   openNotifications). Five toggles, all ON by default:
     Chase pulls · Rainbow pulls (#/50) · Prism pulls (#/10) ·
     Obsidian pulls (#/5) · 1-of-1 pulls
   Preferences live on the account server-side (cps.accounts.notif_prefs),
   so they follow the player across devices. cps_list_notifications
   filters the big-pull announcements (kinds chase_pull / variant_pull,
   variant tier read from the notification's meta) against the prefs —
   the rows are still created, just never listed or counted while off,
   so turning a toggle back on reveals anything from the last 30 days.
   Every other kind (trades, gifts, rewards, admin messages…) is NOT
   toggleable and always comes through.
   Failure is soft: if 129 isn't run yet, opening the screen surfaces
   the standard "server isn't ready" error and nothing breaks. */
(function (CPS) {
  'use strict';

  var KINDS = [
    { key: 'chase',    icon: '🎯', label: 'Chase card pulls',   sub: 'When someone pulls a Chase card' },
    { key: 'rainbow',  icon: '🌈', label: 'Rainbow card pulls', sub: 'Numbered Rainbow cards (# of 50)' },
    { key: 'prism',    icon: '💎', label: 'Prism card pulls',   sub: 'Numbered Prism cards (# of 10)' },
    { key: 'obsidian', icon: '⚫', label: 'Obsidian card pulls', sub: 'Numbered Obsidian cards (# of 5)' },
    { key: 'oneofone', icon: '👑', label: '1-of-1 card pulls',  sub: 'When someone pulls a one-of-one' }
  ];

  function backToNotifications() {
    var b = document.getElementById('notifBtn');
    if (b) b.click(); /* the bell re-opens the list, freshly filtered */
  }

  async function open() {
    var ctx = CPS.appCtx;
    if (!ctx) return;
    if (!ctx.isCloud()) { ctx.toast('Notification settings need an online account.', 'warn'); return; }
    ctx.openModal('<div class="muted" style="padding:24px">Loading…</div>');
    var prefs;
    try { prefs = await CPS.cloud.call('get_notif_prefs'); }
    catch (e) { ctx.closeModal(true); ctx.cloudError(e); return; }
    render(ctx, prefs || {});
  }

  function render(ctx, prefs) {
    var rows = KINDS.map(function (k) {
      return '<label class="toggle" style="justify-content:space-between;width:100%">' +
        '<span><span style="font-size:1.2rem;margin-right:8px">' + k.icon + '</span>' +
        '<b>' + k.label + '</b><br>' +
        '<span class="muted small" style="margin-left:33px">' + k.sub + '</span></span>' +
        '<input type="checkbox" data-npref="' + k.key + '"' + (prefs[k.key] !== false ? ' checked' : '') + '></label>';
    }).join('');
    ctx.openModal('<button class="modal-x" data-close aria-label="Close">×</button><div class="profile">' +
      '<h2>Notification Settings</h2>' +
      '<p class="muted">Choose which big-pull announcements land in your bell. ' +
      'Trades, gifts, rewards and everything else always come through.</p>' +
      '<div style="margin:14px 0">' + rows + '</div>' +
      '<div class="notif-actions">' +
      '<button class="btn small" id="nprefAllOn">All on</button>' +
      '<button class="btn small" id="nprefAllOff">All off</button>' +
      '<button class="btn small primary" id="nprefBack" style="margin-left:auto">← Notifications</button>' +
      '</div>' +
      '<p class="muted small" style="margin-top:10px">Turning one off also hides ones already in your list ' +
      'from the last 30 days — turn it back on and they reappear.</p>' +
      '</div>', function (box) {
        box.querySelectorAll('[data-npref]').forEach(function (input) {
          input.addEventListener('change', async function () {
            var key = input.dataset.npref;
            prefs[key] = input.checked;
            try {
              prefs = (await CPS.cloud.call('set_notif_prefs', { p_prefs: prefs })) || prefs;
              ctx.toast('Saved.', 'good', 1500);
            } catch (e) {
              input.checked = !input.checked;
              prefs[key] = input.checked;
              ctx.cloudError(e);
            }
          });
        });
        function setAll(val) {
          return async function () {
            KINDS.forEach(function (k) { prefs[k.key] = val; });
            try {
              prefs = (await CPS.cloud.call('set_notif_prefs', { p_prefs: prefs })) || prefs;
              render(ctx, prefs);
            } catch (e) { ctx.cloudError(e); }
          };
        }
        box.querySelector('#nprefAllOn').addEventListener('click', setAll(true));
        box.querySelector('#nprefAllOff').addEventListener('click', setAll(false));
        box.querySelector('#nprefBack').addEventListener('click', function () {
          ctx.closeModal();
          backToNotifications();
        });
      });
  }

  /* Tier-aware bell icon for variant_pull notifications (companion to
     migration 140, which fixed the announcement text the same way).
     app.js routes the bell icon through here; returning null makes it
     fall back to the per-kind default. Tier comes from the row's meta;
     rows old enough to lack meta are classified by their text, the same
     word patterns cps.notif_visible uses server-side. Emojis are the
     card-face tier emojis (CPS.cards.VARIANTS), so the icon matches the
     emoji leading the announcement text. */
  CPS.notifIcon = function (it) {
    if (!it || it.kind !== 'variant_pull') return null;
    var tier = (it.meta && it.meta.tier) || null;
    if (!tier && it.text) {
      if (it.text.indexOf(' pulled Prism #') >= 0) tier = 'prism';
      else if (it.text.indexOf(' pulled Obsidian #') >= 0) tier = 'obsidian';
      else if (it.text.indexOf(' pulled a one-of-one ') >= 0 || it.text.indexOf(' pulled the One-of-One ') >= 0) tier = 'oneofone';
      else if (it.text.indexOf(' pulled Rainbow #') >= 0) tier = 'rainbow';
    }
    var v = tier && CPS.cards && CPS.cards.VARIANTS && CPS.cards.VARIANTS[tier];
    return v ? v.emoji : null;
  };

  CPS.notifSettings = { open: open };
})(window.CPS);

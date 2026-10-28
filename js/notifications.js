/* Notifications panel. Moved out of js/app.js (2026-10-16, boot diet)
   to free app.js push headroom; behavior is unchanged, including the
   pinned-announcements ordering. Registers as CPS.notifPanel. */
(function (CPS) {
  var ctx = CPS.appCtx;
  var esc = ctx.esc;

var NOTIF_KIND_ICON = { gift_card: '🎁', gift: '🎁', gift_thanks: '🙏', gift_pack: '📦', gift_spin: '🎟️',
  trade_offer: '⇄', trade_accepted: '✅', trade_declined: '❌', variant_pull: '🌈', chase_pull: '🎯', support: '🎫' };

function notifTime(iso) {
  var ms = Date.now() - new Date(iso).getTime();
  if (ms < 0) ms = 0;
  var m = Math.floor(ms / 60000);
  if (m < 1) return 'just now';
  if (m < 60) return m + 'm ago';
  var hh = Math.floor(m / 60);
  if (hh < 24) return hh + 'h ago';
  var d = Math.floor(hh / 24);
  if (d < 7) return d + 'd ago';
  try { return new Date(iso).toLocaleDateString(undefined, { month: 'short', day: 'numeric' }); }
  catch (e) { return ''; }
}

async function openNotifications() {
  ctx.openModal('<div class="muted" style="padding:24px">Loading…</div>');
  try {
    var n = await CPS.cloud.call('list_notifications');
    var items = n.items || [];
    var isAnn = function (it) { return !it.read && (it.kind === 'admin' || it.kind === 'turnin_rewards'); };
    var pins = items.filter(isAnn);
    if (pins.length) items = pins.concat(items.filter(function (it) { return !isAnn(it); }));
    ctx.openModal('<button class="modal-x" data-close aria-label="Close">×</button><div class="profile">' +
      '<h2>Notifications</h2>' +
      (pins.length ? '<p class="muted small" style="margin:2px 0 0">📌 Announcements stay pinned to the top until you read them.</p>' : '') +
      (items.length ? '<div class="notif-list">' + items.map(function (it) {
        return '<button class="notif' + (it.read ? '' : ' unread') + (isAnn(it) ? ' pinned' : '') + '" data-notif="' + it.id + '"' +
          (it.view ? ' data-view="' + ctx.esc(it.view) + '"' : '') +
          (it.meta && it.meta.ticket_id ? ' data-ticket="' + ctx.esc(it.meta.ticket_id) + '"' : '') +
          (it.meta && it.meta.set_id ? ' data-nset="' + ctx.esc(it.meta.set_id) + '" data-ncard="' + ctx.esc(it.meta.card_id) + '"' +
            ' data-nholo="' + (it.meta.holo ? '1' : '0') + '"' +
            (it.meta.tier ? ' data-ntier="' + ctx.esc(it.meta.tier) + '" data-nserial="' + it.meta.serial + '"' : '') : '') + '>' +
          '<span class="notif-icon">' + ((CPS.notifIcon && CPS.notifIcon(it)) || NOTIF_KIND_ICON[it.kind] || '🔔') + '</span>' +
          '<span class="notif-text">' + ctx.esc(it.text) +
          '<span class="notif-time">' + notifTime(it.created_at) + '</span></span></button>';
      }).join('') + '</div><div class="notif-actions"><button class="btn small" id="notifReadAll">Mark all read</button>' +
      (items.some(function (it) { return it.read; }) ? '<button class="btn small" id="notifClearRead">Clear read</button>' : '') + '<button class="btn small" id="notifSettingsBtn">⚙ Settings</button></div>'
      : '<div class="empty">No notifications yet.</div><div class="notif-actions"><button class="btn small" id="notifSettingsBtn">⚙ Notification Settings</button></div>') +
      '</div>', function (box) {
        box.querySelectorAll('.notif').forEach(function (el) {
          el.addEventListener('click', async function () {
            var id = el.dataset.notif, view = el.dataset.view;
            try { await CPS.cloud.call('read_notifications', { p_ids: [id] }); } catch (e) {}
            el.classList.remove('unread');
            ctx.refreshNotifBadge(true); // forced: the shared 10s cache still holds the pre-read list
            if (el.dataset.nset) {
              var vt = el.dataset.ntier;
              ctx.closeModal();
              ctx.openCardModal(el.dataset.nset, el.dataset.ncard, el.dataset.nholo === '1',
                vt ? { tier: vt, serial: parseInt(el.dataset.nserial, 10) } : null);
            } else if (el.dataset.ticket && CPS.help) {
              ctx.closeModal();
              ctx.showView('help');
              CPS.help.openTicket(el.dataset.ticket);
            } else if (view) { ctx.closeModal(); ctx.showView(view); }
          });
        });
        var ra = box.querySelector('#notifReadAll');
        if (ra) ra.addEventListener('click', async function () {
          try { await CPS.cloud.call('read_notifications', {}); } catch (e) { ctx.cloudError(e); return; }
          await ctx.refreshNotifBadge(true); // forced fresh, so the badge (and the cache the panel re-reads) match the server
          openNotifications();
        });
        var cr = box.querySelector('#notifClearRead');
        if (cr) cr.addEventListener('click', async function () {
          try { await CPS.cloud.call('clear_notifications', {}); } catch (e) { ctx.cloudError(e); return; }
          await ctx.refreshNotifBadge(true); // Clear never refreshed the badge at all — the count survived until a page reload
          openNotifications();
        });
        var sb = box.querySelector('#notifSettingsBtn');
        if (sb) sb.addEventListener('click', function () { if (CPS.notifSettings) CPS.notifSettings.open(); });
      });
  } catch (e) { ctx.closeModal(true); ctx.cloudError(e); }
}

  CPS.notifPanel = { open: openNotifications };
})(window.CPS);

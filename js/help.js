/* js/help.js — Help & Support tickets (migration 212).
   A super basic ticket system (Franklin, 2026-10-27):
     * Any logged-in player can submit a ticket (subject + message)
       and see EVERY ticket they themselves have submitted — and
       nobody else's. The server enforces that: cps_list_my_tickets
       only ever returns the caller's rows, and cps_get_ticket /
       cps_reply_ticket raise 42501 for anyone who isn't the owner
       or an admin.
     * Admins additionally see EVERYONE's tickets in the same view
       (cps_admin_list_tickets, admin-only server-side), can reply,
       and can close / reopen.
     * Both lists split the same way Franklin asked for: OPEN
       tickets in a menu that starts expanded, CLOSED tickets in a
       menu that starts collapsed, so the view isn't cluttered.
     * Replies are a simple thread on the ticket. A closed ticket is
       read-only until an admin reopens it. Admins get a 🔔 when a
       ticket is submitted or a player replies; the player gets one
       when an admin replies or closes/reopens (server-side, via the
       existing notifications system, kind 'support').
   Player-facing name is "Help & Support", not "Tickets": in
   PackRipper 🎟️ ticket already means the spin ticket.
   All logic lives here; app.js carries only the view whitelist, one
   renderView branch and the account-dropdown handler (see
   INTEGRATION.md). Consumes CPS.appCtx; registers CPS.help. */
(function (CPS) {
  'use strict';
  var ctx = CPS.appCtx;

  var mine = { open: [], closed: [] };
  var adminLists = null;          // null = not loaded / not an admin
  var openTicket = null;          // {ticket, mine, messages} while a thread is shown
  var expanded = {              // collapsible groups: open starts OPEN, closed starts CLOSED
    myOpen: true, myClosed: false,
    admOpen: true, admClosed: false
  };
  var loadedFor = null;           // account id the lists were loaded for

  function $(s) { return ctx.$(s); }
  function esc(s) { return ctx.esc(s); }
  function isAdmin() { return !!(ctx.S && ctx.S.account && ctx.S.account.is_admin); }
  function myId() { return ctx.S && ctx.S.account ? ctx.S.account.id : null; }
  function fmtDate(iso) {
    if (!iso) return '';
    var d = new Date(iso);
    return isNaN(d.getTime()) ? '' : d.toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
  }
  function fail(e) {
    if (ctx.cloudError) ctx.cloudError(e);
    else if (ctx.toast) ctx.toast((e && e.message) || 'Something went wrong.', 'error');
  }

  /* ---------------------------------------------------------- loading */
  async function load(force) {
    if (!ctx.isCloud() || !myId()) { mine = { open: [], closed: [] }; adminLists = null; return; }
    if (!force && loadedFor === myId()) return;
    mine = await CPS.cloud.call('list_my_tickets', {});
    adminLists = isAdmin() ? await CPS.cloud.call('admin_list_tickets', {}) : null;
    loadedFor = myId();
  }

  /* ------------------------------------------------------------ rows */
  function ticketRow(t, showOwner) {
    return '<button type="button" class="help-ticket-row" data-ticket="' + esc(t.id) + '">' +
      '<span class="help-ticket-main">' +
        '<span class="help-ticket-subject">' + esc(t.subject) + '</span>' +
        '<span class="help-ticket-meta">' +
          (showOwner ? esc(t.owner_name || 'Player') + ' · ' : '') +
          (t.message_count | 0) + ' message' + ((t.message_count | 0) === 1 ? '' : 's') +
          ' · last activity ' + esc(fmtDate(t.last_at || t.updated_at)) +
        '</span>' +
        (t.last_body ? '<span class="help-ticket-preview">' + esc(t.last_body) + '</span>' : '') +
      '</span>' +
      '<span class="help-pill help-pill-' + esc(t.status) + '">' + (t.status === 'open' ? 'Open' : 'Closed') + '</span>' +
    '</button>';
  }

  function group(key, title, tickets, showOwner) {
    var isOpen = !!expanded[key];
    var rows = tickets.length
      ? tickets.map(function (t) { return ticketRow(t, showOwner); }).join('')
      : '<p class="muted small help-empty">None.</p>';
    return '<div class="help-group">' +
      '<button type="button" class="help-group-head" data-group="' + esc(key) + '" aria-expanded="' + isOpen + '">' +
        '<span>' + (isOpen ? '▾' : '▸') + ' ' + esc(title) + ' (' + tickets.length + ')</span>' +
      '</button>' +
      (isOpen ? '<div class="help-group-body">' + rows + '</div>' : '') +
    '</div>';
  }

  /* ---------------------------------------------------------- render */
  function render() {
    var host = $('#helpBody');
    if (!host) return;
    if (!ctx.isCloud() || !myId()) {
      host.innerHTML = '<p class="muted">Log in to submit a help ticket.</p>';
      return;
    }
    if (openTicket) { renderThread(host); return; }
    var h = '';
    h += '<form id="helpNewForm" class="help-new">' +
      '<label>Subject <input id="helpSubject" maxlength="120" placeholder="e.g. A pack I opened gave me the wrong cards"></label>' +
      '<label>What do you need help with? <textarea id="helpBodyText" rows="4" maxlength="2000" placeholder="Tell us what happened — the more detail, the faster we can sort it out."></textarea></label>' +
      '<button class="btn primary" type="submit">Submit ticket</button>' +
      '<span class="muted small">You can have up to 5 open tickets at a time.</span>' +
    '</form>';
    h += '<h3 class="help-sec">Your tickets</h3>';
    h += group('myOpen', 'Open', mine.open, false);
    h += group('myClosed', 'Closed', mine.closed, false);
    if (adminLists) {
      h += '<h3 class="help-sec">🛠️ All players&rsquo; tickets (admins only)</h3>';
      h += group('admOpen', 'Open', adminLists.open, true);
      h += group('admClosed', 'Closed', adminLists.closed, true);
    }
    host.innerHTML = h;
    wireList(host);
  }

  function renderThread(host) {
    var t = openTicket.ticket;
    var h = '';
    h += '<button type="button" class="btn small ghost" id="helpBackBtn">← Back to tickets</button>';
    h += '<h3 class="help-thread-subject">' + esc(t.subject) +
      ' <span class="help-pill help-pill-' + esc(t.status) + '">' + (t.status === 'open' ? 'Open' : 'Closed') + '</span></h3>';
    h += '<p class="muted small">Started by ' + esc(t.owner_name || 'Player') + ' · ' + esc(fmtDate(t.created_at)) + '</p>';
    h += '<div class="help-thread">';
    h += openTicket.messages.map(function (m) {
      return '<div class="help-msg' + (m.author_is_admin ? ' help-msg-admin' : '') + '">' +
        '<div class="help-msg-head"><b>' + esc(m.author_name || 'Player') + '</b>' +
          (m.author_is_admin ? ' <span class="help-admin-tag">Admin</span>' : '') +
          ' <span class="muted small">' + esc(fmtDate(m.created_at)) + '</span></div>' +
        '<div class="help-msg-body">' + esc(m.body) + '</div>' +
      '</div>';
    }).join('');
    h += '</div>';
    if (t.status === 'open') {
      h += '<form id="helpReplyForm" class="help-reply">' +
        '<textarea id="helpReplyText" rows="3" maxlength="2000" placeholder="Write a reply…"></textarea>' +
        '<div class="row"><button class="btn primary" type="submit">Reply</button></div>' +
      '</form>';
    } else {
      h += '<p class="muted small">This ticket is closed. ' +
        (isAdmin() ? 'Reopen it to reply.' : 'If you need more help, submit a new ticket.') + '</p>';
    }
    if (isAdmin()) {
      h += '<div class="row help-admin-actions">' +
        (t.status === 'open'
          ? '<button type="button" class="btn danger" id="helpCloseBtn">Close ticket</button>'
          : '<button type="button" class="btn" id="helpReopenBtn">Reopen ticket</button>') +
      '</div>';
    }
    host.innerHTML = h;
    var back = $('#helpBackBtn');
    if (back) back.addEventListener('click', function () { openTicket = null; render(); });
    var form = $('#helpReplyForm');
    if (form) form.addEventListener('submit', onReply);
    var close = $('#helpCloseBtn');
    if (close) close.addEventListener('click', function () { setStatus('closed'); });
    var reopen = $('#helpReopenBtn');
    if (reopen) reopen.addEventListener('click', function () { setStatus('open'); });
  }

  function wireList(host) {
    var form = $('#helpNewForm');
    if (form) form.addEventListener('submit', onSubmit);
    host.querySelectorAll('.help-group-head').forEach(function (b) {
      b.addEventListener('click', function () {
        var k = b.getAttribute('data-group');
        expanded[k] = !expanded[k];
        render();
      });
    });
    host.querySelectorAll('.help-ticket-row').forEach(function (b) {
      b.addEventListener('click', function () { openThread(b.getAttribute('data-ticket')); });
    });
  }

  /* ---------------------------------------------------------- actions */
  async function onSubmit(e) {
    e.preventDefault();
    var subject = ($('#helpSubject').value || '').trim();
    var body = ($('#helpBodyText').value || '').trim();
    if (!subject) { ctx.toast('Give your ticket a subject.', 'warn'); return; }
    if (!body) { ctx.toast('Describe what you need help with.', 'warn'); return; }
    try {
      var t = await CPS.cloud.call('submit_ticket', { p_subject: subject, p_body: body });
      ctx.toast('Ticket submitted — an admin will take a look.', '', 3000);
      loadedFor = null;
      await load(true);
      if (t && t.id) openThread(t.id); else render();
    } catch (err) { fail(err); }
  }

  async function openThread(id) {
    try {
      openTicket = await CPS.cloud.call('get_ticket', { p_ticket: id });
      render();
    } catch (err) { fail(err); }
  }

  async function onReply(e) {
    e.preventDefault();
    var body = ($('#helpReplyText').value || '').trim();
    if (!body) { ctx.toast('Write a reply first.', 'warn'); return; }
    try {
      await CPS.cloud.call('reply_ticket', { p_ticket: openTicket.ticket.id, p_body: body });
      var id = openTicket.ticket.id;
      loadedFor = null;
      await load(true);
      openTicket = await CPS.cloud.call('get_ticket', { p_ticket: id });
      render();
    } catch (err) { fail(err); }
  }

  async function setStatus(status) {
    try {
      await CPS.cloud.call('admin_set_ticket_status', { p_ticket: openTicket.ticket.id, p_status: status });
      ctx.toast(status === 'closed' ? 'Ticket closed.' : 'Ticket reopened.', '', 2500);
      var id = openTicket.ticket.id;
      loadedFor = null;
      await load(true);
      openTicket = await CPS.cloud.call('get_ticket', { p_ticket: id });
      render();
    } catch (err) { fail(err); }
  }

  /* View entry point: app.js renderView calls CPS.help.enter(). */
  async function enter() {
    try { await load(false); } catch (e) { fail(e); }
    render();
  }

  CPS.help = { enter: enter, render: render, openTicket: openThread };
})(window.CPS = window.CPS || {});

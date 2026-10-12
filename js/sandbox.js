/* ============================================================================
 * CPS.sandbox — admin-only testing ground.
 *
 * Anything new we build (games, features) starts life here, visible only to
 * admin accounts, and graduates to a public tab when it's ready.
 *
 * HOW TO ADD SOMETHING TO THE SANDBOX:
 *   1. Write the feature as a module exposing render(el) and teardown().
 *   2. Add it to ITEMS below (or call CPS.sandbox.register(item)):
 *        { id: 'dice-duel', title: 'Dice Duel', blurb: 'Roll-off vs the house.',
 *          status: 'testing',
 *          render: function (el) { CPS.diceDuel.render(el); },
 *          teardown: function () { CPS.diceDuel.teardown(); } }
 *
 * HOW TO RELEASE IT TO EVERYONE:
 *   Flip status from 'testing' to 'public'. That's the whole release — boot()
 *   automatically gives the item its own public tab (ahead of the Sandbox tab),
 *   its own view section, and hash routing. No index.html or app.js edits.
 *   Flip it back to 'testing' to pull it out of public again.
 *
 * Visibility: the Sandbox tab itself uses the same admin-tab gating as the
 * Admin tab (hidden unless the account is an admin, or in local/guest mode).
 * Server RPCs keep their own permission checks — this is a client-side gate.
 * ========================================================================== */
(function () {
  'use strict';

  var PREFIX = 'sbx-';

  var ITEMS = [
    { id: 'shop', title: 'Shop', blurb: 'Rotating pack stock for Store Credit. Restocks at midnight/noon.',
      status: 'testing',
      render: function (el) { CPS.shop.render(el); },
      teardown: function () { CPS.shop.teardown(); } },
  ];

  var launched = null; // id of the item currently open (sandbox or public tab)

  // PUBLIC maps every view id this module owns to 1. app.js consults it in its
  // hash whitelist and renderView branch, so graduated items need no app.js edits.
  var PUBLIC = { 'sandbox': 1 };
  function markPublic(it) { PUBLIC[PREFIX + it.id] = 1; }
  ITEMS.forEach(function (it) { if (it.status === 'public') markPublic(it); });

  function $(s, r) { return (r || document).querySelector(s); }
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function byId(id) {
    for (var i = 0; i < ITEMS.length; i++) if (ITEMS[i].id === id) return ITEMS[i];
    return null;
  }
  function publicItems() { return ITEMS.filter(function (it) { return it.status === 'public'; }); }
  function teardownLaunched() {
    if (!launched) return;
    var prev = byId(launched);
    launched = null;
    if (prev && prev.teardown) { try { prev.teardown(); } catch (e) { /* ignore */ } }
  }

  /* ---------------- sandbox home (the admin-only tab) ---------------- */
  function renderHome() {
    var panel = $('#sandboxPanel');
    if (!panel) return;
    teardownLaunched();
    var html = '<div class="panel sandbox-head">' +
      '<h2>Sandbox</h2>' +
      '<p class="muted small">Admin-only testing ground. New games and features start here and ' +
      'move to a public tab when they\'re ready. Regular players can\'t see this tab.</p></div>';
    if (!ITEMS.length) {
      html += '<div class="panel"><p class="muted">Nothing in testing right now — new builds will show up here first.</p></div>';
    } else {
      html += '<div class="sandbox-grid">' + ITEMS.map(function (it) {
        var pub = it.status === 'public';
        return '<div class="panel sandbox-card">' +
          '<h3>' + esc(it.title) + '</h3>' +
          (it.blurb ? '<p class="muted small">' + esc(it.blurb) + '</p>' : '') +
          '<p class="sandbox-status ' + (pub ? 'is-public' : 'is-testing') + '">' +
            (pub ? '● Live on its own public tab' : '● In testing') + '</p>' +
          (pub
            ? '<button class="btn" data-sbx-open="' + esc(it.id) + '">Open public tab</button>'
            : '<button class="btn primary" data-sbx-launch="' + esc(it.id) + '">Launch test</button>') +
          '</div>';
      }).join('') + '</div>';
      html += '<div class="panel"><p class="muted small"><b>Releasing:</b> flip the item\'s ' +
        '<code>status</code> to <code>\'public\'</code> in <code>js/sandbox.js</code> and it gets ' +
        'its own public tab on next load. Flip it back to <code>\'testing\'</code> to pull it back.</p></div>';
    }
    panel.innerHTML = html;
    panel.querySelectorAll('[data-sbx-launch]').forEach(function (b) {
      b.addEventListener('click', function () { launch(b.getAttribute('data-sbx-launch')); });
    });
    panel.querySelectorAll('[data-sbx-open]').forEach(function (b) {
      b.addEventListener('click', function () {
        if (typeof CPS !== 'undefined' && CPS.app) CPS.app.showView(PREFIX + b.getAttribute('data-sbx-open'));
      });
    });
  }

  function launch(id) {
    var it = byId(id);
    var panel = $('#sandboxPanel');
    if (!it || !panel || it.status === 'public') return;
    launched = id;
    panel.innerHTML = '<button class="btn sandbox-back" id="sbxBack" type="button">← Back to Sandbox</button>' +
      '<div id="sbxStage"></div>';
    $('#sbxBack').addEventListener('click', function () { renderHome(); });
    try {
      it.render($('#sbxStage'));
    } catch (e) {
      $('#sbxStage').innerHTML = '<div class="panel"><p class="muted">This test item failed to render: ' +
        esc(e && e.message) + '</p></div>';
    }
  }

  /* ---------------- public (graduated) items ---------------- */
  function ensurePublicTab(it) {
    var view = PREFIX + it.id;
    var nav = $('nav.tabs');
    var sandboxBtn = $('#sandboxTabBtn');
    var main = $('main');
    var sbxSec = $('#view-sandbox');
    if (nav && sandboxBtn && !document.getElementById('sbx-tab-' + it.id)) {
      var b = document.createElement('button');
      b.className = 'tab';
      b.id = 'sbx-tab-' + it.id;
      b.setAttribute('data-view', view);
      b.textContent = it.title;
      b.addEventListener('click', function () {
        if (typeof CPS !== 'undefined' && CPS.app) CPS.app.showView(view);
      });
      nav.insertBefore(b, sandboxBtn); // public tabs sit ahead of the Sandbox tab
    }
    if (main && !document.getElementById('view-' + view)) {
      var sec = document.createElement('section');
      sec.className = 'view';
      sec.id = 'view-' + view;
      if (sbxSec) main.insertBefore(sec, sbxSec);
      else main.appendChild(sec);
    }
  }
  function renderPublic(view) {
    var id = view.slice(PREFIX.length);
    var it = byId(id);
    var sec = document.getElementById('view-' + view);
    if (!it || it.status !== 'public' || !sec) return;
    teardownLaunched();
    launched = id;
    var stage = sec.querySelector('.sbx-public-stage');
    if (!stage) {
      sec.innerHTML = '<div class="sbx-public-stage"></div>';
      stage = sec.querySelector('.sbx-public-stage');
    }
    stage.innerHTML = '';
    try {
      it.render(stage);
    } catch (e) {
      stage.innerHTML = '<div class="panel"><p class="muted">Something went wrong loading this feature.</p></div>';
    }
  }

  /* ---------------- boot: build public tabs for graduated items ---------------- */
  function boot() {
    publicItems().forEach(ensurePublicTab);
    // app.js boot may have run before this script executed (async init): if the
    // URL hash points at the sandbox or a public item, re-assert the view now.
    var h = (location.hash || '').replace('#', '');
    if ((h === 'sandbox' || CPS.sandbox.isPublicView(h)) &&
        typeof CPS !== 'undefined' && CPS.app) {
      CPS.app.showView(h);
    }
  }

  CPS.sandbox = {
    items: ITEMS,
    PUBLIC: PUBLIC,
    register: function (item) {
      if (item && item.id && !byId(item.id)) {
        ITEMS.push(item);
        if (item.status === 'public') {
          markPublic(item);
          ensurePublicTab(item); // late-registered public items get tabs too
          // a direct #sbx-<id> load may have resolved before this registration ran
          var h = (location.hash || '').replace('#', '');
          if (h === PREFIX + item.id && typeof CPS !== 'undefined' && CPS.app) CPS.app.showView(h);
        }
      }
    },
    isPublicView: function (v) {
      if (typeof v !== 'string' || v.indexOf(PREFIX) !== 0) return false;
      var it = byId(v.slice(PREFIX.length));
      return !!it && it.status === 'public';
    },
    publicViews: function () {
      return publicItems().map(function (it) { return PREFIX + it.id; });
    },
    render: function (view) {
      if (view === 'sandbox') renderHome();
      else if (typeof view === 'string' && view.indexOf(PREFIX) === 0) renderPublic(view);
    }
  };

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})(window.CPS = window.CPS || {});

/* OAuth login (Google via Supabase Auth) — client module.
   STAGED ONLY (migration 189 package) — not on the live site.

   Split out so js/app.js stays under the push size limit, exactly
   like js/donate.js / js/giftbundle.js: it consumes CPS.appCtx,
   registers as CPS.oauth, and app.js needs at most two one-line
   guarded hooks (see client/INTEGRATION.md). On its own it can also
   enhance the login gate via a MutationObserver fallback.

   Design (see ../SPEC.md):
   * Supabase Auth is IDENTITY ONLY. supabase-js is loaded LAZILY, only
     when a player actually starts (or returns from) an OAuth flow —
     never at boot, never for PIN-only players.
   * The OAuth exchange calls the migration-189 RPCs with the Supabase
     access token as Authorization: Bearer. The SERVER reads
     auth.uid() from that verified JWT; this file never sends a user
     id or email for the server to trust (email/provider shown in the
     UI below is display-only — the server re-reads both itself).
   * A successful RPC returns the SAME kind of cps session token
     cps_login has always returned. We store it through
     CPS.cloud.setToken (one-line cloud.js export, INTEGRATION.md)
     and reload, so app.js boots into the account exactly as it does
     after a PIN login.
   * LINKING REMOVES PIN ACCESS — the link confirmation below says so
     in plain words and the confirm button is labelled with it. The
     server (cps_oauth_link) does the removal atomically.
*/
(function (CPS) {
  'use strict';

  var C = (CPS && CPS.appCtx) || null;
  /* Pinned 2026-10-27 for the Google-only ship: supabase-js 2.118.0
     (the current stable v2 tag reported by jsDelivr's package metadata).
     The lazy loader sets the matching sha384 SRI below and
     crossOrigin='anonymous'; if the CDN bytes differ, the browser
     refuses to execute the script rather than running altered code. */
  var SUPABASE_JS_URL = 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.118.0/dist/umd/supabase.min.js';
  var SUPABASE_JS_INTEGRITY = 'sha384-UagCvVPT5XXA0Hx+nJYUAGBFseHT9zBgpJMSebsAxl9lciTwbT+39j5VfRjdP5Tp';
  var SS_INTENT = 'cps:oauth:intent';     // 'login' | 'link' | 'claim'
  var SS_PROVIDER = 'cps:oauth:provider'; // first ship: 'google' only
  var SS_CODE = 'cps:oauth:claimCode';
  var SS_RETURN = 'cps:oauth:return';     // captured return tokens (see captureReturn)
  var SS_LINKPENDING = 'cps:oauth:linkPending'; // pending-link flag (see maybeResumeLink; unarmed since §6.16)

  var sbPromise = null;   // lazy supabase-js load
  var sb = null;          // supabase client, once loaded

  /* Return-handling race (found live, 2026-10-27 ship night): after
     the Google round-trip, supabase-js may still be exchanging the
     return URL (PKCE) when handleReturn() first samples
     auth.getSession() — a single sample can find no session yet and
     the old code silently abandoned the login (the Admin account
     failed 4 times, then succeeded on the 5th: a pure race).
     handleReturn() therefore WAITS for the session (auth-state event
     + polling, bounded) before concluding there is none. The harness
     shrinks these bounds via _test.setSessionWait so the suite stays
     fast and deterministic. */
  var SESSION_WAIT_MS = 6000;  // bounded wait for the return session
  var SESSION_POLL_MS = 250;   // getSession() poll interval while waiting
  var returnInFlight = null;   // once-guard: concurrent handleReturn() calls share one run

  /* Pending-link auto-resume (LINKPATH-AUDIT option (c), §6.15):
     a settle check (maybeResumeLink) opens the link confirmation
     when SS_LINKPENDING is set and the player is PIN-logged-in
     with that Google session still alive — even after a
     stored-token boot, which the app.js doLogin hook misses. An
     'episode' is keyed to the cps token value: a fresh login (new
     token) re-arms the once-guard; the guard also latches
     whenever the confirmation is opened by any path. DORMANT
     since §6.16: no UI path arms the flag anymore (the choice
     modal's 'link it' shows a plain instruction instead), so the
     machinery below simply never fires. */
  var linkResumeBusy = false;  // a settle check's async hop is in flight
  var linkResumeShown = false; // the confirmation already opened this episode
  var linkEpisodeKey = null;   // cps token the current episode is keyed to

  function cfg() { return (CPS.cloud && CPS.cloud.config) || window.CPS_CONFIG || {}; }
  function esc(s) {
    if (C && C.esc) return C.esc(s);
    return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }
  function toast(msg, type, ms) {
    if (C && C.toast) C.toast(msg, type, ms);
    else window.alert(msg);
  }
  function providerLabel(p) {
    return p === 'apple' ? 'Apple' : p === 'google' ? 'Google' : 'Google/Apple';
  }
  function googleMark() {
    return '<span class="oauth-mark g" aria-hidden="true">' +
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48" width="20" height="20" focusable="false">' +
      '<path fill="#FFC107" d="M43.611 20.083H42V20H24v8h11.303C33.654 32.657 29.223 36 24 36c-6.627 0-12-5.373-12-12s5.373-12 12-12c3.059 0 5.842 1.154 7.961 3.039l5.657-5.657C34.046 6.053 29.268 4 24 4 12.955 4 4 12.955 4 24s8.955 20 20 20 20-8.955 20-20c0-1.341-.138-2.65-.389-3.917z"/>' +
      '<path fill="#FF3D00" d="M6.306 14.691l6.571 4.819C14.655 15.108 18.961 12 24 12c3.059 0 5.842 1.154 7.961 3.039l5.657-5.657C34.046 6.053 29.268 4 24 4 16.318 4 9.656 8.337 6.306 14.691z"/>' +
      '<path fill="#4CAF50" d="M24 44c5.166 0 9.86-1.977 13.409-5.192l-6.19-5.238C29.211 35.091 26.715 36 24 36c-5.202 0-9.619-3.317-11.283-7.946l-6.522 5.025C9.505 39.556 16.227 44 24 44z"/>' +
      '<path fill="#1976D2" d="M43.611 20.083H42V20H24v8h11.303c-.792 2.237-2.231 4.166-4.087 5.571l6.19 5.238C36.971 39.205 44 34 44 24c0-1.341-.138-2.65-.389-3.917z"/>' +
      '</svg></span>';
  }
  function ssGet(k) { try { return sessionStorage.getItem(k); } catch (e) { return null; } }
  function ssSet(k, v) { try { sessionStorage.setItem(k, v); } catch (e) {} }
  function ssDel(k) { try { sessionStorage.removeItem(k); } catch (e) {} }
  function clearIntent() { ssDel(SS_INTENT); ssDel(SS_PROVIDER); ssDel(SS_CODE); ssDel(SS_RETURN); }
  /* The pending-link flag lives OUTSIDE clearIntent() on purpose:
     a dismissal (data-oauth-close, hence clearIntent) must NOT
     wipe it — surviving dismissal is the flag's whole job. It
     stores only the provider name — nothing sensitive — and
     maybeResumeLink owns its lifecycle. Since §6.16 nothing arms
     it (setLinkPending has no callers); it stays only as part of
     the dormant auto-resume machinery. */
  function setLinkPending() {
    ssSet(SS_LINKPENDING, ssGet(SS_PROVIDER) || 'google');
    linkResumeShown = false; // a fresh choice-modal selection re-arms the resume
  }
  function clearLinkPending() { ssDel(SS_LINKPENDING); }

  /* ---------- return-token capture (RETURN-AUDIT-2) ----------
     app.js is a hash-routed SPA: its boot ends in showView(), which
     replaceStates location.hash to the view name ('#packs'). On a
     provider return, the implicit-flow tokens exist ONLY in that
     fragment, and the logged-out boot reaches the rewrite while this
     module is still lazily downloading supabase-js — by the time
     createClient initializes, detectSessionInUrl finds '#packs' and
     establishes nothing: no session, no SIGNED_IN, ever (found live
     2026-10-27; validation/RETURN-AUDIT-2.md). So bind() — which
     evaluates strictly before boot() can reach the rewrite — copies
     the tokens into sessionStorage first, and handleReturn()
     establishes the session from the copy via auth.setSession. The
     URL is never rewritten here: if supabase-js wins its own race
     and consumes the fragment, the stash simply defers (see
     establishFromStash). */
  function captureReturn() {
    try {
      var parts = [location.hash.replace(/^#/, ''), location.search.replace(/^\?/, '')];
      for (var i = 0; i < parts.length; i++) {
        if (!parts[i]) continue;
        var p = new URLSearchParams(parts[i]);
        if (p.get('access_token') || p.get('refresh_token') || p.get('error')) {
          ssSet(SS_RETURN, JSON.stringify({
            access_token: p.get('access_token') || '',
            refresh_token: p.get('refresh_token') || '',
            error: p.get('error') || '',
            error_description: p.get('error_description') || ''
          }));
          return;
        }
      }
    } catch (e) { /* best effort — the fragment path may still win */ }
  }
  function readReturnStash() {
    var raw = ssGet(SS_RETURN);
    if (!raw) return null;
    try {
      var o = JSON.parse(raw);
      return (o && (o.access_token || o.refresh_token || o.error)) ? o : null;
    } catch (e) { return null; }
  }

  /* ---------- lazy supabase-js ---------- */
  function loadSupabase() {
    if (window.supabase && window.supabase.createClient) return Promise.resolve();
    if (sbPromise) return sbPromise;
    sbPromise = new Promise(function (resolve, reject) {
      var s = document.createElement('script');
      s.src = SUPABASE_JS_URL;
      s.integrity = SUPABASE_JS_INTEGRITY;
      s.crossOrigin = 'anonymous';
      s.async = true;
      s.onload = function () { resolve(); };
      s.onerror = function () { sbPromise = null; reject(new Error("Couldn't load the sign-in library. Check your connection and try again.")); };
      document.head.appendChild(s);
    });
    return sbPromise;
  }
  function client() {
    if (sb) return Promise.resolve(sb);
    return loadSupabase().then(function () {
      var c = cfg();
      sb = window.supabase.createClient(c.supabaseUrl, c.supabaseKey);
      return sb;
    });
  }

  /* ---------- RPCs with the Supabase JWT ----------
     PostgREST verifies the Bearer token and exposes auth.uid() to the
     RPC. The publishable key still goes in apikey, as everywhere. */
  function oauthRpc(fn, args, accessToken) {
    var c = cfg();
    return fetch(c.supabaseUrl.replace(/\/+$/, '') + '/rest/v1/rpc/' + fn, {
      method: 'POST',
      headers: {
        apikey: c.supabaseKey,
        Authorization: 'Bearer ' + accessToken,
        'Content-Type': 'application/json',
        Accept: 'application/json'
      },
      body: JSON.stringify(args || {})
    }).then(function (res) {
      return res.text().then(function (text) {
        var data = null;
        try { data = text ? JSON.parse(text) : null; } catch (e) { /* keep null */ }
        if (!res.ok) {
          var err = new Error((data && data.message) || ('Server error (' + res.status + ')'));
          err.status = res.status; err.code = data && data.code;
          throw err;
        }
        return data;
      });
    });
  }

  /* ---------- finishing a flow ----------
     Store the minted cps token, drop the Supabase session (its job is
     done; the cps token is the site's session now), and reload so the
     normal boot path (initAccount) picks the token up untouched. */
  function setCpsToken(token) {
    if (CPS.cloud && CPS.cloud.setToken) { CPS.cloud.setToken(token, true); return; }
    /* Fallback if the cloud.js export has not landed yet: mirror
       cloud.js's own storage (same key, localStorage = remember me). */
    try {
      localStorage.removeItem('cps:v1:token'); sessionStorage.removeItem('cps:v1:token');
      localStorage.setItem('cps:v1:token', token);
    } catch (e) {}
  }
  function finish(token) {
    setCpsToken(token);
    clearIntent();
    var done = function () { location.reload(); };
    if (sb) sb.auth.signOut().then(done, done);
    else done();
  }
  /* Friendly error text that keeps the server's error code visible —
     on the ship night a bare code (e.g. no_oauth_session) was the one
     clue that mattered, and it never reached the screen. */
  function errText(src, fallback) {
    var msg = (src && (src.error || src.message)) || fallback;
    var code = src && src.code;
    if (code && String(msg).indexOf(String(code)) === -1) msg += ' (Error code: ' + code + ')';
    return msg;
  }

  /* Return-path failures render through our OWN overlay (.oauth-overlay,
     z-index 999) — never solely through app.js's modal (z-50). During
     the 2026-10-27 ship the maintenance overlay (z-200) sat on top of
     the app modal and every sign-in error was invisible; the player
     just saw the maintenance screen again. An OK-only terminal error
     needs no app-modal machinery, so it always takes this surface. */
  function showOAuthOverlay(html) {
    var wrap = document.createElement('div');
    wrap.className = 'oauth-overlay';
    wrap.innerHTML = '<div class="oauth-sheet login-box">' + html + '</div>';
    document.body.appendChild(wrap);
    wireClose(wrap);
    return wrap;
  }
  function failToModal(title, text) {
    showOAuthOverlay(
      '<h2>' + esc(title) + '</h2>' +
      '<p class="muted small">' + esc(text) + '</p>' +
      '<div class="row"><button class="btn primary" type="button" data-oauth-close>OK</button></div>');
  }

  /* ---------- our own modal surface (uses appCtx.openModal when up) ---------- */
  function openOAuthModal(html, after) {
    if (C && C.openModal) {
      C.openModal(html, function (box) {
        wireClose(box);
        if (after) after(box);
      });
      return;
    }
    /* Pre-boot fallback (gate not yet wired): our own overlay. */
    var wrap = showOAuthOverlay(html);
    if (after) after(wrap);
  }
  function wireClose(root) {
    var btns = root.querySelectorAll('[data-oauth-close]');
    Array.prototype.forEach.call(btns, function (b) {
      b.addEventListener('click', function () {
        clearIntent();
        if (C && C.closeModal) C.closeModal(true);
        var ov = root.classList && root.classList.contains('oauth-overlay') ? root : root.closest && root.closest('.oauth-overlay');
        if (ov) ov.remove();
      });
    });
  }

  /* ---------- step 1: send the player to Google ---------- */
  function startProvider(provider, intent, claimCode) {
    ssDel(SS_RETURN); // an outbound flow never inherits a stale capture
    ssSet(SS_INTENT, intent || 'login');
    ssSet(SS_PROVIDER, provider);
    if (claimCode) ssSet(SS_CODE, claimCode); else ssDel(SS_CODE);
    return client().then(function (client_) {
      return client_.auth.signInWithOAuth({
        provider: provider,
        options: { redirectTo: cfg().siteUrl || (location.origin + location.pathname) }
      });
    }).then(function (r) {
      if (r && r.error) throw r.error;
      /* success = browser is navigating to the provider */
    }).catch(function (e) {
      clearIntent();
      toast((e && e.message) || 'Sign-in could not start.', 'error', 5000);
    });
  }

  /* ---------- step 2: we are back from the provider ---------- */
  function looksLikeReturn() {
    if (readReturnStash()) return true;
    if (/[#&?](access_token|error|provider_token)=/.test(location.hash + location.search)) return true;
    if (ssGet(SS_INTENT)) {
      try { return Object.keys(localStorage).some(function (k) { return k.indexOf('sb-') === 0 && k.indexOf('auth-token') > -1; }); }
      catch (e) { return true; }
    }
    return false;
  }

  /* Wait for supabase-js to finish establishing the session from the
     return URL. Resolves with the first real session from whichever
     source fires first — the immediate getSession() sample, the
     onAuthStateChange event (SIGNED_IN lands when the URL exchange
     completes), or a short-interval getSession() poll — or with null
     once SESSION_WAIT_MS expires (with one final sample at the bound).
     The settled flag is a once-guard: event + poll + final sample can
     never resolve twice, so the exchange below fires exactly once. */
  function waitForSession(client_) {
    return new Promise(function (resolve) {
      var settled = false;
      var timer = null, poll = null, sub = null;
      function done(session) {
        if (settled) return;
        settled = true;
        if (timer) clearTimeout(timer);
        if (poll) clearInterval(poll);
        if (sub) { try { sub.unsubscribe(); } catch (e) {} }
        resolve(session || null);
      }
      function sample() {
        client_.auth.getSession().then(function (res) {
          var s = res && res.data && res.data.session;
          if (s) done(s);
        }, function () { /* a failed sample is not final — keep waiting */ });
      }
      try {
        var r = client_.auth.onAuthStateChange(function (_event, session) {
          if (session) done(session);
        });
        sub = r && r.data && r.data.subscription;
      } catch (e) { /* no event source — polling still covers it */ }
      sample();
      poll = setInterval(sample, SESSION_POLL_MS);
      timer = setTimeout(function () {
        client_.auth.getSession().then(function (res) {
          done(res && res.data && res.data.session);
        }, function () { done(null); });
      }, SESSION_WAIT_MS);
    });
  }

  /* Establish the session explicitly from the captured return
     tokens when supabase-js has NOT already done so from the
     fragment (its own race, occasionally won). One getSession()
     sample decides: a live session means the library consumed the
     return itself and the stash defers — setSession is not called.
     Otherwise setSession validates the access token with the auth
     server, persists the session under the standard sb-… key and
     fires SIGNED_IN, so the waitForSession below resolves at once.
     A failure here is not final: waitForSession still gets its
     bounded chance (the fragment may yet be processed). */
  function establishFromStash(client_, stash) {
    if (!stash || !stash.access_token) return Promise.resolve();
    return client_.auth.getSession().then(function (res) {
      if (res && res.data && res.data.session) return null; // library's copy — stash defers
      return client_.auth.setSession({
        access_token: stash.access_token,
        refresh_token: stash.refresh_token || ''
      }).then(function () { return null; }, function () { return null; });
    }, function () { return null; });
  }

  function handleReturn() {
    if (returnInFlight) return returnInFlight;
    if (!looksLikeReturn()) return Promise.resolve(false);
    var stashFailed = false;
    var p = client().then(function (client_) {
      var stash = readReturnStash();
      if (stash && stash.error) {
        /* The provider returned an error, not tokens: no session
           will ever arrive, so fail visibly NOW instead of running
           the bounded wait to expiry. */
        stashFailed = true;
        clearIntent();
        failToModal('Sign-in problem',
          stash.error_description || ('Google sign-in failed (' + stash.error + '). Please try again.'));
        return null;
      }
      return establishFromStash(client_, stash).then(function () {
        return waitForSession(client_);
      });
    }).then(function (session) {
      if (stashFailed) return true;
      if (!session) {
        clearIntent();
        failToModal('Sign-in problem',
          'We didn\'t get your Google sign-in back — it may have been interrupted. Please try "Continue with Google" again.');
        return true;
      }
      var intent = ssGet(SS_INTENT) || 'login';
      if (intent === 'link') { resumeLink(session); return true; }
      if (intent === 'claim') { return doClaim(session); }
      return doOAuthLogin(session);
    }).catch(function (e) {
      clearIntent();
      failToModal('Sign-in problem', errText(e, 'Something went wrong signing you in. Please try again.'));
      return true;
    });
    returnInFlight = p;
    var clearGuard = function () { if (returnInFlight === p) returnInFlight = null; };
    p.then(clearGuard, clearGuard);
    return p;
  }

  function doOAuthLogin(session) {
    return oauthRpc('cps_oauth_login',
      { p_user_agent: (navigator.userAgent || '').slice(0, 200) },
      session.access_token
    ).then(function (r) {
      if (r && r.ok) { finish(r.token); return true; }
      if (r && r.code === 'not_linked') { openChoiceModal(session); return true; }
      failToModal('Sign-in problem', errText(r, 'Sign-in failed. Please try again.'));
      return true;
    });
  }

  /* Duplicate-account guard: an unlinked identity NEVER silently
     becomes an empty new account. The player chooses, explicitly. */
  function openChoiceModal(session) {
    var email = session.user && session.user.email;
    openOAuthModal(
      '<h2>One quick choice</h2>' +
      '<p class="muted small">' + esc(email ? ('You signed in as ' + email + '. ') : '') +
      'This Google account is not linked to a PackRipper account yet.</p>' +
      '<div class="oauth-choice">' +
      '<button class="btn primary" type="button" id="oauthChoiceLink">I already have a PackRipper account — link it</button>' +
      '<button class="btn" type="button" id="oauthChoiceNew">I\'m new — create my account</button>' +
      '<button class="btn ghost" type="button" data-oauth-close>Cancel</button>' +
      '</div>' +
      '<p class="muted small">Linking keeps everything — your collection, packs and vault stay exactly as they are. Creating a new account starts empty.</p>',
      function (box) {
        box.querySelector('#oauthChoiceLink').addEventListener('click', function () {
          ssSet(SS_INTENT, 'link');
          if (CPS.cloud && CPS.cloud.hasToken()) { resumeLink(session); return; }
          /* Not logged in: one unambiguous instruction — Franklin's
             wording verbatim — and a single Okay back to the gate.
             The dropdown's Link Google is the one canonical linking
             route, so this screen deliberately does NOT arm the
             pending-link flag (§6.16; it supersedes the §6.15
             auto-resume promise this modal used to make). The
             paragraph is a double-quoted JS string so the sentence
             sits verbatim in the served bytes. */
          openOAuthModal(
            '<h2>Link your account</h2>' +
            "<p class=\"muted small\">To link an existing account, please log in using your username and PIN and select 'Link Google' in the top right profile dropdown</p>" +
            '<div class="row"><button class="btn primary" type="button" data-oauth-close>Okay</button></div>',
            function (b2) { wireClose(b2); });
        });
        box.querySelector('#oauthChoiceNew').addEventListener('click', function () {
          openNameModal(session);
        });
      });
  }

  /* Pick-a-name: new signups only. Prefilled from the provider. */
  function openNameModal(session) {
    var u = session.user || {};
    var meta = u.user_metadata || {};
    var prefill = meta.full_name || meta.name || (u.email ? u.email.split('@')[0] : '');
    openOAuthModal(
      '<h2>Welcome to PackRipper</h2>' +
      '<p class="muted small">What should other players call you? This is your display name — you can change it later.</p>' +
      '<form id="oauthNameForm" class="login-form">' +
      '<label class="field">Display name <input id="oauthName" type="text" maxlength="32" autocomplete="name" value="' + esc(prefill) + '"></label>' +
      '<div class="row"><button class="btn primary" type="submit" id="oauthNameGo">Create my account</button>' +
      '<button class="btn ghost" type="button" data-oauth-close>Cancel</button></div></form>' +
      '<div id="oauthNameMsg" class="login-msg"></div>',
      function (box) {
        wireClose(box);
        var input = box.querySelector('#oauthName');
        setTimeout(function () { input.focus(); input.select(); }, 30);
        box.querySelector('#oauthNameForm').addEventListener('submit', function (e) {
          e.preventDefault();
          var name = input.value.trim();
          var msg = box.querySelector('#oauthNameMsg');
          if (!name) { msg.textContent = 'Pick a display name first.'; msg.className = 'login-msg bad'; return; }
          var btn = box.querySelector('#oauthNameGo');
          btn.disabled = true; btn.textContent = 'Creating…';
          oauthRpc('cps_oauth_signup',
            { p_display_name: name, p_user_agent: (navigator.userAgent || '').slice(0, 200) },
            session.access_token
          ).then(function (r) {
            if (r && r.ok) {
              /* One-time welcome pop-up: ONLY here, on the actual
                 signup response — never on oauth_login, never again. */
              if (r.welcome_packs > 0) openWelcomeModal(r);
              else finish(r.token);
              return;
            }
            msg.textContent = (r && r.error) || 'Could not create the account.';
            msg.className = 'login-msg bad';
            btn.disabled = false; btn.textContent = 'Create my account';
          }).catch(function (err) {
            msg.textContent = err.message || 'Could not create the account.';
            msg.className = 'login-msg bad';
            btn.disabled = false; btn.textContent = 'Create my account';
          });
        });
      });
  }

  /* ---------- one-time welcome pop-up (signup only) ----------
     Shown immediately after a successful cps_oauth_signup, and from
     nowhere else: not on login, not on link, not on claim. The core
     line is Franklin's dictated wording (2026-10-25), verbatim — the
     grant is called a 'box set' here by his choice; in the SPEC and
     the SQL it is 30 random packs (migration 152/144 semantics).
     'Start ripping!' stores the minted cps token and reloads into
     the packs screen, like every other finish(). */
  function openWelcomeModal(r) {
    openOAuthModal(
      '<h2>🎉 Welcome!</h2>' +
      '<p><b>Thanks for joining PackRipper! You\'ve been granted a box set containing 30 random packs.</b></p>' +
      '<p class="muted small">They\'re already in your account, ready to rip. You can earn more by:</p>' +
      '<ul class="oauth-earn">' +
      '<li><b>Opening packs</b> — packs can contain spin tickets, store credit and arcade tokens</li>' +
      '<li><b>Completing Daily Quests</b> — for spin tickets, packs and tokens</li>' +
      '<li><b>Spinning the Prize Wheel</b> — win packs and more</li>' +
      '<li><b>Playing Arcade games</b> — win packs, tickets and tokens</li>' +
      '<li><b>Buying packs in the Shop</b> — with the store credit you earn</li>' +
      '<li><b>Trading with other players and completing sets</b> — turning in a whole set earns big turn-in rewards</li>' +
      '</ul>' +
      '<div class="row"><button class="btn primary" type="button" id="oauthWelcomeGo">Start ripping!</button></div>',
      function (box) {
        var go = box.querySelector('#oauthWelcomeGo');
        if (go) go.addEventListener('click', function () { finish(r.token); });
        else finish(r.token);
      });
  }

  /* ---------- linking (existing account, PIN session in hand) ---------- */
  /* Called by the app.js hook after a PIN login, or by the modal's
     continue button. Requires BOTH proofs: the cps token already in
     storage AND the live Supabase session we came back with. */
  function resumeLink(session) {
    if (!(CPS.cloud && CPS.cloud.hasToken())) return;
    if (session) { openLinkConfirm(session); return; }
    client().then(function (c) { return c.auth.getSession(); }).then(function (res) {
      var s = res && res.data && res.data.session;
      if (s) { openLinkConfirm(s); return; }
      /* No live Google session: that is the ordinary case for a plain
         PIN login (doLogin calls resumeLink unconditionally), so stay
         silent unless a link flow was actually in flight — every PIN
         login used to get a spurious failure toast. */
      if (ssGet(SS_INTENT) === 'link' || ssGet(SS_LINKPENDING)) {
        toast('Google sign-in did not complete. Please try again.', 'warn', 4500);
      }
    });
  }

  function openLinkConfirm(session) {
    linkResumeShown = true; // any confirm opening latches this episode's resume guard
    var provider = (session.user && session.user.app_metadata && session.user.app_metadata.provider) || ssGet(SS_PROVIDER) || 'google';
    var label = providerLabel(provider);
    var email = session.user && session.user.email;
    var acct = (C && C.S && C.S.account) || {};
    var who = acct.display_name ? ('<b>' + esc(acct.display_name) + '</b>') : 'your PackRipper account';
    openOAuthModal(
      '<h2>Link ' + esc(label) + ' and turn off my PIN</h2>' +
      '<p>You are linking ' + esc(email ? (label + ' (' + email + ')') : label) + ' to ' + who + '.</p>' +
      '<div class="warn-box">Once you link, <b>your PIN will stop working immediately</b>. ' +
      'From then on, only this ' + esc(label) + ' account can log you in. ' +
      'Your collection, packs and vault stay exactly as they are.</div>' +
      '<p class="muted small">Lost access to that ' + esc(label) + ' account later? The site owner can unlink it and give you a one-time claim code — your PIN is never restored.</p>' +
      '<div class="row"><button class="btn primary" type="button" id="oauthLinkGo">Link ' + esc(label) + ' and turn off my PIN</button>' +
      '<button class="btn ghost" type="button" data-oauth-close>Not yet</button></div>' +
      '<div id="oauthLinkMsg" class="login-msg"></div>',
      function (box) {
        wireClose(box);
        /* 'Not yet' is an explicit cancel of a (possibly resumed)
           link: retire the pending flag for good — the auto-resume
           must not re-offer it until the player chooses 'link it'
           again. wireClose's clearIntent does not know the flag. */
        Array.prototype.forEach.call(box.querySelectorAll('[data-oauth-close]'), function (b) {
          b.addEventListener('click', function () { clearLinkPending(); });
        });
        box.querySelector('#oauthLinkGo').addEventListener('click', function () {
          var btn = this, msg = box.querySelector('#oauthLinkMsg');
          btn.disabled = true; btn.textContent = 'Linking…';
          oauthRpc('cps_oauth_link',
            { p_token: CPS.cloud.getToken() },
            session.access_token
          ).then(function (r) {
            if (r && r.ok) {
              clearIntent();
              clearLinkPending();
              if (C && C.S && C.S.account) C.S.account.oauth_linked = true;
              refreshLinkMenuItem();
              openOAuthModal(
                '<h2>' + esc(label) + ' linked</h2>' +
                '<p class="muted small">From now on, “Continue with ' + esc(label) + '” logs you straight in. Your PIN has been turned off.</p>' +
                '<div class="row"><button class="btn primary" type="button" data-oauth-close>Got it</button></div>',
                function (b2) { wireClose(b2); if (sb) sb.auth.signOut(); });
              return;
            }
            msg.textContent = (r && r.error) || 'Linking failed. Please try again.';
            msg.className = 'login-msg bad';
            btn.disabled = false; btn.textContent = 'Link ' + label + ' and turn off my PIN';
          }).catch(function (err) {
            msg.textContent = err.message || 'Linking failed. Please try again.';
            msg.className = 'login-msg bad';
            btn.disabled = false; btn.textContent = 'Link ' + label + ' and turn off my PIN';
          });
        });
      });
  }

  /* Start linking while already logged in with a PIN (account menu /
     profile button calls CPS.oauth.openLink()). */
  function openLink() {
    if (!(CPS.cloud && CPS.cloud.hasToken())) {
      toast('Log in with your username and PIN first — linking attaches Google to that account.', 'warn', 5000);
      return Promise.resolve(false);
    }
    openOAuthModal(
      '<h2>Link Google</h2>' +
      '<p class="muted small">Continue with the Google account you want to log in with from now on. After you pick it, we will ask you to confirm — linking turns your PIN off.</p>' +
      '<div class="oauth-choice">' +
      '<button class="btn oauth-btn google" type="button" id="oauthLinkGoogle">' + googleMark() + ' Link Google</button>' +
      '<button class="btn ghost" type="button" data-oauth-close>Not yet</button></div>',
      function (box) {
        wireClose(box);
        box.querySelector('#oauthLinkGoogle').addEventListener('click', function () { startProvider('google', 'link'); });
      });
    return Promise.resolve(true);
  }

  /* ---------- claim-code recovery ---------- */
  function openClaim() {
    openOAuthModal(
      '<h2>Claim your account</h2>' +
      '<p class="muted small">Enter the one-time claim code the site owner gave you, then sign in with your NEW Google account. The code works once, and only until it expires.</p>' +
      '<form id="oauthClaimForm" class="login-form">' +
      '<label class="field">Claim code <input id="oauthClaimCode" type="text" maxlength="14" autocomplete="off" autocapitalize="characters" spellcheck="false" placeholder="XXXX-XXXX-XXXX"></label>' +
      '<div class="oauth-choice">' +
      '<button class="btn oauth-btn google" type="submit" data-provider="google">' + googleMark() + ' Continue with Google</button>' +
      '<button class="btn ghost" type="button" data-oauth-close>Cancel</button></div></form>',
      function (box) {
        wireClose(box);
        var provider = 'google';
        Array.prototype.forEach.call(box.querySelectorAll('[data-provider]'), function (b) {
          b.addEventListener('click', function () { provider = b.dataset.provider; });
        });
        box.querySelector('#oauthClaimForm').addEventListener('submit', function (e) {
          e.preventDefault();
          var code = box.querySelector('#oauthClaimCode').value.trim();
          if (!code) { toast('Enter the claim code first.', 'warn'); return; }
          startProvider(provider, 'claim', code);
        });
      });
  }
  function doClaim(session) {
    var code = ssGet(SS_CODE) || '';
    return oauthRpc('cps_oauth_claim',
      { p_code: code, p_user_agent: (navigator.userAgent || '').slice(0, 200) },
      session.access_token
    ).then(function (r) {
      if (r && r.ok) { toast('Account claimed — welcome back!', 'good'); finish(r.token); return true; }
      failToModal('Claim problem', errText(r, 'That claim code did not work.'));
      return true;
    });
  }

  /* ---------- admin recovery (RPC exists in 189; panel wiring is push-day) ---------- */
  function adminUnlink(accountId) {
    if (!(CPS.cloud && CPS.cloud.call)) return Promise.reject(new Error('Cloud is off.'));
    return CPS.cloud.call('admin_oauth_unlink', { p_account: accountId }).then(function (r) {
      if (r && r.ok) {
        openOAuthModal(
          '<h2>Claim code for ' + esc(r.account.display_name) + '</h2>' +
          '<p class="muted small">Their Google link is removed and all their sessions are ended. Give them this one-time code privately — it is shown <b>once</b> and expires ' +
          esc(new Date(r.claim_expires_at).toLocaleString()) + '. Their old PIN is NOT restored.</p>' +
          '<div class="login-pair"><span>Claim code</span><code class="big-code">' + esc(r.claim_code) + '</code></div>' +
          '<div class="row"><button class="btn primary" type="button" data-oauth-close>Done</button></div>',
          function (b2) { wireClose(b2); });
      }
      return r;
    });
  }

  /* ---------- login gate enhancement ---------- */
  function enhanceGate(box) {
    if (!box || box.querySelector('#oauthGate')) return;
    var form = box.querySelector('#loginForm');
    if (!form) return;
    var mount = document.createElement('div');
    mount.id = 'oauthGate';
    mount.className = 'oauth-gate';
    mount.innerHTML =
      '<button class="btn oauth-btn google" type="button" id="oauthGoogle">' + googleMark() + ' Continue with Google</button>' +
      '<div class="oauth-divider"><span>or use your username + PIN</span></div>';
    form.parentNode.insertBefore(mount, form);
    var foot = document.createElement('p');
    foot.className = 'muted small';
    foot.innerHTML = 'New here? Continue with Google and we will create your account. ' +
      '<a href="#" id="oauthClaimLink">Have a claim code?</a>';
    var msg = box.querySelector('#loginMsg');
    (msg ? msg.parentNode.insertBefore(foot, msg.nextSibling) : form.parentNode.appendChild(foot));
    mount.querySelector('#oauthGoogle').addEventListener('click', function () { startProvider('google', 'login'); });
    foot.querySelector('#oauthClaimLink').addEventListener('click', function (e) { e.preventDefault(); openClaim(); });
  }

  /* Observer fallback: enhance the gate whenever app.js shows it, so
     the module works even before the one-line showGate hook lands. */
  function watchGate() {
    if (!window.MutationObserver || !document.body) return;
    var mo = new MutationObserver(function () {
      var box = document.querySelector('.login-box.gate');
      if (box) enhanceGate(box);
      refreshLinkMenuItem();
      maybeResumeLink();
    });
    mo.observe(document.body, { childList: true, subtree: true });
  }

  /* Account-menu entry for linking, injected by the module itself
     (the menu is static HTML), so app.js needs no bind() edit. */
  function injectLinkMenuItem() {
    var menu = document.getElementById('acctMenu');
    if (!menu || document.getElementById('acctLinkBtn')) return;
    var b = document.createElement('button');
    b.className = 'acct-menu-item';
    b.id = 'acctLinkBtn';
    b.type = 'button';
    b.textContent = '🔗 Link Google';
    var logout = document.getElementById('acctLogoutBtn');
    menu.insertBefore(b, logout || null);
    b.addEventListener('click', function () {
      menu.classList.add('hidden');
      openLink();
    });
    watchLinkMenu(menu);
    refreshLinkMenuItem();
  }

  /* Hide the Link item once the account is linked (migration 210 puts
     oauth_linked on S.account via cps.state_json). The flag is read
     fresh on every evaluation, so a state refresh that flips it (link,
     admin unlink) is honored the next time the menu opens. */
  function refreshLinkMenuItem() {
    var b = document.getElementById('acctLinkBtn');
    if (!b) return;
    var acct = (C && C.S && C.S.account) || null;
    b.style.display = (acct && acct.oauth_linked) ? 'none' : '';
  }

  /* app.js's toggleAccountMenu is IIFE-internal (no hook); it opens the
     menu by removing the 'hidden' class, so observe that instead. */
  function watchLinkMenu(menu) {
    if (!window.MutationObserver || !menu) return;
    var mo = new MutationObserver(function () { refreshLinkMenuItem(); });
    mo.observe(menu, { attributes: true, attributeFilter: ['class'] });
  }

  /* ---------- pending-link auto-resume settle check ----------
     Rides the watchGate observer above: app rendering settles →
     this runs. It fires ONLY when everything coincides:
       - the pending flag is set (armed by the choice modal's
         'link it' until §6.16; no path arms it now — dormant),
       - a cps token is present (they PIN-logged in — any style:
         fresh form login OR a stored-token boot, which is the case
         the app.js doLogin → resumeLink hook cannot see),
       - the account is loaded and NOT oauth_linked,
       - a live Supabase session still exists.
     Then the link confirmation opens, exactly once per episode.
     Flag lifecycle: set by the choice modal until §6.16 (no
     longer); cleared on link success (openLinkConfirm), on
     explicit cancel in the confirmation (openLinkConfirm wires
     that), when the account is observed linked, and when the
     Google session is gone at a check where a token IS present
     (stale — it could never resume). While merely logged out the
     flag is KEPT untouched: surviving dismissal → gate → PIN
     login was its entire purpose (§6.15 design; dormant now). */
  function maybeResumeLink() {
    var token = null;
    try { token = (CPS.cloud && CPS.cloud.getToken && CPS.cloud.getToken()) || null; } catch (e) { token = null; }
    if (token !== linkEpisodeKey) { linkEpisodeKey = token; linkResumeShown = false; }
    if (!ssGet(SS_LINKPENDING)) return;
    if (!(CPS.cloud && CPS.cloud.hasToken())) return; // logged out: keep waiting
    var acct = (C && C.S && C.S.account) || null;
    if (!acct || !acct.id) return;                    // state not settled yet; a later settle retries
    if (acct.oauth_linked) { clearLinkPending(); return; }
    if (linkResumeShown || linkResumeBusy) return;
    linkResumeBusy = true;
    client().then(function (c) { return c.auth.getSession(); }).then(function (res) {
      linkResumeBusy = false;
      var s = res && res.data && res.data.session;
      if (!s) {
        clearLinkPending();
        if (ssGet(SS_INTENT) === 'link') ssDel(SS_INTENT);
        return;
      }
      /* Re-verify at open time: state may have moved during the hop. */
      if (!ssGet(SS_LINKPENDING) || linkResumeShown) return;
      var a2 = (C && C.S && C.S.account) || null;
      if (!a2 || !a2.id) return;
      if (a2.oauth_linked) { clearLinkPending(); return; }
      linkResumeShown = true;
      openLinkConfirm(s);
    }, function () { linkResumeBusy = false; });
  }

  function bind() {
    captureReturn();
    watchGate();
    injectLinkMenuItem();
    handleReturn();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', bind);
  else bind();

  CPS.oauth = {
    enhanceGate: enhanceGate,
    startProvider: startProvider,
    openLink: openLink,
    resumeLink: resumeLink,
    openClaim: openClaim,
    adminUnlink: adminUnlink,
    handleReturn: handleReturn,
    _test: {
      providerLabel: providerLabel, openNameModal: openNameModal, openWelcomeModal: openWelcomeModal,
      waitForSession: waitForSession,
      captureReturn: captureReturn,
      refreshLinkMenuItem: refreshLinkMenuItem,
      openChoiceModal: openChoiceModal,
      checkLinkResume: maybeResumeLink,
      linkPending: function () { return ssGet(SS_LINKPENDING); },
      bind: bind,
      setSessionWait: function (waitMs, pollMs) { SESSION_WAIT_MS = waitMs; SESSION_POLL_MS = pollMs; }
    }
  };
})(window.CPS);

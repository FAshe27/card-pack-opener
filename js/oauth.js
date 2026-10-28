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

  var sbPromise = null;   // lazy supabase-js load
  var sb = null;          // supabase client, once loaded

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
  function clearIntent() { ssDel(SS_INTENT); ssDel(SS_PROVIDER); ssDel(SS_CODE); }

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
  function failToModal(title, text) {
    openOAuthModal(
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
    /* Pre-boot fallback (gate not yet wired): a bare overlay. */
    var wrap = document.createElement('div');
    wrap.className = 'oauth-overlay';
    wrap.innerHTML = '<div class="oauth-sheet login-box">' + html + '</div>';
    document.body.appendChild(wrap);
    wireClose(wrap);
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
    if (/[#&?](access_token|error|provider_token)=/.test(location.hash + location.search)) return true;
    if (ssGet(SS_INTENT)) {
      try { return Object.keys(localStorage).some(function (k) { return k.indexOf('sb-') === 0 && k.indexOf('auth-token') > -1; }); }
      catch (e) { return true; }
    }
    return false;
  }

  function handleReturn() {
    if (!looksLikeReturn()) return Promise.resolve(false);
    return client().then(function (client_) {
      return client_.auth.getSession();
    }).then(function (res) {
      var session = res && res.data && res.data.session;
      if (!session) { clearIntent(); return false; }
      var intent = ssGet(SS_INTENT) || 'login';
      if (intent === 'link') { resumeLink(session); return true; }
      if (intent === 'claim') { doClaim(session); return true; }
      return doOAuthLogin(session);
    }).catch(function (e) {
      clearIntent();
      failToModal('Sign-in problem', (e && e.message) || 'Something went wrong signing you in. Please try again.');
      return true;
    });
  }

  function doOAuthLogin(session) {
    return oauthRpc('cps_oauth_login',
      { p_user_agent: (navigator.userAgent || '').slice(0, 200) },
      session.access_token
    ).then(function (r) {
      if (r && r.ok) { finish(r.token); return true; }
      if (r && r.code === 'not_linked') { openChoiceModal(session); return true; }
      failToModal('Sign-in problem', (r && r.error) || 'Sign-in failed. Please try again.');
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
          openOAuthModal(
            '<h2>Link your account</h2>' +
            '<p class="muted small">First, log in the way you do now — with your username and PIN. ' +
            'Then use the button below and we will link this Google account to it. Nothing about your account changes except how you log in.</p>' +
            '<div class="row"><button class="btn primary" type="button" id="oauthLinkAfterPin">I\'ve logged in with my PIN — continue linking</button>' +
            '<button class="btn ghost" type="button" data-oauth-close>Later</button></div>',
            function (b2) {
              wireClose(b2);
              b2.querySelector('#oauthLinkAfterPin').addEventListener('click', function () {
                if (CPS.cloud && CPS.cloud.hasToken()) resumeLink(session);
                else toast('Log in with your username and PIN first, then tap continue.', 'warn', 4500);
              });
            });
          if (C && C.closeModal) { /* gate is behind us: reopen it so they can PIN-login */
            setTimeout(function () { /* player closes this modal via Later, gate shows */ }, 0);
          }
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
      if (s) openLinkConfirm(s);
      toast('Google sign-in did not complete. Please try again.', 'warn', 4500);
    });
  }

  function openLinkConfirm(session) {
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
        box.querySelector('#oauthLinkGo').addEventListener('click', function () {
          var btn = this, msg = box.querySelector('#oauthLinkMsg');
          btn.disabled = true; btn.textContent = 'Linking…';
          oauthRpc('cps_oauth_link',
            { p_token: CPS.cloud.getToken() },
            session.access_token
          ).then(function (r) {
            if (r && r.ok) {
              clearIntent();
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
      failToModal('Claim problem', (r && r.error) || 'That claim code did not work.');
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
      '<p class="oauth-link-hint">If you log in using Username and PIN, you MUST log in with that before linking your Google Login in the top right dropdown.</p>' +
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
  }

  function bind() {
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
    _test: { providerLabel: providerLabel, openNameModal: openNameModal, openWelcomeModal: openWelcomeModal }
  };
})(window.CPS);

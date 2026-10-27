/* Prize wheel: canvas rendering + spin animation.
   The wheel STRUCTURE mirrors supabase/migrations/176_wheel_categories.sql
   (cps.wheel_config): 8 category slices weighted by their active set
   count, one Bonus slice (weight 3), hop slices at weight 1.5. Segments
   come from the server config; categories carry their member set list so
   single spins can play a sub-wheel (see playHops / openSubWheel).
   Bulk modes (wheelMulti, autospin) never show sub-wheels. */
(function (CPS) {
  var TAU = Math.PI * 2;

  /* Static, set-agnostic structure. Resolved against a set list by localConfig(). */
  var STRUCTURE = [
    { id: 'w1', name: 'Prize Wheel',  tiers: [{ packs: 1, weight: 1 }, { tokens: 3, weight: 1 }, { goto: 'w2', label: 'Go to second wheel', weight: 1 }] },
    { id: 'w2', name: 'Double Wheel', tiers: [{ packs: 2, weight: 1 }, { tokens: 7, weight: 1 }, { goto: 'w1', label: 'Back to first wheel', weight: 1 }, { goto: 'w3', label: 'Go to third wheel', weight: 1 }] },
    { id: 'w3', name: 'Triple Wheel', tiers: [{ packs: 3, weight: 1 }, { tokens: 10, weight: 1 }, { goto: 'w1', label: 'Back to first wheel', weight: 1 }, { goto: 'w2', label: 'Back to second wheel', weight: 1 }] }
  ];

  var GOTO_COLORS = { w1: '#8e6cc9', w2: '#ffb21e', w3: '#ff5d5d' };

  /* Category map (mirrors cps.wheel_segments in migration 176; the server
     config is authoritative for cloud play - this is for guest mode and
     sub-wheel coloring). Any set id missing here falls to Curiosities. */
  var CATEGORIES = [
    { key: 'animals',       name: 'Animals',              icon: '🐾', color: '#43aa8b', sets: ['birdwatching', 'sea', 'aquariums', 'dogs', 'insects', 'reptiles', 'wild-mammals', 'dinosaurs'] },
    { key: 'world',         name: 'World & Nature',       icon: '🌍', color: '#3d8bfd', sets: ['countries', 'states', 'world-cities', 'world-landmarks', 'nps', 'natural-wonders', 'water', 'plants', 'gems-minerals'] },
    { key: 'sports',        name: 'Sports & Racing',      icon: '🏆', color: '#e63946', sets: ['mlb', 'nba-collection', 'nfl-collection', 'formula-1-collection', 'nascar-collection', 'indy'] },
    { key: 'gaming',        name: 'Gaming',               icon: '🎮', color: '#7c5cff', sets: ['acrs', 'minecraft', 'mkrt', 'pokemon', 'skyrim', 'stardew-valley', 'zelda'] },
    { key: 'entertainment', name: 'Entertainment',        icon: '🎬', color: '#f372b5', sets: ['movies-pack-images', 'tv-shows', 'disney', 'pixar', 'spongebob', 'star-wars', 'hero', 'stage', 'music-pack', 'works-of-art'] },
    { key: 'food',          name: 'Food & Drink',         icon: '🍔', color: '#ffb020', sets: ['beverages', 'cereals', 'candy', 'fast-food', 'iconic-dishes'] },
    { key: 'machines',      name: 'Machines & Transport', icon: '🚗', color: '#8d99ae', sets: ['civilian-aircraft', 'aircraft', 'us-navy', 'cars', 'motorcycles', 'trains', 'hwy'] },
    { key: 'curiosities',   name: 'Curiosities',          icon: '🔮', color: '#2ec4b6', sets: ['space', 'technology-collection', 'periodic', 'cryptids', 'calendar', 'playing', 'gas', 'coasters', 'theme-parks'] }
  ];
  var CAT_OF_SET = {};
  CATEGORIES.forEach(function (c) { c.sets.forEach(function (id) { CAT_OF_SET[id] = c.key; }); });
  function categoryOf(setId) {
    var k = CAT_OF_SET[setId] || 'curiosities';
    for (var i = 0; i < CATEGORIES.length; i++) if (CATEGORIES[i].key === k) return CATEGORIES[i];
    return CATEGORIES[CATEGORIES.length - 1];
  }
  /* Bonus sub-roll prizes (migration 176): values are Prize/Double/Triple. */
  var BONUS_PRIZES = [
    { bp: 'jumbled', icon: '🎲', color: '#9d6bc7', amounts: [1, 3, 5],   label: function (a) { return a + ' × Jumbled Mess pack' + (a === 1 ? '' : 's'); } },
    { bp: 'credit',  icon: '💵', color: '#c9a227', amounts: [5, 10, 15], label: function (a) { return '$' + a + ' Store Credit'; } },
    { bp: 'tickets', icon: '🎟️', color: '#7c5cff', amounts: [2, 4, 6],  label: function (a) { return a + ' Spin Tickets'; } },
    { bp: 'tokens',  icon: '🪙', color: '#43aa8b', amounts: [5, 15, 25], label: function (a) { return a + ' Arcade Tokens'; } },
    { bp: 'random',  icon: '🎁', color: '#f372b5', amounts: [2, 4, 6],  label: function (a) { return a + ' Random Packs'; } }
  ];
  function shade(hex, amt) {
    var n = parseInt(String(hex).replace('#', ''), 16);
    if (isNaN(n)) return hex;
    var r = Math.max(0, Math.min(255, (n >> 16) + amt));
    var g = Math.max(0, Math.min(255, ((n >> 8) & 255) + amt));
    var b = Math.max(0, Math.min(255, (n & 255) + amt));
    return 'rgb(' + r + ',' + g + ',' + b + ')';
  }
  var FALLBACK = ['#3f8cff', '#38c97f', '#b35cff', '#ff7a59', '#ffb21e', '#ff4fa3', '#2dd4bf', '#f472b6'];

  /* Baked emblem sprite (Franklin, 2026-10-21): live fillText emoji go
     through the platform font, and iOS draws them small, padded and
     inconsistent glyph-to-glyph - so set slices paint pre-rendered Noto
     Color Emoji images from assets/wheel-emblems.png instead (emblem ->
     cell map in js/wheel-emblems.js; both generated by
     tools/build-wheel-emblems.py). Until the sprite arrives, or for an
     emblem with no cell yet, the text glyph below is the fallback. */
  var emblemImg = null, emblemReady = false, lastDrawState = null;
  function ensureEmblemSprite() {
    if (emblemImg) return;
    emblemImg = new Image();
    emblemImg.onload = function () {
      emblemReady = true;
      if (lastDrawState && document.contains(lastDrawState.canvas)) {
        lastDrawState.canvas._faceCvs = null; /* rebake the face with images */
        draw(lastDrawState.canvas, lastDrawState.wheel, lastDrawState.rotation, lastDrawState.key);
      }
    };
    emblemImg.src = window.WHEEL_EMBLEM_SPRITE || 'assets/wheel-emblems.png';
  }
  function emblemCell(ch) {
    var W = window.WHEEL_EMBLEMS;
    if (!W || !W.map || !ch) return -1;
    var v = W.map[ch];
    return typeof v === 'number' ? v : -1;
  }

  function setColor(setId, i) {
    try {
      var s = window.CardSets && window.CardSets.get(setId);
      if (s && s.theme && s.theme.primary) return s.theme.primary;
    } catch (e) {}
    return FALLBACK[i % FALLBACK.length];
  }

  function setName(setId) {
    if (setId === 'jumbled') return 'Jumbled Mess';
    try {
      var s = window.CardSets && window.CardSets.get(setId);
      if (s && s.name) return s.name;
    } catch (e) {}
    return setId;
  }

  function setEmblem(setId) {
    if (setId === 'jumbled') return '\u{1F3B2}';
    try {
      var s = window.CardSets && window.CardSets.get(setId);
      if (s && s.pack && s.pack.emblem) return s.pack.emblem;
      if (s && s.emblem) return s.emblem;
    } catch (e) {}
    return '\u{1F381}';
  }

  /* Enrich a server-shaped config {wheels:[{id,name,segments:[...]}]} with
     colors and display labels, using the client's set data. */
  function enrich(cfg) {
    var i = 0;
    return {
      wheels: (cfg.wheels || []).map(function (w) {
        return {
          id: w.id, name: w.name,
          segments: (w.segments || []).map(function (sg) {
            var out = {
              key: sg.key, kind: sg.kind,
              set_id: sg.set_id || null, packs: sg.packs || 0,
              tokens: sg.tokens || 0, credit: sg.credit || 0,
              weight: sg.weight, wheel: sg.wheel || null,
              label: sg.label || '',
              category: sg.category || null, sets: sg.sets || null,
              icon: sg.icon || null, color: sg.color || null
            };
            if (sg.kind === 'category') {
              out.label = (sg.icon || '') + ' ' + (sg.label || sg.category || 'Category');
              out.color = sg.color || FALLBACK[i++ % FALLBACK.length];
              out.emblem = sg.icon || '🎁';
            } else if (sg.kind === 'bonus') {
              out.label = '⭐ BONUS';
              out.color = sg.color || '#ffd60a';
              out.emblem = '⭐';
            } else if (sg.kind === 'packs') {
              out.label = sg.packs + ' × ' + setName(sg.set_id);
              out.color = setColor(sg.set_id, i++);
              out.emblem = setEmblem(sg.set_id);
            } else if (sg.kind === 'tokens') {
              out.label = sg.tokens + ' x 🪙 Arcade Tokens';
              out.color = '#6b6bd6';
            } else {
              out.color = GOTO_COLORS[sg.wheel] || '#999';
            }
            return out;
          })
        };
      })
    };
  }

  /* Guest-mode config: same category structure, resolved against the
     client's set list (ids grouped by the category map above). */
  function localConfig() {
    var sets = ((window.CardSets && window.CardSets.all()) || []).slice()
      .sort(function (a, b) { return a.id < b.id ? -1 : a.id > b.id ? 1 : 0; });
    var byCat = {};
    sets.forEach(function (st) {
      var c = categoryOf(st.id);
      (byCat[c.key] = byCat[c.key] || []).push(st.id);
    });
    return enrich({
      wheels: STRUCTURE.map(function (w) {
        var mult = w.tiers[0].packs || 1;
        var segs = [];
        CATEGORIES.forEach(function (c) {
          var members = byCat[c.key] || [];
          if (!members.length) return;
          segs.push({ key: 'cat:' + c.key, kind: 'category', category: c.key, label: c.name, icon: c.icon, color: c.color, packs: mult, weight: members.length, sets: members.slice() });
        });
        segs.push({ key: 'bonus', kind: 'bonus', label: 'BONUS', icon: '⭐', color: '#ffd60a', weight: 3 });
        w.tiers.forEach(function (t) {
          if (t.goto) segs.push({ key: 'goto:' + t.goto, kind: 'goto', wheel: t.goto, label: t.label, weight: 1.5 });
        });
        return { id: w.id, name: w.name, segments: segs };
      })
    });
  }

  /* Center angle of a segment in the wheel's local frame (rotation = 0). */
  function segSpan(wheel, key) {
    var total = wheel.segments.reduce(function (a, s) { return a + s.weight; }, 0);
    var acc = 0;
    for (var i = 0; i < wheel.segments.length; i++) {
      var sg = wheel.segments[i], a0 = (acc / total) * TAU;
      acc += sg.weight;
      if (sg.key === key) return { a0: a0, a1: (acc / total) * TAU };
    }
    return { a0: 0, a1: TAU };
  }

  /* Paint the wheel face (segments + labels + rim + hub) once at rotation 0
     into an offscreen canvas. Spins then just rotate this bitmap per frame
     instead of re-rendering ~30 shadowed text labels 60x/second. */
  function paintFace(canvas, wheel) {
    var W = canvas.width, H = canvas.height, cx = W / 2, cy = H / 2;
    var R = Math.min(W, H) / 2 - 10;
    var off = document.createElement('canvas');
    off.width = W; off.height = H;
    var ctx = off.getContext('2d');
    var segs = wheel.segments;
    var total = segs.reduce(function (a, s) { return a + s.weight; }, 0) || 1;
    var acc = 0;
    segs.forEach(function (sg) {
      var a0 = (acc / total) * TAU - Math.PI / 2;
      acc += sg.weight;
      var a1 = (acc / total) * TAU - Math.PI / 2;
      ctx.beginPath();
      ctx.moveTo(cx, cy);
      ctx.arc(cx, cy, R, a0, a1);
      ctx.closePath();
      ctx.fillStyle = sg.color;
      ctx.fill();
      ctx.strokeStyle = 'rgba(0,0,0,.4)';
      ctx.lineWidth = 2;
      ctx.stroke();
      var mid = (a0 + a1) / 2;
      ctx.save();
      ctx.translate(cx, cy);
      ctx.rotate(mid);
      ctx.textBaseline = 'middle';
      ctx.shadowColor = 'rgba(0,0,0,.65)';
      if (sg.kind === 'packs') {
        /* Set slices carry the set's emblem instead of its name: at 60+
           slices the full-name labels collide into mush near the hub,
           while one glyph per slice stays legible (Franklin, 2026-10-21).
           The winning set is still named in the result banner/summary. */
        ctx.translate(R - Math.round(R * 0.102), 0);
        ctx.rotate(Math.PI / 2);
        var cell = emblemReady ? emblemCell(sg.emblem) : -1;
        if (cell >= 0) {
          var EW = window.WHEEL_EMBLEMS, es = Math.round(R * 0.088); /* fits inside the slice wedge (~0.091R of arc at this ring); 0.115 spilled over the edges (Franklin, 2026-10-21) */
          ctx.shadowBlur = 0; /* shadows smudge transparent images on iOS too */
          ctx.drawImage(emblemImg, (cell % EW.cols) * EW.cell, Math.floor(cell / EW.cols) * EW.cell, EW.cell, EW.cell, -es / 2, -es / 2, es, es);
        } else {
          ctx.textAlign = 'center';
          ctx.font = Math.round(R * 0.095) + 'px "Apple Color Emoji", "Noto Color Emoji", "Segoe UI Emoji", sans-serif';
          ctx.shadowBlur = 0; /* emoji + shadow = a gray smudge on iOS Safari (it shadows the whole bitmap); text labels keep theirs */
          ctx.fillStyle = '#fff';
          ctx.fillText(sg.emblem || '\u{1F381}', 0, 0);
        }
      } else {
        ctx.textAlign = 'right';
        ctx.font = '700 15px system-ui, -apple-system, sans-serif';
        ctx.shadowBlur = 5;
        ctx.fillStyle = '#fff';
        if (sg.kind === 'bonus') { ctx.fillStyle = '#231600'; ctx.shadowBlur = 0; ctx.font = '800 17px system-ui, -apple-system, sans-serif'; }
        ctx.fillText(sg.label, R - 16, 0, R - 70);
      }
      ctx.restore();
    });
    /* rim + hub */
    ctx.beginPath(); ctx.arc(cx, cy, R + 4, 0, TAU);
    ctx.strokeStyle = '#ffe08a'; ctx.lineWidth = 6; ctx.stroke();
    ctx.beginPath(); ctx.arc(cx, cy, 34, 0, TAU);
    ctx.fillStyle = '#1c1c28'; ctx.fill();
    ctx.strokeStyle = '#ffe08a'; ctx.lineWidth = 4; ctx.stroke();
    ctx.fillStyle = '#ffe08a';
    ctx.font = '700 22px system-ui, sans-serif';
    ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    ctx.fillText('\u2605', cx, cy + 1);
    return off;
  }

  function faceFor(canvas, wheel) {
    if (canvas._faceCvs && canvas._faceWheel === wheel &&
        canvas._faceW === canvas.width && canvas._faceH === canvas.height) {
      return canvas._faceCvs;
    }
    var off = paintFace(canvas, wheel);
    canvas._faceCvs = off; canvas._faceWheel = wheel;
    canvas._faceW = canvas.width; canvas._faceH = canvas.height;
    return off;
  }

  function draw(canvas, wheel, rotation, highlightKey) {
    lastDrawState = { canvas: canvas, wheel: wheel, rotation: rotation || 0, key: highlightKey || null };
    ensureEmblemSprite();
    var ctx = canvas.getContext('2d');
    var W = canvas.width, H = canvas.height, cx = W / 2, cy = H / 2;
    var R = Math.min(W, H) / 2 - 10;
    ctx.clearRect(0, 0, W, H);
    ctx.save();
    ctx.translate(cx, cy);
    ctx.rotate(rotation || 0);
    ctx.drawImage(faceFor(canvas, wheel), -cx, -cy);
    ctx.restore();
    if (highlightKey) {
      var sp = segSpan(wheel, highlightKey);
      var ha0 = rotation + sp.a0 - Math.PI / 2, ha1 = rotation + sp.a1 - Math.PI / 2;
      var hubR = 34; /* must match the hub drawn in paintFace: stroke the wedge from the hub edge out */
      ctx.beginPath();
      ctx.moveTo(cx + Math.cos(ha0) * hubR, cy + Math.sin(ha0) * hubR);
      ctx.arc(cx, cy, R, ha0, ha1);
      ctx.lineTo(cx + Math.cos(ha1) * hubR, cy + Math.sin(ha1) * hubR);
      ctx.arc(cx, cy, hubR, ha1, ha0, true); /* inner edge must follow the hub circle — closePath() alone chords straight across it */
      ctx.closePath();
      ctx.shadowColor = '#ffb21e';
      ctx.shadowBlur = 14;
      ctx.strokeStyle = '#ffe08a';
      ctx.lineWidth = 6;
      ctx.stroke();
      ctx.shadowBlur = 0;
    }
  }

  /* Animate the wheel to land on the segment with `key`. rotation 0 = pointer at top. */
  function segIndexAt(wheel, localAngle) {
    var segs = wheel.segments;
    var total = segs.reduce(function (a, s) { return a + s.weight; }, 0) || 1;
    var acc = 0;
    for (var i = 0; i < segs.length; i++) {
      acc += segs[i].weight;
      if (localAngle < (acc / total) * TAU) return i;
    }
    return segs.length - 1;
  }

  function spinTo(canvas, wheel, key, fromRot, durationMs, done) {
    var sp = segSpan(wheel, key);
    var targetLocal = sp.a0 + (sp.a1 - sp.a0) * (0.2 + 0.6 * Math.random());
    var want = -targetLocal; /* rotation that puts targetLocal at the top */
    var cur = ((fromRot % TAU) + TAU) % TAU;
    var delta = (((want - cur) % TAU) + TAU) % TAU;
    var turns = 5 + Math.floor(Math.random() * 3);
    var finalRot = fromRot + turns * TAU + delta;
    var t0 = null, lastIdx = -1;
    function frame(t) {
      if (t0 === null) t0 = t;
      var p = Math.min(1, (t - t0) / durationMs);
      var e = 1 - Math.pow(1 - p, 3); /* easeOutCubic */
      var rot = fromRot + (finalRot - fromRot) * e;
      var ptrLocal = ((-rot % TAU) + TAU) % TAU; /* wheel-local angle under the pointer */
      var idx = segIndexAt(wheel, ptrLocal);
      if (lastIdx >= 0 && idx !== lastIdx && CPS.audio && CPS.audio.tick) CPS.audio.tick();
      lastIdx = idx;
      draw(canvas, wheel, rot);
      if (p < 1) requestAnimationFrame(frame);
      else { canvas._rot = ((finalRot % TAU) + TAU) % TAU; if (done) done(); }
    }
    requestAnimationFrame(frame);
  }

  /* Local "waiting" spin: keeps the wheel visibly turning while a spin
     RPC is in flight, so a slow server never reads as a hang. playHops
     stops it and takes over for the real result animation. */
  function startIdle(canvas, wheel) {
    if (!canvas || !wheel) return;
    stopIdle(canvas);
    var rot = canvas._rot || 0, last = null, speed = 0;
    canvas._idle = true;
    function frame(t) {
      if (!canvas._idle) return;
      if (!document.contains(canvas)) { stopIdle(canvas); return; }
      if (last === null) last = t;
      var dt = Math.min(0.05, (t - last) / 1000); last = t;
      speed = Math.min(2.2, speed + dt * 1.4); /* rev/s: ramps up, then holds */
      rot = (rot + speed * TAU * dt) % TAU;
      canvas._rot = rot;
      draw(canvas, wheel, rot);
      canvas._idleRaf = requestAnimationFrame(frame);
    }
    canvas._idleRaf = requestAnimationFrame(frame);
  }
  function stopIdle(canvas) {
    if (!canvas) return;
    canvas._idle = false;
    if (canvas._idleRaf) cancelAnimationFrame(canvas._idleRaf);
    canvas._idleRaf = null;
  }

  /* Play a server-rolled hop chain, one wheel at a time. Returns a promise. */
  function playHops(canvas, cfg, hops, speed) {
    speed = speed || 1;
    return new Promise(function (resolve) {
      var byId = {};
      cfg.wheels.forEach(function (w) { byId[w.id] = w; });
      stopIdle(canvas);
      var i = 0, last = null, first = true;
      function next() {
        if (i >= hops.length) {
          /* Single spins only: a category or Bonus landing plays its
             sub-wheel before the result banner. Autospin (app.js state)
             and bulk modes (wheelMulti sets CPS.wheel._noSub) skip it. */
          var lastHop = hops[hops.length - 1];
          var A = CPS.appCtx;
          var isAuto = !!(A && A.S && A.S.autospin);
          if (lastHop && !CPS.wheel._noSub && !isAuto &&
              (lastHop.kind === 'category' || lastHop.kind === 'bonus')) {
            openSubWheel(cfg, lastHop, function () { resolve(last); });
          } else {
            resolve(last);
          }
          return;
        }
        var hop = hops[i++];
        var wheel = byId[hop.wheel] || cfg.wheels[0];
        var nameEl = document.getElementById('wheelName');
        if (nameEl) nameEl.textContent = wheel.name;
        var fr = first ? (canvas._rot || 0) : 0;
        first = false;
        draw(canvas, wheel, fr);
        setTimeout(function () {
          spinTo(canvas, wheel, hop.key, fr, 3600 / speed, function () {
            last = { wheelId: wheel.id, key: hop.key, rotation: canvas._rot || 0 };
            setTimeout(next, 1100 / speed);
          });
        }, 400 / speed);
      }
      next();
    });
  }

  /* --- Sub-wheel (migration 176 presentation): a popup wheel that spins
     to the SERVER-DECIDED outcome of a category or Bonus landing. It never
     re-rolls: the winner index is fixed by the hop's prize fields before
     the animation starts. Single spins only (see playHops). --- */
  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape' && subEls && subEls.ov.style.display !== 'none') subOverlayExit();
  });
  var subEls = null;
  function ensureSubEls() {
    if (subEls) return subEls;
    if (!document.getElementById('subwheelCss')) {
      var st = document.createElement('style');
      st.id = 'subwheelCss';
      st.textContent =
        '.subwheel-overlay{position:fixed;inset:0;background:rgba(10,6,20,.8);display:flex;align-items:center;justify-content:center;z-index:9999;padding:16px}' +
        '.subwheel-box{background:#1f1930;border:2px solid #ffb020;border-radius:18px;padding:18px;text-align:center;max-width:450px;width:100%;box-shadow:0 18px 50px rgba(0,0,0,.6);color:#f3eefc;font-family:system-ui,-apple-system,sans-serif}' +
        '.subwheel-box h3{margin:0 0 2px;font-size:20px}' +
        '.subwheel-stage{position:relative;width:min(100%,340px);margin:10px auto 4px}' +
        '.subwheel-stage canvas{width:100%;height:auto;display:block}' +
        '.subwheel-pointer{position:absolute;left:50%;top:-6px;transform:translateX(-50%);color:#ffb020;font-size:27px;z-index:3;text-shadow:0 2px 6px rgba(0,0,0,.6)}' +
        '.subwheel-result{font-size:16px;min-height:25px;margin-top:8px}' +
        '.subwheel-btn{margin-top:10px;background:linear-gradient(180deg,#ffc44d,#ffb020);color:#231600;border:none;border-radius:10px;padding:10px 34px;font-size:15px;font-weight:800;cursor:pointer}' +
        '.subwheel-btn:disabled{opacity:.45;cursor:default}';
      document.head.appendChild(st);
    }
    var ov = document.createElement('div');
    ov.className = 'subwheel-overlay';
    ov.innerHTML = '<div class="subwheel-box"><h3></h3>' +
      '<div class="subwheel-stage"><div class="subwheel-pointer">\u25BC</div>' +
      '<canvas width="520" height="520"></canvas></div>' +
      '<div class="subwheel-result">Spinning\u2026</div>' +
      '<button class="subwheel-btn" disabled>Nice!</button></div>';
    ov.style.display = 'none';
    ov.addEventListener('click', function (e) { if (e.target === ov) subOverlayExit(); });
    document.body.appendChild(ov);
    subEls = {
      ov: ov,
      title: ov.querySelector('h3'),
      canvas: ov.querySelector('canvas'),
      result: ov.querySelector('.subwheel-result'),
      btn: ov.querySelector('.subwheel-btn')
    };
    return subEls;
  }

  function drawSubFace(items, rot) {
    var cv = subEls.canvas, ctx = cv.getContext('2d');
    var S = cv.width, C = S / 2, R = C - 6, n = items.length;
    ctx.clearRect(0, 0, S, S);
    items.forEach(function (it, idx) {
      var a0 = rot + (idx / n) * TAU - Math.PI / 2;
      var a1 = a0 + TAU / n;
      ctx.beginPath(); ctx.moveTo(C, C); ctx.arc(C, C, R, a0, a1); ctx.closePath();
      ctx.fillStyle = it.color; ctx.fill();
      ctx.strokeStyle = 'rgba(0,0,0,.4)'; ctx.lineWidth = 3; ctx.stroke();
      var mid = (a0 + a1) / 2;
      ctx.save(); ctx.translate(C, C); ctx.rotate(mid);
      ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
      ctx.font = Math.round(R * 0.11) + 'px "Apple Color Emoji", "Noto Color Emoji", "Segoe UI Emoji", sans-serif';
      ctx.shadowColor = 'rgba(0,0,0,.65)'; ctx.shadowBlur = 0;
      ctx.fillText(it.icon || '🎁', R * 0.84, 0);
      ctx.save(); ctx.translate(R * 0.52, 0);
      ctx.font = '700 14px system-ui, -apple-system, sans-serif';
      ctx.fillStyle = '#fff'; ctx.shadowBlur = 4;
      var words = String(it.label).split(' '), lines = [], line = '';
      words.forEach(function (wd) {
        var t = line ? line + ' ' + wd : wd;
        if (ctx.measureText(t).width > 120 && line) { lines.push(line); line = wd; } else line = t;
      });
      if (line) lines.push(line);
      lines.forEach(function (l, li) { ctx.fillText(l, 0, (li - (lines.length - 1) / 2) * 16); });
      ctx.restore(); ctx.restore();
    });
    ctx.beginPath(); ctx.arc(C, C, R, 0, TAU);
    ctx.strokeStyle = '#ffb020'; ctx.lineWidth = 5; ctx.stroke();
    ctx.beginPath(); ctx.arc(C, C, 30, 0, TAU);
    ctx.fillStyle = '#1c1c28'; ctx.fill();
    ctx.strokeStyle = '#ffb020'; ctx.lineWidth = 3; ctx.stroke();
    ctx.fillStyle = '#ffb020'; ctx.font = '700 18px system-ui, sans-serif';
    ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    ctx.fillText('★', C, C + 1);
  }

  function spinSubTo(items, winIdx, done) {
    var n = items.length;
    var frac = (winIdx + 0.25 + Math.random() * 0.5) / n;
    var targetRot = TAU * 5 + (TAU - frac * TAU);
    var from = 0, t0 = null, lastIdx = -1;
    function frame(t) {
      if (t0 === null) t0 = t;
      var pr = subSkip ? 1 : Math.min(1, (t - t0) / 3000);
      var e = 1 - Math.pow(1 - pr, 4);
      var rot = from + (targetRot - from) * e;
      var ptrLocal = ((-rot % TAU) + TAU) % TAU;
      var idx = Math.min(n - 1, Math.floor(ptrLocal / (TAU / n)));
      if (lastIdx >= 0 && idx !== lastIdx && CPS.audio && CPS.audio.tick) CPS.audio.tick();
      lastIdx = idx;
      drawSubFace(items, rot);
      if (pr < 1) requestAnimationFrame(frame); else done();
    }
    requestAnimationFrame(frame);
  }

  /* Backdrop tap / Escape on the sub-wheel overlay: while it is still
     spinning, fast-forward the animation to its result; once the
     result is showing, act exactly like the Nice! button. Everywhere
     else in the app X / backdrop / Escape always works — this overlay
     was the one exception. */
  var subSkip = false;
  function subOverlayExit() {
    var els = ensureSubEls();
    if (els.ov.style.display === 'none') return;
    if (els.btn.disabled) { subSkip = true; return; }
    if (els.btn.onclick) els.btn.onclick();
  }

  /* Build the sub-wheel for a terminal hop and play it. done() fires when
     the player taps Nice! (or immediately, if anything is missing). */
  function openSubWheel(cfg, hop, done) {
    var wheel = null, seg = null;
    (cfg.wheels || []).forEach(function (w) { if (w.id === hop.wheel) wheel = w; });
    if (wheel) (wheel.segments || []).forEach(function (sg) { if (sg.key === hop.key) seg = sg; });
    if (!seg) { done(); return; }
    var items = null, winIdx = -1, title = '';
    if (hop.kind === 'category') {
      var sets = seg.sets || [];
      var base = seg.color || '#888';
      items = sets.map(function (sid, idx) {
        return { label: setName(sid), icon: setEmblem(sid), color: shade(base, idx % 2 ? -30 : 16) };
      });
      winIdx = sets.indexOf(hop.prize_set_id);
      title = (seg.icon || '') + ' ' + (seg.category ? (function () { for (var i = 0; i < CATEGORIES.length; i++) if (CATEGORIES[i].key === seg.category) return CATEGORIES[i].name; return seg.label; })() : seg.label) + ' — which set?';
    } else if (hop.kind === 'bonus') {
      var widx = hop.wheel === 'w1' ? 0 : hop.wheel === 'w2' ? 1 : 2;
      items = BONUS_PRIZES.map(function (b) {
        return { label: b.label(b.amounts[widx]), icon: b.icon, color: b.color, bp: b.bp };
      });
      items.forEach(function (it, idx) { if (it.bp === hop.bonus_prize) winIdx = idx; });
      title = '⭐ BONUS — which prize?';
    }
    if (!items || !items.length || winIdx < 0) { done(); return; }
    var els = ensureSubEls();
    subSkip = false;
    els.title.textContent = title;
    els.result.textContent = 'Spinning…';
    els.btn.disabled = true;
    els.ov.style.display = 'flex';
    drawSubFace(items, 0);
    spinSubTo(items, winIdx, function () {
      var it = items[winIdx];
      els.result.innerHTML = 'You got <b>' + escHtml(it.label) + '</b>';
      els.btn.disabled = false;
      els.btn.onclick = function () {
        els.ov.style.display = 'none';
        els.btn.onclick = null;
        done();
      };
    });
  }

  function escHtml(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  /* Result banner HTML for a spin prize. */
  function prizeHtml(prize, setName) {
    if (prize && prize.kind === 'tickets') {
      var tk = prize.tickets || 0;
      return '🎉 You won <b>' + tk + ' Spin Ticket' + (tk === 1 ? '' : 's') + '</b>!';
    }
    if (prize && prize.kind === 'random_packs') {
      var bySet = prize.packs_by_set || {};
      var parts = Object.keys(bySet).sort().map(function (sid) {
        var st = null;
        try { st = window.CardSets && window.CardSets.get(sid); } catch (e) {}
        var nm = sid === 'jumbled' ? 'Jumbled Mess' : ((st && st.name) || sid);
        return escHtml(nm) + (bySet[sid] > 1 ? ' ×' + bySet[sid] : '');
      });
      return '🎉 <b>BONUS!</b> You won <b>' + (prize.packs || 0) + ' Random Packs</b>' +
        (parts.length ? '<br>' + parts.join(' · ') : '') + '!';
    }
    if (prize && prize.bonus && prize.kind === 'packs') {
      return '🎉 <b>BONUS!</b> You won <b>' + (prize.packs || 0) + ' Jumbled Mess pack' + (prize.packs === 1 ? '' : 's') + '</b>!';
    }
    if (prize && prize.kind === 'tokens') {
      var n = prize.tokens || 0;
      return '🎉 You won <b>' + n + ' Arcade token' + (n === 1 ? '' : 's') + '</b>!';
    }
    if (prize && prize.kind === 'credit') {
      var c = prize.credit || 0;
      return '🎉 You won <b>$' + c + ' Store Credit</b>!';
    }
    var pname = setName || (prize && prize.set_id) || 'packs';
    var pwon = (prize && prize.packs) || 0;
    return '🎉 You won <b>' + pwon + ' ' + escHtml(pname) + ' pack' + (pwon === 1 ? '' : 's') + '</b>!';
  }

  CPS.wheel = {
    enrich: enrich,
    localConfig: localConfig,
    draw: draw,
    spinTo: spinTo,
    playHops: playHops,
    prizeHtml: prizeHtml,
    startIdle: startIdle,
    stopIdle: stopIdle
  };
})(window.CPS);

/* --- SPIN xN (migration 128): one server call simulates N spins
   (x5 / x10 buttons); the wheel plays ONE visual spin (the last
   result's hop chain), then a summary popup lists everything won.
   State lives in app.js; this module drives it through CPS.appCtx
   like the other feature modules.
   SPIN ALL (migration 162) rides the same call: startAll passes the
   whole ticket balance and the server clamp (1000) does the rest. */
(function (CPS) {
  function start(count) {
    count = count || 10;
    var A = CPS.appCtx; if (!A) return;
    var S = A.S;
    if (S.spinning || S.autospin || A.isLocked()) return;
    if (A.spinCount() < count) { A.toast('Multi-spin needs ' + count + ' spin tickets.', 'warn'); A.audio.error(); return; }
    var cfg = S._wheelCfg || A.wheelConfig();
    if (!cfg || !cfg.wheels.length) { A.toast("The wheel isn't ready yet.", 'warn'); return; }
    S.spinning = true;
    S._wheelEnd = null;
    CPS.wheel._noSub = true; /* bulk modes never play sub-wheels */
    CPS.wheel.draw(document.getElementById('wheelCanvas'), cfg.wheels[0], 0);
    var nm = document.getElementById('wheelName'); if (nm) nm.textContent = cfg.wheels[0].name;
    A.renderWheel();
    CPS.wheel.startIdle(document.getElementById('wheelCanvas'), cfg.wheels[0]);
    CPS.cloud.call('spin_wheel_multi', { p_count: count }).then(function (out) {
      S.spins = out.spins_left;
      A.refreshQuests();
      A.renderWheel();
      var pn = out.packs_now || {};
      Object.keys(pn).forEach(function (sid) { var st = window.CardSets.get(sid); if (st) A.ps(st).packs = pn[sid]; });
      if (out.tokens_won > 0 && CPS.games) CPS.games.setTokens(out.tokens_now);
      var results = out.results || [], last = results[results.length - 1] || {};
      return CPS.wheel.playHops(document.getElementById('wheelCanvas'), cfg, last.hops || [], 1).then(function (endState) {
        var prize = last.prize || {}, isTok = prize.kind === 'tokens', isCred = prize.kind === 'credit';
        var pset = !isTok && !isCred && prize.set_id ? window.CardSets.get(prize.set_id) : null;
        if (endState) S._wheelEnd = { wheelId: endState.wheelId, key: endState.key, rot: endState.rotation, resultHtml: CPS.wheel.prizeHtml(prize, pset && pset.name) };
        A.audio.coin();
        CPS.wheel._noSub = false;
        S.spinning = false;
        A.renderWheel();
        A.renderPacksSide();
        showResults(out, count);
      });
    }).catch(function (e) { CPS.wheel.stopIdle(document.getElementById('wheelCanvas')); CPS.wheel._noSub = false; S.spinning = false; A.renderWheel(); A.cloudError(e); });
  }
  /* Autospin tally (called from app.js doOneSpin per spin): counts every
     prize kind the wheel can return, including Bonus 'tickets' and
     'random_packs' (which expand per set), so showSummary lists them. */
  function addPrize(A, prize) {
    if (!A || !prize) return;
    A.n = (A.n || 0) + 1;
    if (prize.kind === 'tokens') A.tokens = (A.tokens || 0) + (prize.tokens || 0);
    else if (prize.kind === 'credit') A.credit = (A.credit || 0) + (prize.credit || 0);
    else if (prize.kind === 'tickets') A.tickets = (A.tickets || 0) + (prize.tickets || 0);
    else if (prize.kind === 'random_packs' && prize.packs_by_set) Object.keys(prize.packs_by_set).forEach(function (sid) { A.bySet[sid] = (A.bySet[sid] || 0) + (prize.packs_by_set[sid] || 0); });
    else if (prize.set_id) A.bySet[prize.set_id] = (A.bySet[prize.set_id] || 0) + (prize.packs || 0);
  }
  /* Shared prize-summary popup: SPIN x10 passes its server aggregate,
     AUTOSPIN passes the tally it accumulated in app.js (S._autoAgg). */
  function showSummary(agg) {
    var A = CPS.appCtx, bySet = agg.bySet || {}, rows = '';
    Object.keys(bySet).sort().forEach(function (sid) {
      var st = window.CardSets.get(sid) || (sid === 'jumbled' && CPS.jumbled ? CPS.jumbled.pseudoSet() : null);
      rows += '<div class="multi-row"><span>' + (sid === 'jumbled' ? '🎲 ' : ((st && st.pack && st.pack.emblem) || '🎁') + ' ') + A.esc(st ? st.name : sid) + ' packs</span><b>×' + bySet[sid] + '</b></div>';
    });
    if (agg.tickets > 0) rows += '<div class="multi-row"><span>🎟️ Spin Tickets</span><b>×' + agg.tickets + '</b></div>';
    if (agg.tokens > 0) rows += '<div class="multi-row"><span>🪙 Arcade tokens</span><b>×' + agg.tokens + '</b></div>';
    if (agg.credit > 0) rows += '<div class="multi-row"><span>💵 Store Credit</span><b>$' + agg.credit + '</b></div>';
    if (!rows) rows = '<div class="multi-row"><span>No prizes this time.</span></div>';
    A.openModal('<button class="modal-x" data-close aria-label="Close">×</button>' +
      '<div class="multi-results"><h3>🎉 ' + agg.n + ' spins — you got:</h3>' + rows +
      '<button class="btn primary" data-close style="margin-top:16px">Nice!</button></div>');
  }
  function showResults(out, count) {
    showSummary({ n: out.spins_used || count || 10, bySet: out.packs_by_set || {}, tokens: out.tokens_won || 0, credit: out.credit_won || 0, tickets: out.tickets_won || 0 });
  }
  /* SPIN ALL: one multi call for the whole balance (server clamps at
     1000 per migration 162; on a pre-162 server it harmlessly spins
     10 and the summary reports the server's spins_used). */
  function startAll() {
    var A = CPS.appCtx; if (!A) return;
    var n = A.spinCount();
    if (n < 2) { A.toast('Spin All needs at least 2 spin tickets.', 'warn'); A.audio.error(); return; }
    start(Math.min(n, 1000));
  }
  CPS.wheelMulti = { start: start, startAll: startAll, showSummary: showSummary, addPrize: addPrize };
})(window.CPS);

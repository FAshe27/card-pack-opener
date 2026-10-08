/* Prize wheel: canvas rendering + spin animation.
   The wheel STRUCTURE (tiers / weights / gateways) mirrors
   supabase/migrations/003_wheel.sql (cps.wheel_config). KEEP IN SYNC.
   Segments are generated from the live set list, so newly added sets appear
   on all wheels automatically with no adjustments. */
(function (CPS) {
  var TAU = Math.PI * 2;

  /* Static, set-agnostic structure. Resolved against a set list by localConfig(). */
  var STRUCTURE = [
    { id: 'w1', name: 'Prize Wheel',  tiers: [{ packs: 1, weight: 3 }, { goto: 'w2', label: 'Go to second wheel', weight: 1 }] },
    { id: 'w2', name: 'Double Wheel', tiers: [{ packs: 2, weight: 2 }, { goto: 'w1', label: 'Back to first wheel', weight: 2 }, { goto: 'w3', label: 'Go to third wheel', weight: 1 }] },
    { id: 'w3', name: 'Triple Wheel', tiers: [{ packs: 3, weight: 2 }, { goto: 'w1', label: 'Back to first wheel', weight: 1 }, { goto: 'w2', label: 'Back to second wheel', weight: 1 }] }
  ];

  var GOTO_COLORS = { w1: '#8e6cc9', w2: '#ffb21e', w3: '#ff5d5d' };
  var FALLBACK = ['#3f8cff', '#38c97f', '#b35cff', '#ff7a59', '#ffb21e', '#ff4fa3', '#2dd4bf', '#f472b6'];

  function setColor(setId, i) {
    try {
      var s = window.CardSets && window.CardSets.get(setId);
      if (s && s.theme && s.theme.primary) return s.theme.primary;
    } catch (e) {}
    return FALLBACK[i % FALLBACK.length];
  }

  function setName(setId) {
    try {
      var s = window.CardSets && window.CardSets.get(setId);
      if (s && s.name) return s.name;
    } catch (e) {}
    return setId;
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
              weight: sg.weight, wheel: sg.wheel || null,
              label: sg.label || ''
            };
            if (sg.kind === 'packs') {
              out.label = sg.packs + ' × ' + setName(sg.set_id);
              out.color = setColor(sg.set_id, i++);
            } else {
              out.color = GOTO_COLORS[sg.wheel] || '#999';
            }
            return out;
          })
        };
      })
    };
  }

  /* Guest-mode config: same structure, resolved against the client's set list. */
  function localConfig() {
    var sets = ((window.CardSets && window.CardSets.all()) || []).slice()
      .sort(function (a, b) { return a.id < b.id ? -1 : a.id > b.id ? 1 : 0; });
    return enrich({
      wheels: STRUCTURE.map(function (w) {
        var segs = [];
        w.tiers.forEach(function (t) {
          if (t.packs) {
            sets.forEach(function (s) {
              segs.push({ key: 'packs:' + s.id, kind: 'packs', set_id: s.id, packs: t.packs, weight: t.weight });
            });
          } else {
            segs.push({ key: 'goto:' + t.goto, kind: 'goto', wheel: t.goto, label: t.label, weight: t.weight });
          }
        });
        return { id: w.id, name: w.name, segments: segs };
      })
    });
  }

  /* Guest-mode roll: mirrors cps.roll_wheel(). Returns {hops, prize}. */
  function rollLocal(cfg) {
    var byId = {}, hops = [], wid = 'w1', guard = 0, prize = null;
    cfg.wheels.forEach(function (w) { byId[w.id] = w; });
    while (guard++ < 25) {
      var wheel = byId[wid];
      if (!wheel) break;
      var total = wheel.segments.reduce(function (a, s) { return a + s.weight; }, 0);
      if (total <= 0) break;
      var r = Math.random() * total, acc = 0, seg = null;
      for (var i = 0; i < wheel.segments.length; i++) {
        acc += wheel.segments[i].weight;
        if (r < acc) { seg = wheel.segments[i]; break; }
      }
      if (!seg) break;
      hops.push({ wheel: wid, key: seg.key, kind: seg.kind, set_id: seg.set_id, packs: seg.packs, label: seg.label });
      if (seg.kind === 'packs') { prize = { set_id: seg.set_id, packs: seg.packs }; break; }
      wid = seg.wheel;
    }
    return { hops: hops, prize: prize };
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

  function draw(canvas, wheel, rotation, highlightKey) {
    var ctx = canvas.getContext('2d');
    var W = canvas.width, H = canvas.height, cx = W / 2, cy = H / 2;
    var R = Math.min(W, H) / 2 - 10;
    ctx.clearRect(0, 0, W, H);
    var segs = wheel.segments;
    var total = segs.reduce(function (a, s) { return a + s.weight; }, 0) || 1;
    var acc = 0;
    segs.forEach(function (sg) {
      var a0 = rotation + (acc / total) * TAU - Math.PI / 2;
      acc += sg.weight;
      var a1 = rotation + (acc / total) * TAU - Math.PI / 2;
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
      ctx.textAlign = 'right';
      ctx.textBaseline = 'middle';
      ctx.font = '700 15px system-ui, -apple-system, sans-serif';
      ctx.shadowColor = 'rgba(0,0,0,.65)';
      ctx.shadowBlur = 5;
      ctx.fillStyle = '#fff';
      ctx.fillText(sg.label, R - 16, 0, R - 70);
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
    ctx.fillText('★', cx, cy + 1);
    if (highlightKey) {
      var sp = segSpan(wheel, highlightKey);
      var ha0 = rotation + sp.a0 - Math.PI / 2, ha1 = rotation + sp.a1 - Math.PI / 2;
      ctx.beginPath();
      ctx.moveTo(cx, cy);
      ctx.arc(cx, cy, R, ha0, ha1);
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
  function spinTo(canvas, wheel, key, fromRot, durationMs, done) {
    var sp = segSpan(wheel, key);
    var targetLocal = sp.a0 + (sp.a1 - sp.a0) * (0.2 + 0.6 * Math.random());
    var want = -targetLocal; /* rotation that puts targetLocal at the top */
    var cur = ((fromRot % TAU) + TAU) % TAU;
    var delta = (((want - cur) % TAU) + TAU) % TAU;
    var turns = 5 + Math.floor(Math.random() * 3);
    var finalRot = fromRot + turns * TAU + delta;
    var t0 = null;
    function frame(t) {
      if (t0 === null) t0 = t;
      var p = Math.min(1, (t - t0) / durationMs);
      var e = 1 - Math.pow(1 - p, 3); /* easeOutCubic */
      draw(canvas, wheel, fromRot + (finalRot - fromRot) * e);
      if (p < 1) requestAnimationFrame(frame);
      else { canvas._rot = ((finalRot % TAU) + TAU) % TAU; if (done) done(); }
    }
    requestAnimationFrame(frame);
  }

  /* Play a server-rolled hop chain, one wheel at a time. Returns a promise. */
  function playHops(canvas, cfg, hops) {
    return new Promise(function (resolve) {
      var byId = {};
      cfg.wheels.forEach(function (w) { byId[w.id] = w; });
      var i = 0, last = null;
      function next() {
        if (i >= hops.length) { resolve(last); return; }
        var hop = hops[i++];
        var wheel = byId[hop.wheel] || cfg.wheels[0];
        var nameEl = document.getElementById('wheelName');
        if (nameEl) nameEl.textContent = wheel.name;
        draw(canvas, wheel, 0);
        setTimeout(function () {
          spinTo(canvas, wheel, hop.key, 0, 3600, function () {
            last = { wheelId: wheel.id, key: hop.key, rotation: canvas._rot || 0 };
            setTimeout(next, 1100);
          });
        }, 400);
      }
      next();
    });
  }

  CPS.wheel = {
    enrich: enrich,
    localConfig: localConfig,
    rollLocal: rollLocal,
    draw: draw,
    spinTo: spinTo,
    playHops: playHops
  };
})(window.CPS);

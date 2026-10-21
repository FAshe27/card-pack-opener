/* Visual effects: particle bursts, confetti, screen flashes, banners. */
(function (CPS) {
  var cv, cx, parts = [], running = false;
  var reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  function ensure() {
    if (cv) return;
    cv = document.createElement('canvas'); cv.className = 'fx-canvas'; document.body.appendChild(cv);
    cx = cv.getContext('2d'); resize(); window.addEventListener('resize', resize);
  }
  function resize() {
    var d = Math.min(window.devicePixelRatio || 1, 2); /* cap at 2: a full-screen canvas at iPhone DPR 3 over a blurred modal saturates iOS Safari */
    cv.width = innerWidth * d; cv.height = innerHeight * d; cx.setTransform(d, 0, 0, d, 0, 0);
  }
  function step() {
    cx.clearRect(0, 0, innerWidth, innerHeight);
    parts = parts.filter(function (p) { return p.life > 0; });
    parts.forEach(function (p) {
      p.life--; p.vx *= p.drag; p.vy = p.vy * p.drag + p.g; p.x += p.vx; p.y += p.vy; p.rot += p.vr;
      var a = Math.min(1, p.life / 25);
      cx.globalAlpha = a; cx.fillStyle = p.c;
      if (p.shape === 'confetti') {
        cx.save(); cx.translate(p.x, p.y); cx.rotate(p.rot); cx.fillRect(-p.s, -p.s / 2, p.s * 2, p.s); cx.restore();
      } else if (p.shape === 'star') {
        cx.save(); cx.translate(p.x, p.y); cx.rotate(p.rot); cx.beginPath();
        for (var i = 0; i < 4; i++) { cx.rotate(Math.PI / 2); cx.lineTo(0, p.s * 2.4); cx.lineTo(p.s * 0.5, p.s * 0.5); }
        cx.closePath(); cx.fill(); cx.restore();
      } else { cx.beginPath(); cx.arc(p.x, p.y, p.s, 0, Math.PI * 2); cx.fill(); }
    });
    cx.globalAlpha = 1;
    if (parts.length) requestAnimationFrame(step); else { running = false; cx.clearRect(0, 0, innerWidth, innerHeight); }
  }
  function go() { if (!running) { running = true; requestAnimationFrame(step); } }
  function burst(x, y, o) {
    if (reduce) return; ensure(); o = o || {};
    /* Bursts share the confetti ceiling: a reveal can fire half a dozen
       of them at once (one per good flip), and uncapped stacks are the
       same iOS freeze pressure the ceiling exists to stop. */
    var room = 450 - parts.length; if (room <= 0) return;
    var colors = o.colors || ['#fff'], n = Math.min(o.count || 40, room);
    for (var i = 0; i < n; i++) {
      var ang = Math.random() * Math.PI * 2, sp = (o.speed || 6) * (0.4 + Math.random() * 0.8);
      parts.push({ x: x, y: y, vx: Math.cos(ang) * sp, vy: Math.sin(ang) * sp, g: o.gravity == null ? 0.12 : o.gravity,
        drag: 0.96, life: (o.life || 55) * (0.6 + Math.random() * 0.6), s: (o.size || 3) * (0.5 + Math.random()),
        c: colors[i % colors.length], shape: o.shape || 'dot', rot: Math.random() * 6, vr: (Math.random() - 0.5) * 0.3 });
    }
    go();
  }
  function confetti(n) {
    if (reduce) return; ensure();
    var room = 450 - parts.length; /* celebrations never stack past ~450 particles total: two pop-ups firing together (260 + 300) froze iOS Safari on the first-ever set completion, 2026-10-20 */
    if (room <= 0) return;
    var colors = ['#ff4fa3', '#ffb21e', '#38c97f', '#3f8cff', '#b35cff', '#ffffff', '#12c2e9'];
    for (var i = 0; i < Math.min(n || 180, room); i++) {
      parts.push({ x: Math.random() * innerWidth, y: -20 - Math.random() * innerHeight * 0.5, vx: (Math.random() - 0.5) * 3,
        vy: 2 + Math.random() * 4, g: 0.05, drag: 0.995, life: 200 + Math.random() * 120, s: 4 + Math.random() * 4,
        c: colors[i % colors.length], shape: 'confetti', rot: Math.random() * 6, vr: (Math.random() - 0.5) * 0.4 });
    }
    go();
  }
  function flash(color, ms) {
    var d = document.createElement('div'); d.className = 'screen-flash';
    d.style.setProperty('--flash', color || '#fff'); document.body.appendChild(d);
    setTimeout(function () { d.remove(); }, ms || 900);
  }
  function banner(text, cls, ms) {
    /* Banners share one centered flex-column wrapper so simultaneous
       banners (a slip + a legendary, a hero pack + a chase…) STACK
       instead of rendering on top of each other. */
    var wrap = document.querySelector('.fx-banners');
    if (!wrap) {
      wrap = document.createElement('div'); wrap.className = 'fx-banners';
      document.body.appendChild(wrap);
    }
    var d = document.createElement('div'); d.className = 'fx-banner ' + (cls || '');
    d.innerHTML = '<span>' + CPS.util.esc(text) + '</span>'; wrap.appendChild(d);
    setTimeout(function () {
      d.remove();
      if (!wrap.children.length && wrap.parentNode) wrap.remove();
    }, ms || 2200);
  }
  function center(el) { var r = el.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; }
  CPS.fx = { burst: burst, confetti: confetti, flash: flash, banner: banner, center: center };
})(window.CPS);

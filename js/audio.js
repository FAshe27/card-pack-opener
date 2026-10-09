/* Synthesized sound effects with WebAudio (no audio files). */
(function (CPS) {
  var ctx = null, master = null, noiseBuf = null;
  var api = { enabled: true };
  function ac() {
    if (!api.enabled) return null;
    try {
      if (!ctx) {
        var C = window.AudioContext || window.webkitAudioContext;
        if (!C) return null;
        ctx = new C(); master = ctx.createGain(); master.gain.value = 0.5; master.connect(ctx.destination);
      }
      if (ctx.state === 'suspended') ctx.resume();
      return ctx;
    } catch (e) { return null; }
  }
  function tone(freq, start, dur, o) {
    var c = ac(); if (!c) return; o = o || {};
    var t0 = c.currentTime + start, osc = c.createOscillator(), g = c.createGain();
    osc.type = o.type || 'sine';
    osc.frequency.setValueAtTime(freq, t0);
    if (o.slideTo) osc.frequency.exponentialRampToValueAtTime(o.slideTo, t0 + dur);
    g.gain.setValueAtTime(0.0001, t0);
    g.gain.exponentialRampToValueAtTime(o.gain || 0.15, t0 + 0.012);
    g.gain.exponentialRampToValueAtTime(0.0001, t0 + dur);
    osc.connect(g); g.connect(master); osc.start(t0); osc.stop(t0 + dur + 0.05);
  }
  function noise(start, dur, o) {
    var c = ac(); if (!c) return; o = o || {};
    if (!noiseBuf) {
      noiseBuf = c.createBuffer(1, c.sampleRate, c.sampleRate);
      var d = noiseBuf.getChannelData(0);
      for (var i = 0; i < d.length; i++) d[i] = Math.random() * 2 - 1;
    }
    var t0 = c.currentTime + start, src = c.createBufferSource(), f = c.createBiquadFilter(), g = c.createGain();
    src.buffer = noiseBuf; f.type = 'bandpass'; f.Q.value = o.q || 1;
    f.frequency.setValueAtTime(o.freq || 1500, t0);
    if (o.sweepTo) f.frequency.exponentialRampToValueAtTime(o.sweepTo, t0 + dur);
    g.gain.setValueAtTime(o.gain || 0.3, t0);
    g.gain.exponentialRampToValueAtTime(0.0001, t0 + dur);
    src.connect(f); f.connect(g); g.connect(master); src.start(t0); src.stop(t0 + dur + 0.05);
  }
  function arp(notes, step, o) { notes.forEach(function (n, i) { tone(n, i * step, (o && o.dur) || 0.35, o); }); }

  api.tear = function () {
    noise(0, 0.12, { freq: 900, sweepTo: 3000, q: 0.7, gain: 0.35 });
    noise(0.1, 0.18, { freq: 1500, sweepTo: 5000, q: 0.6, gain: 0.3 });
    noise(0.26, 0.22, { freq: 2500, sweepTo: 7000, q: 0.5, gain: 0.25 });
  };
  api.deal = function () { noise(0, 0.05, { freq: 2500, q: 2, gain: 0.08 }); };
  api.flip = function () { tone(620, 0, 0.07, { type: 'triangle', gain: 0.08, slideTo: 300 }); noise(0, 0.05, { freq: 3000, q: 1, gain: 0.08 }); };
  api.click = function () { tone(440, 0, 0.05, { type: 'square', gain: 0.03 }); };
  api.tick = function () { noise(0, 0.025, { freq: 4200, q: 0.8, gain: 0.045 }); };
  api.reveal = function (rarity) {
    switch (rarity) {
      case 'uncommon': tone(880, 0.02, 0.25, { gain: 0.06 }); break;
      case 'rare': arp([784, 1175], 0.08, { gain: 0.09, dur: 0.4 }); break;
      case 'epic': arp([659, 831, 988, 1319], 0.07, { type: 'triangle', gain: 0.1, dur: 0.5 }); break;
      case 'legendary':
        arp([523, 659, 784, 1047, 1319], 0.08, { type: 'triangle', gain: 0.12, dur: 0.6 });
        tone(262, 0, 1.1, { type: 'sawtooth', gain: 0.04 });
        break;
      case 'chase':
        arp([523, 659, 784, 1047, 784, 1047, 1319, 1568], 0.09, { type: 'square', gain: 0.06, dur: 0.5 });
        [523, 659, 784].forEach(function (f) { tone(f, 0.75, 1.6, { type: 'triangle', gain: 0.07 }); });
        noise(0.75, 1.2, { freq: 6000, q: 0.5, gain: 0.08 });
        break;
    }
  };
  api.coin = function () { arp([988, 1319], 0.08, { type: 'square', gain: 0.05, dur: 0.25 }); };
  api.error = function () { tone(200, 0, 0.2, { type: 'square', gain: 0.05, slideTo: 140 }); };
  CPS.audio = api;
})(window.CPS);

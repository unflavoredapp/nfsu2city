// Generated from voice-src/voice.js (the page-side half of proximity voice).
enum VoiceScript {
    static let source = #"""
/* nfsu2.city proximity voice (runs inside the game page, injected by the app).
 * The server (gate) says who is near and relays WebRTC signaling; audio goes browser to browser.
 * Each voice is placed in 3D by where that car is (Web Audio panner), fades out with distance, and nobody
 * beyond the server's range is connected at all. */
(function () {
  if (window.__voice) return;
  var cfg = window.NFSU2_VOICE || {};
  var V = window.__voice = {};
  var mode = cfg.mode === 'open' ? 'open' : 'ptt', flip = !!cfg.flip;
  var pttDown = false, muted = false, wantOn = true;
  var peers = {};                       // lower-case name -> peer
  var me = null, ice = [], maxPeers = 8, serverOk = false, serverMuted = false;
  var ctx = null, micStream = null, micTrack = null, micAnalyser = null, micLevel = 0, micErr = '', micAsked = false;
  var sigAfter = 0, loopsOn = false, status = '', lastPost = '';
  var calib = { s: [{ c: 0, n: 0 }, { c: 0, n: 0 }], cs: [0, 0], sn: [0, 0], cnt: 0, sign: 1, off: 0, prev: null };
  var myName = String(window.NFSU2_USERNAME || '').toLowerCase();

  function post(force) {
    var sp = [], k;
    for (k in peers) if (peers[k].speaking) sp.push(peers[k].name);
    var self = micTrack && micTrack.enabled && micLevel > 0.02 && !muted;
    var n = 0; for (k in peers) if (peers[k].connected) n++;
    var st = micErr ? micErr : !serverOk ? 'Waiting for free roam' : serverMuted ? 'Muted by admin' : muted ? 'Mic muted' : mode === 'ptt' ? (pttDown ? 'Talking' : 'Hold to talk') : 'Open mic';
    var msg = JSON.stringify({ t: 'state', speaking: sp, self: !!self, peers: n, status: st, mode: mode, muted: muted });
    if (!force && msg === lastPost) return;
    lastPost = msg;
    try { window.webkit.messageHandlers.voice.postMessage(JSON.parse(msg)); } catch (e) {}
  }

  function api(path, opt) {
    opt = opt || {};
    return fetch('/app/voice/' + path, { method: opt.body ? 'POST' : 'GET', credentials: 'same-origin',
      headers: opt.body ? { 'content-type': 'application/json' } : undefined, body: opt.body ? JSON.stringify(opt.body) : undefined })
      .then(function (r) { if (!r.ok) throw new Error('http ' + r.status); return r.json(); });
  }
  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

  /* ---- the microphone ---- */
  function getCtx() {
    if (!ctx) {
      var AC = window.AudioContext || window.webkitAudioContext;
      ctx = new AC({ latencyHint: 'interactive' });
      ctx.listener && setListener();
    }
    if (ctx.state !== 'running') ctx.resume().catch(function () {});
    return ctx;
  }
  function setListener() {
    // the listener stays at the origin looking down -Z; sources are placed relative to the car (placeSource)
    var l = ctx.listener;
    try {
      if (l.positionX) { l.positionX.value = 0; l.positionY.value = 0; l.positionZ.value = 0;
        l.forwardX.value = 0; l.forwardY.value = 0; l.forwardZ.value = -1; l.upX.value = 0; l.upY.value = 1; l.upZ.value = 0; }
      else { l.setPosition(0, 0, 0); l.setOrientation(0, 0, -1, 0, 1, 0); }
    } catch (e) {}
  }
  function getMic() {
    if (micStream || micAsked) return Promise.resolve();
    micAsked = true;
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) { micErr = 'No microphone support'; post(); return Promise.resolve(); }
    return navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: !cfg.raw, noiseSuppression: !cfg.raw, autoGainControl: !cfg.raw, channelCount: 1 } })
      .then(function (s) {
        micStream = s; micTrack = s.getAudioTracks()[0]; micErr = '';
        var c = getCtx(), src = c.createMediaStreamSource(s.clone());   // (a clone made first: its level is read while the sent track is off)
        micTrack.enabled = false;
        micAnalyser = c.createAnalyser(); micAnalyser.fftSize = 512; src.connect(micAnalyser); pull(micAnalyser);
        for (var k in peers) attachMic(peers[k]);
        applyTx(); post();
      })
      .catch(function (e) { micAsked = false; micErr = 'Mic blocked: allow it in Settings'; post(); });
  }
  function pull(an) {          // a silent path to the output, so the meter keeps running on every browser
    var g = getCtx().createGain(); g.gain.value = 0; an.connect(g); g.connect(ctx.destination);
  }
  function level(an) {
    if (!an) return 0;
    var b = an.__b || (an.__b = new Uint8Array(an.fftSize));
    an.getByteTimeDomainData(b);
    var s = 0; for (var i = 0; i < b.length; i++) { var v = (b[i] - 128) / 128; s += v * v; }
    return Math.sqrt(s / b.length);
  }
  var openUntil = 0;
  function applyTx() {
    if (!micTrack) return;
    var on = false;
    if (!muted && !serverMuted && wantOn) {
      if (mode === 'ptt') on = pttDown;
      else { if (micLevel > 0.025) openUntil = Date.now() + 500; on = Date.now() < openUntil; }
    }
    if (micTrack.enabled !== on) micTrack.enabled = on;
  }
  function attachMic(p) {
    if (!micTrack || !p.sender || p.sender.track === micTrack) return;
    p.sender.replaceTrack(micTrack).catch(function () {});
  }

  /* ---- peers ---- */
  function mkPeer(name) {
    var k = name.toLowerCase();
    if (peers[k]) return peers[k];
    var p = { name: name, k: k, polite: myName > k, making: false, ignore: false, connected: false, speaking: false,
      at: Date.now(), lastNear: Date.now(), meet: false, d: 0, pos: null, quiet: 0, hold: 0 };
    var pc = p.pc = new RTCPeerConnection({ iceServers: ice, bundlePolicy: 'max-bundle' });
    var tr = pc.addTransceiver('audio', { direction: 'sendrecv' });
    p.sender = tr.sender;
    attachMic(p);
    pc.onnegotiationneeded = function () {
      p.making = true;
      pc.createOffer().then(function (o) {
        if (pc.signalingState !== 'stable') return;
        return pc.setLocalDescription(o).then(function () { sendSig(p, { d: pc.localDescription }); });
      }).catch(function () {}).then(function () { p.making = false; });
    };
    pc.onicecandidate = function (e) { if (e.candidate) sendSig(p, { c: e.candidate }); };
    pc.oniceconnectionstatechange = function () {
      var s = pc.iceConnectionState;
      p.connected = s === 'connected' || s === 'completed';
      if (s === 'failed') { try { pc.restartIce(); } catch (e) {} }
      if (s === 'closed') drop(k);
      post();
    };
    pc.ontrack = function (e) { if (e.track.kind === 'audio') wireOut(p, e.streams[0] || new MediaStream([e.track])); };
    peers[k] = p;
    return p;
  }
  function wireOut(p, stream) {
    var c = getCtx();
    p.stream = stream;
    try { p.el = new Audio(); p.el.muted = true; p.el.srcObject = stream; p.el.play().catch(function () {}); } catch (e) {}  // keeps the stream flowing
    p.src = c.createMediaStreamSource(stream);
    p.an = c.createAnalyser(); p.an.fftSize = 512;
    p.fade = c.createGain(); p.fade.gain.value = 0;
    p.pan = c.createPanner();
    p.pan.panningModel = 'HRTF'; p.pan.distanceModel = 'exponential'; p.pan.refDistance = 6; p.pan.rolloffFactor = 1.1; p.pan.maxDistance = 200;
    p.src.connect(p.an); pull(p.an); p.src.connect(p.fade); p.fade.connect(p.pan); p.pan.connect(c.destination);
    placeSource(p, true);
  }
  function drop(k) {
    var p = peers[k]; if (!p) return;
    delete peers[k];
    try { p.pc.onicecandidate = p.pc.ontrack = p.pc.onnegotiationneeded = p.pc.oniceconnectionstatechange = null; p.pc.close(); } catch (e) {}
    try { if (p.fade) p.fade.disconnect(); if (p.pan) p.pan.disconnect(); if (p.src) p.src.disconnect(); } catch (e) {}
    try { if (p.el) { p.el.srcObject = null; } } catch (e) {}
    post();
  }
  function sendSig(p, data) {
    api('sig', { body: { to: p.name, data: data } }).catch(function () {});
  }
  function onSig(m) {
    var p = peers[m.from.toLowerCase()];
    if (!p) { if (Object.keys(peers).length >= maxPeers + 2 || !serverOk) return; p = mkPeer(m.from); }
    p.at = Date.now();
    var pc = p.pc, d = m.data || {};
    if (d.d) {
      var desc = d.d, collision = desc.type === 'offer' && (p.making || pc.signalingState !== 'stable');
      p.ignore = !p.polite && collision;
      if (p.ignore) return;
      var step = collision && pc.signalingState === 'have-local-offer'
        ? Promise.all([pc.setLocalDescription({ type: 'rollback' }), pc.setRemoteDescription(desc)])
        : pc.setRemoteDescription(desc);
      step.then(function () {
        if (desc.type !== 'offer') return;
        attachMic(p);
        return pc.createAnswer().then(function (a) { return pc.setLocalDescription(a); }).then(function () { sendSig(p, { d: pc.localDescription }); });
      }).then(function () { limitBitrate(p); }).catch(function () {});
    } else if (d.c) {
      pc.addIceCandidate(d.c).catch(function () { /* ignored offers' candidates */ });
    }
  }
  function limitBitrate(p) {
    try {
      var par = p.sender.getParameters(); if (!par.encodings || !par.encodings.length) par.encodings = [{}];
      par.encodings[0].maxBitrate = 28000;
      p.sender.setParameters(par).catch(function () {});
    } catch (e) {}
  }

  /* ---- where each voice sits ---- */
  function calibrate(m) {
    // learns how the game's heading number maps onto the way the car actually moves (direction and zero point)
    var now = Date.now(), pv = calib.prev;
    calib.prev = { x: m.x, y: m.y, t: now };
    if (!pv || now - pv.t > 1500) return;
    var dx = m.x - pv.x, dy = m.y - pv.y, dt = (now - pv.t) / 1000;
    if (Math.hypot(dx, dy) / dt < 4) return;
    var mv = Math.atan2(dy, dx), th = m.h * Math.PI / 128;
    for (var i = 0; i < 2; i++) {
      var sg = i ? -1 : 1, diff = mv - sg * th;
      calib.cs[i] = calib.cs[i] * 0.97 + Math.cos(diff); calib.sn[i] = calib.sn[i] * 0.97 + Math.sin(diff);
    }
    calib.cnt++;
    var r0 = Math.hypot(calib.cs[0], calib.sn[0]), r1 = Math.hypot(calib.cs[1], calib.sn[1]);
    calib.sign = r1 > r0 ? -1 : 1;
    var i2 = calib.sign === 1 ? 0 : 1;
    calib.off = Math.atan2(calib.sn[i2], calib.cs[i2]);
  }
  function facing(h) { return calib.sign * h * Math.PI / 128 + calib.off; }   // angle on the ground the car faces
  function placeSource(p, snap) {
    if (!p.pan || !me || !p.pos) return;
    var a = facing(me.h), fx = Math.cos(a), fy = Math.sin(a);
    var dx = p.pos.x - me.x, dy = p.pos.y - me.y, dz = p.pos.z - me.z;
    var fwd = dx * fx + dy * fy, right = dx * fy - dy * fx;       // right-handed world: right of (fx,fy) is (fy,-fx)
    if (flip) right = -right;
    var t = ctx.currentTime, tc = snap ? 0.001 : 0.12;
    p.pan.positionX.setTargetAtTime(right, t, tc);
    p.pan.positionY.setTargetAtTime(dz, t, tc);
    p.pan.positionZ.setTargetAtTime(-fwd, t, tc);
    var meet = p.meet;
    p.pan.refDistance = meet ? 14 : 6; p.pan.rolloffFactor = meet ? 0.7 : 1.1;
    var lim = meet ? 55 : 75, f = Math.max(0, Math.min(1, (lim - p.d) / 18));   // fades to nothing before the server drops it
    p.fade.gain.setTargetAtTime(f, t, 0.1);
  }

  /* ---- loops ---- */
  function nearLoop() {
    api('near').then(function (j) {
      serverOk = !!j.ok; serverMuted = !!j.muted; maxPeers = j.max || 8;
      if (j.ice && JSON.stringify(j.ice) !== JSON.stringify(ice)) ice = j.ice;
      var want = {};
      if (serverOk && j.me && wantOn) {
        me = j.me; calibrate(me);
        for (var i = 0; i < j.near.length; i++) {
          var n = j.near[i], k = n.n.toLowerCase(); want[k] = 1;
          var p = peers[k] || mkPeer(n.n);
          p.pos = n; p.d = n.d; p.meet = n.meet; p.lastNear = Date.now();
          placeSource(p, false);
        }
        if (!micAsked) getMic();
        getCtx();
      }
      for (var k2 in peers) if (!want[k2] && Date.now() - peers[k2].lastNear > 4000 && Date.now() - peers[k2].at > 4000) drop(k2);
      post();
    }).catch(function () {}).then(function () { setTimeout(nearLoop, 350); });
  }
  function sigLoop() {
    api('sig?after=' + sigAfter).then(function (j) {
      if (j.last < sigAfter) sigAfter = 0;
      (j.msgs || []).forEach(function (m) { sigAfter = Math.max(sigAfter, m.id); onSig(m); });
      if (!(j.msgs || []).length) sigAfter = Math.max(sigAfter, j.last);
    }).catch(function () { return sleep(2000); }).then(function () { setTimeout(sigLoop, 30); });
  }
  function meterLoop() {
    micLevel = level(micAnalyser);
    applyTx();
    var changed = false;
    for (var k in peers) {
      var p = peers[k], lv = level(p.an), now = Date.now();
      if (lv > 0.02) p.hold = now + 350;
      var sp = now < p.hold && !!p.fade && p.fade.gain.value > 0.03;
      if (sp !== p.speaking) { p.speaking = sp; changed = true; }
    }
    post(changed);
    setTimeout(meterLoop, 120);
  }

  /* ---- called from the app ---- */
  V.ptt = function (down) { pttDown = !!down; if (down && !micAsked) getMic(); applyTx(); post(true); };
  V.setMode = function (m) { mode = m === 'open' ? 'open' : 'ptt'; applyTx(); post(true); };
  V.setMuted = function (m) { muted = !!m; applyTx(); post(true); };
  V.setFlip = function (f) { flip = !!f; for (var k in peers) placeSource(peers[k], true); };
  V.setEnabled = function (on) {
    wantOn = !!on;
    if (!wantOn) { for (var k in peers) drop(k); if (micTrack) micTrack.enabled = false; }
    post(true);
  };
  V.state = function () { return lastPost; };
  V.debug = function () { var o = { ctx: ctx && ctx.state, mic: micLevel, track: micTrack && micTrack.enabled, peers: {} }; for (var k in peers) { var p = peers[k]; o.peers[k] = { lv: level(p.an), gain: p.fade && p.fade.gain.value, d: p.d, ice: p.pc.iceConnectionState, pos: p.pan && [p.pan.positionX.value, p.pan.positionY.value, p.pan.positionZ.value] }; } o.calib = [calib.sign, calib.off, calib.cnt]; return o; };
  nearLoop(); sigLoop(); meterLoop();
  document.addEventListener('visibilitychange', function () { if (ctx && ctx.state !== 'running') ctx.resume().catch(function () {}); });
})();

"""#
}

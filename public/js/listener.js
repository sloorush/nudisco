// Listener page (open on each phone at http://<mac-lan-ip>:PORT/).
// Big "Tap to Join" (mobile autoplay needs a gesture), then receive + play the
// broadcaster's audio. Shows status, volume, estimated latency, reconnect.
//
// House Speaker mode (?house=1, run on the Mac): adds an OUTPUT device picker so
// you can route this tab to your room speakers. Because it rides the same
// WebRTC pipeline, the speakers share (most of) the phones' delay.

import {
  Signal, RTC_CONFIG, configureOpus, preferRed,
  BUFFER_PRESETS, getBufferPref, setBufferPref, PIPELINE_CONST_MS,
  webrtcAvailable, isIOS,
} from './rtc-common.js';

const $ = (id) => document.getElementById(id);
const HOUSE = new URLSearchParams(location.search).has('house');

const els = {
  app: $('app'),
  title: $('title'),
  joinBtn: $('joinBtn'),
  status: $('status'),
  statusDot: $('statusDot'),
  controls: $('controls'),
  volume: $('volume'),
  volNote: $('volNote'),
  latency: $('latency'),
  latencyDetail: $('latencyDetail'),
  reconnectBtn: $('reconnectBtn'),
  resume: $('resume'),
  resumeBtn: $('resumeBtn'),
  outputRow: $('outputRow'),
  outputSelect: $('outputSelect'),
  bufferRow: $('bufferRow'),
  bufferSelect: $('bufferSelect'),
  warn: $('warn'),
  player: $('player'),
};

let signal = null;
let pc = null;
let remoteStream = null;
let audioReceiver = null;          // the live RTCRtpReceiver, so the buffer toggle can retune it
let statsTimer = null;
let reconnectTimer = null;
let connectTimer = null;          // watchdog: armed when DJ is live but no offer has arrived
let pendingCandidates = [];        // remote ICE buffered until setRemoteDescription
let bufferPref = getBufferPref();  // 'smooth' | 'balanced' | 'low'
let manualStop = false;
let joined = false;

// House mode cosmetics.
if (HOUSE) {
  document.body.classList.add('house');
  els.title.textContent = 'House Speaker';
}

// Hard stop early if WebRTC isn't available (usually: plain http on a mobile
// browser that requires a secure context).
if (!webrtcAvailable()) {
  els.joinBtn.disabled = true;
  els.warn.hidden = false;
  els.warn.innerHTML =
    'This browser is blocking WebRTC here. The DJ can switch the server to ' +
    'HTTPS — then reopen the <b>https://</b> version of this URL and trust the ' +
    'certificate.';
}

// ---------------------------------------------------------------------------
// Join
// ---------------------------------------------------------------------------
els.joinBtn.addEventListener('click', join);
els.reconnectBtn.addEventListener('click', () => { teardown(); join(); });
els.resumeBtn.addEventListener('click', () => playAudio());

function join() {
  if (joined) return;
  joined = true;
  manualStop = false;
  els.joinBtn.hidden = true;
  els.controls.hidden = false;
  setStatus('connecting', 'Connecting…');

  // iOS unlocks audio output only inside the user gesture. Calling play() now
  // (even before a stream exists) keeps the element "user-activated" so it plays
  // once srcObject is attached.
  els.player.play().catch(() => {});

  signal = new Signal('listener', { house: HOUSE });
  signal.on('signal', onSignal);
  signal.on('broadcaster-available', () => {
    setStatus('connecting', 'DJ is live — connecting…');
    armConnectWatchdog();
  });
  signal.on('no-broadcaster', () => setStatus('waiting', 'Waiting for the DJ to start…'));
  signal.on('broadcaster-gone', () => {
    setStatus('waiting', 'DJ paused the stream. Waiting…');
    if (connectTimer) { clearTimeout(connectTimer); connectTimer = null; }
    resetPeer();
  });
  signal.on('close', (e) => {
    if (manualStop) return;
    setStatus('error', 'Disconnected. Reconnecting…');
    scheduleReconnect();
  });
  signal.connect();
}

// ---------------------------------------------------------------------------
// Peer connection (listener is the ANSWERER)
// ---------------------------------------------------------------------------
function ensurePC() {
  if (pc) return pc;
  pc = new RTCPeerConnection(RTC_CONFIG);

  pc.ontrack = (e) => {
    remoteStream = e.streams[0] || new MediaStream([e.track]);
    els.player.srcObject = remoteStream;
    audioReceiver = e.receiver;
    applyBuffer(bufferPref);      // size the jitter buffer per the current preset
    playAudio();
  };

  pc.onicecandidate = (e) => {
    if (e.candidate) signal.send({ type: 'signal', to: 'broadcaster', data: { candidate: e.candidate } });
  };

  pc.onconnectionstatechange = () => {
    const s = pc.connectionState;
    if (s === 'connected') setStatus('live', HOUSE ? 'Routing to speakers' : 'Connected — enjoy 🎧');
    else if (s === 'connecting') setStatus('connecting', 'Connecting…');
    else if (s === 'failed') { setStatus('error', 'Connection failed. Reconnecting…'); scheduleReconnect(); }
    else if (s === 'disconnected') setStatus('error', 'Connection unstable…');
  };

  startStatsLoop();
  return pc;
}

async function onSignal(m) {
  const data = m.data;
  try {
    if (data.sdp && data.sdp.type === 'offer') {
      // A fresh offer always means a (possibly brand-new) broadcaster peer — its
      // DTLS fingerprint / ICE creds differ, so never renegotiate onto the old
      // transport. Rebuild clean. (This also sidesteps glare and handles a
      // reloaded/replaced broadcaster re-offering an existing listener.)
      resetPeer();
      ensurePC();
      await pc.setRemoteDescription(data.sdp);
      if (connectTimer) { clearTimeout(connectTimer); connectTimer = null; }
      // Accept RED (redundant audio) on our side too, before answering.
      preferRed(pc.getTransceivers().find((t) => t.receiver && t.receiver.track && t.receiver.track.kind === 'audio'));
      const answer = await pc.createAnswer();
      answer.sdp = configureOpus(answer.sdp);       // request stereo on our side too
      await pc.setLocalDescription(answer);
      signal.send({ type: 'signal', to: 'broadcaster', data: { sdp: pc.localDescription } });
      // Flush ICE that arrived before the remote description was set.
      for (const c of pendingCandidates) {
        try { await pc.addIceCandidate(c); } catch (e) { console.warn('flush ice', e); }
      }
      pendingCandidates = [];
    } else if (data.candidate) {
      if (pc && pc.remoteDescription && pc.remoteDescription.type) {
        await pc.addIceCandidate(data.candidate);
      } else {
        pendingCandidates.push(data.candidate);     // buffer until the offer lands
      }
    }
  } catch (e) {
    console.warn('signal error', e);
  }
}

// ---------------------------------------------------------------------------
// Playback + iOS resume handling
// ---------------------------------------------------------------------------
async function playAudio() {
  try {
    await els.player.play();
    els.resume.hidden = true;
  } catch {
    // Autoplay blocked / backgrounded — surface a tap-to-resume overlay.
    els.resume.hidden = false;
  }
}

// If audio pauses unexpectedly (iOS backgrounding, interruptions), show resume.
els.player.addEventListener('pause', () => {
  // Only a genuine interruption of a LIVE stream (iOS backgrounding, a call)
  // should prompt resume — not our own teardown/reconnect, which also pauses.
  if (joined && !manualStop && pc && pc.connectionState === 'connected') {
    els.resume.hidden = false;
  }
});
els.player.addEventListener('playing', () => { els.resume.hidden = true; });
document.addEventListener('visibilitychange', () => {
  if (!document.hidden && joined && els.player.paused) playAudio();
});

// ---------------------------------------------------------------------------
// Volume
// ---------------------------------------------------------------------------
els.volume.addEventListener('input', () => {
  els.player.volume = parseFloat(els.volume.value);
});
els.player.volume = parseFloat(els.volume.value);
if (isIOS()) {
  // iOS ignores HTMLMediaElement.volume — the slider can't work there.
  els.volNote.hidden = false;
}

// ---------------------------------------------------------------------------
// Buffering (smoothness vs latency) — applied live to the receiver
// ---------------------------------------------------------------------------
function applyBuffer(key) {
  const p = BUFFER_PRESETS[key] || BUFFER_PRESETS.smooth;
  bufferPref = BUFFER_PRESETS[key] ? key : 'smooth';
  setBufferPref(bufferPref);
  if (audioReceiver) {
    // Both are settable any time; no-ops on iOS Safari (it self-manages).
    try { audioReceiver.playoutDelayHint = p.playoutDelayHint; } catch {}
    try { if ('jitterBufferTarget' in audioReceiver) audioReceiver.jitterBufferTarget = p.jitterBufferTarget; } catch {}
  }
}
els.bufferSelect.value = bufferPref;
els.bufferSelect.addEventListener('change', () => applyBuffer(els.bufferSelect.value));

// ---------------------------------------------------------------------------
// Output device picker (House Speaker / desktop Chrome only)
// ---------------------------------------------------------------------------
// Output picker is a desktop/House-mode feature. It needs mediaDevices, which is
// undefined in an insecure context (a phone on plain http) — so guard on it, or
// accessing navigator.mediaDevices.* below throws.
if (navigator.mediaDevices && typeof els.player.setSinkId === 'function') {
  els.outputRow.hidden = false;
  (async () => {
    // enumerateDevices() only reveals output LABELS after a media-permission
    // grant. The listener page never calls getUserMedia, so in House mode do a
    // throwaway capture first — otherwise every option is a generic "Output N"
    // and you can't tell your speakers from BlackHole (which would feed back).
    if (HOUSE) {
      try {
        const tmp = await navigator.mediaDevices.getUserMedia({ audio: true });
        tmp.getTracks().forEach((t) => t.stop());
      } catch { /* labels stay generic; ids still route */ }
    }
    await populateOutputs();
  })();
  navigator.mediaDevices.addEventListener?.('devicechange', populateOutputs);
  els.outputSelect.addEventListener('change', async () => {
    try { await els.player.setSinkId(els.outputSelect.value); }
    catch (e) { console.warn('setSinkId', e); }
  });
}

async function populateOutputs() {
  try {
    const devices = await navigator.mediaDevices.enumerateDevices();
    const outs = devices.filter((d) => d.kind === 'audiooutput');
    const current = els.outputSelect.value;
    els.outputSelect.innerHTML = '';
    for (const d of outs) {
      const opt = document.createElement('option');
      opt.value = d.deviceId;
      // Flag loopback devices: routing House output into BlackHole (or an
      // aggregate that contains it) feeds audio back into the broadcaster's
      // capture, building an escalating feedback loop for everyone.
      const loop = /blackhole|aggregate/i.test(d.label);
      opt.textContent = (d.label || `Output ${els.outputSelect.length + 1}`) +
        (loop ? '  ⚠︎ do not use (feedback)' : '');
      els.outputSelect.appendChild(opt);
    }
    if (current) els.outputSelect.value = current;
  } catch { /* labels need permission; ids still route */ }
}

// ---------------------------------------------------------------------------
// Latency estimate (and report to broadcaster)
// ---------------------------------------------------------------------------
function startStatsLoop() {
  if (statsTimer) clearInterval(statsTimer);
  statsTimer = setInterval(async () => {
    if (!pc || pc.connectionState !== 'connected') return;
    let inbound = null, pair = null;
    try {
      const stats = await pc.getStats();
      stats.forEach((r) => {
        if (r.type === 'inbound-rtp' && r.kind === 'audio') inbound = r;
        if (r.type === 'candidate-pair' && r.state === 'succeeded' &&
            (r.nominated || r.selected)) pair = r;
      });
    } catch { return; }

    const rttMs = pair && pair.currentRoundTripTime != null
      ? pair.currentRoundTripTime * 1000 : null;
    let jbMs = null;
    if (inbound && inbound.jitterBufferEmittedCount) {
      jbMs = (inbound.jitterBufferDelay / inbound.jitterBufferEmittedCount) * 1000;
    }
    const jitterMs = inbound && inbound.jitter != null ? inbound.jitter * 1000 : null;

    // Estimated mouth-to-ear: one-way network + jitter buffer + fixed pipeline.
    // Require the jitter-buffer term (usually dominant) before publishing a
    // number, so a partial first-tick reading can't under-report the latency the
    // broadcaster uses for the recommended speaker delay.
    let est = null;
    if (jbMs != null) {
      est = (rttMs != null ? rttMs / 2 : 0) + jbMs + PIPELINE_CONST_MS;
    }

    if (est != null) {
      els.latency.textContent = Math.round(est) + ' ms';
      els.latencyDetail.textContent =
        `net ~${rttMs != null ? Math.round(rttMs / 2) : '?'} ms · ` +
        `buffer ~${jbMs != null ? Math.round(jbMs) : '?'} ms · ` +
        `jitter ${jitterMs != null ? Math.round(jitterMs) : '?'} ms`;
    }

    signal.send({ type: 'stats', stats: { latencyMs: est, rttMs, jbMs, jitterMs } });
  }, 2000);
}

// ---------------------------------------------------------------------------
// Reconnect / teardown
// ---------------------------------------------------------------------------
// If broadcaster-available arrived but no offer ever did (e.g. the broadcaster's
// offer creation failed), nothing else would retry — connectionState 'failed'
// can't fire before negotiation starts. Watchdog: re-join to retrigger an offer.
function armConnectWatchdog() {
  if (connectTimer) clearTimeout(connectTimer);
  connectTimer = setTimeout(() => {
    connectTimer = null;
    if (!pc || pc.connectionState !== 'connected') scheduleReconnect();
  }, 5000);
}

function scheduleReconnect() {
  if (manualStop || reconnectTimer) return;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    resetPeer();
    if (signal) signal.close();
    signal = null;
    joined = false;
    join();
  }, 1500);
}

function resetPeer() {
  if (statsTimer) { clearInterval(statsTimer); statsTimer = null; }
  if (pc) { try { pc.close(); } catch {} pc = null; }
  remoteStream = null;
  pendingCandidates = [];
  els.player.srcObject = null;     // drop the dead stream so it can't drive UI
  els.resume.hidden = true;        // a 'pause' from this close is not a real stall
}

function teardown() {
  manualStop = true;
  if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
  if (connectTimer) { clearTimeout(connectTimer); connectTimer = null; }
  resetPeer();
  if (signal) { signal.close(); signal = null; }
  joined = false;
}

function setStatus(kind, text) {
  els.status.textContent = text;
  els.statusDot.className = 'dot dot-' + kind;
}

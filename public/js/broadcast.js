// Broadcaster page (open on the Mac at http://localhost:PORT/broadcast).
// Pick the BlackHole input, capture it, and send to every listener via the
// swappable MeshBroadcaster. Shows listener count, level meter, join URL + QR,
// and per-listener latency with a recommended room-speaker delay.

import { Signal, AUDIO } from './rtc-common.js';
import { MeshBroadcaster } from './mesh-broadcaster.js';

const $ = (id) => document.getElementById(id);

const els = {
  enableBtn: $('enableBtn'),
  deviceRow: $('deviceRow'),
  deviceSelect: $('deviceSelect'),
  startBtn: $('startBtn'),
  stopBtn: $('stopBtn'),
  status: $('status'),
  count: $('count'),
  meterFill: $('meterFill'),
  meterPeak: $('meterPeak'),
  joinUrl: $('joinUrl'),
  copyBtn: $('copyBtn'),
  qr: $('qr'),
  houseLink: $('houseLink'),
  latencyBig: $('latencyBig'),
  latencyNote: $('latencyNote'),
  listenerTable: $('listenerTable'),
  listenerBody: $('listenerBody'),
};

let captureStream = null;
let broadcaster = null;
let signal = null;
let audioCtx = null;
let analyser = null;
let meterRAF = null;
const latencyById = new Map();   // id -> { latencyMs, rttMs, jbMs, jitterMs, house, ts }

// ---------------------------------------------------------------------------
// Join URL + QR
// ---------------------------------------------------------------------------
async function loadInfo() {
  try {
    const info = await (await fetch('/api/info')).json();
    els.joinUrl.textContent = info.listenerUrl;
    els.joinUrl.dataset.url = info.listenerUrl;
    els.qr.src = '/qr.svg?text=' + encodeURIComponent(info.listenerUrl);
    els.qr.alt = 'QR code to ' + info.listenerUrl;
    // House Speaker runs on THIS Mac, so point it at localhost (works even if
    // the Mac isn't reachable at its own LAN IP from itself).
    els.houseLink.href = `${location.protocol}//${location.host}/?house=1`;
  } catch {
    els.joinUrl.textContent = '(could not load — is the server running?)';
  }
}

els.copyBtn.addEventListener('click', async () => {
  const url = els.joinUrl.dataset.url;
  if (!url) return;
  try {
    await navigator.clipboard.writeText(url);
    els.copyBtn.textContent = 'copied!';
    setTimeout(() => (els.copyBtn.textContent = 'copy'), 1200);
  } catch { /* clipboard may be blocked; URL is visible anyway */ }
});

// ---------------------------------------------------------------------------
// Step 1: unlock device labels + enumerate inputs
// ---------------------------------------------------------------------------
els.enableBtn.addEventListener('click', async () => {
  els.enableBtn.disabled = true;
  els.enableBtn.textContent = 'requesting access…';
  try {
    // A quick getUserMedia grant is required before enumerateDevices reveals
    // device labels. We stop it immediately; the real capture happens on Start.
    const tmp = await navigator.mediaDevices.getUserMedia({ audio: true });
    tmp.getTracks().forEach((t) => t.stop());
    await populateDevices();
    els.deviceRow.hidden = false;
    els.startBtn.hidden = false;     // reveal Start — without this the DJ can never go on air
    els.enableBtn.hidden = true;
    setStatus('Pick your input (BlackHole 2ch) and press Start.', 'idle');
  } catch (err) {
    els.enableBtn.disabled = false;
    els.enableBtn.textContent = 'Enable & list audio inputs';
    setStatus('Microphone/input access was denied: ' + err.message, 'error');
  }
});

async function populateDevices() {
  const devices = await navigator.mediaDevices.enumerateDevices();
  const inputs = devices.filter((d) => d.kind === 'audioinput');
  els.deviceSelect.innerHTML = '';
  for (const d of inputs) {
    const opt = document.createElement('option');
    opt.value = d.deviceId;
    opt.textContent = d.label || `Input ${els.deviceSelect.length + 1}`;
    if (/blackhole/i.test(d.label)) opt.selected = true; // auto-pick BlackHole
    els.deviceSelect.appendChild(opt);
  }
}

// ---------------------------------------------------------------------------
// Step 2: start / stop broadcasting
// ---------------------------------------------------------------------------
els.startBtn.addEventListener('click', startBroadcast);
els.stopBtn.addEventListener('click', stopBroadcast);

async function startBroadcast() {
  els.startBtn.disabled = true;
  const deviceId = els.deviceSelect.value;
  try {
    captureStream = await navigator.mediaDevices.getUserMedia({
      audio: {
        deviceId: deviceId ? { exact: deviceId } : undefined,
        // Music: every bit of "voice" processing must be OFF.
        echoCancellation: false,
        noiseSuppression: false,
        autoGainControl: false,
        channelCount: 2,
        sampleRate: 48000,
      },
      video: false,
    });
  } catch (err) {
    setStatus('Could not open that input: ' + err.message, 'error');
    els.startBtn.disabled = false;
    return;
  }

  startMeter(captureStream);

  signal = new Signal('broadcaster');
  broadcaster = new MeshBroadcaster({
    signal,
    getStream: () => captureStream,
    onPeerChange: renderListeners,
  });

  signal.on('listener-count', (m) => { els.count.textContent = m.count; });
  signal.on('listener-stats', (m) => {
    latencyById.set(m.id, { ...m.stats, house: m.house, ts: Date.now() });
    renderListeners();
  });
  signal.on('listener-left', (m) => { latencyById.delete(m.id); });
  signal.on('open', () => setStatus('On air — share the URL / QR with guests.', 'live'));
  signal.on('close', (e) => {
    if (e.byUs) return;                  // our own stopBroadcast() — don't fight it
    setStatus('Signaling disconnected. Reconnecting…', 'error');
    if (reconnectTimer) return;
    reconnectTimer = setTimeout(() => {
      reconnectTimer = null;
      if (!signal || !captureStream) return;        // stopped meanwhile
      // Drop dead per-listener PCs so the server's re-announced 'listener-joined'
      // events build FRESH offers (addListener bails on peers.has(id) otherwise).
      if (broadcaster) broadcaster.stop();
      signal.connect();                             // re-hello -> server re-announces listeners
    }, 1500);
  });
  signal.on('replaced', () => {
    stopBroadcast();                     // a 2nd broadcaster won — release device, peers, timers
    setStatus('Another broadcaster took over this session.', 'error');
  });
  signal.connect();

  els.stopBtn.hidden = false;
  els.startBtn.hidden = true;
  els.deviceSelect.disabled = true;

  // Refresh per-peer RTT periodically (broadcaster-side view).
  refreshTimer = setInterval(renderListeners, 2000);
}

let refreshTimer = null;
let reconnectTimer = null;

function stopBroadcast() {
  if (refreshTimer) { clearInterval(refreshTimer); refreshTimer = null; }
  if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
  if (broadcaster) { broadcaster.stop(); broadcaster = null; }
  if (signal) { signal.close(); signal = null; }
  if (captureStream) { captureStream.getTracks().forEach((t) => t.stop()); captureStream = null; }
  stopMeter();
  latencyById.clear();
  renderListeners();
  els.count.textContent = '0';
  els.stopBtn.hidden = true;
  els.startBtn.hidden = false;
  els.startBtn.disabled = false;
  els.deviceSelect.disabled = false;
  setStatus('Stopped.', 'idle');
}

// ---------------------------------------------------------------------------
// Level meter (analyse only — do NOT route to output, that would feed back)
// ---------------------------------------------------------------------------
function startMeter(stream) {
  audioCtx = new (window.AudioContext || window.webkitAudioContext)({ latencyHint: 'interactive' });
  const src = audioCtx.createMediaStreamSource(stream);
  analyser = audioCtx.createAnalyser();
  analyser.fftSize = 1024;
  src.connect(analyser);
  const buf = new Float32Array(analyser.fftSize);
  let peak = 0;
  const draw = () => {
    analyser.getFloatTimeDomainData(buf);
    let sum = 0;
    for (let i = 0; i < buf.length; i++) sum += buf[i] * buf[i];
    const rms = Math.sqrt(sum / buf.length);
    const db = 20 * Math.log10(rms || 1e-7);          // ~ -90 (silence) .. 0
    const pct = Math.max(0, Math.min(100, (db + 60) / 60 * 100)); // map -60..0 dB
    els.meterFill.style.width = pct + '%';
    peak = Math.max(peak * 0.92, pct);
    els.meterPeak.style.left = peak + '%';
    meterRAF = requestAnimationFrame(draw);
  };
  draw();
}

function stopMeter() {
  if (meterRAF) cancelAnimationFrame(meterRAF);
  meterRAF = null;
  if (audioCtx) { audioCtx.close().catch(() => {}); audioCtx = null; }
  els.meterFill.style.width = '0%';
  els.meterPeak.style.left = '0%';
}

// ---------------------------------------------------------------------------
// Listener table + recommended speaker delay
// ---------------------------------------------------------------------------
async function renderListeners() {
  const peerStats = broadcaster ? await broadcaster.getPeerStats() : [];
  const rows = [];
  const phoneLatencies = [];

  for (const p of peerStats) {
    const rep = latencyById.get(p.id);
    const lat = rep && rep.latencyMs != null ? Math.round(rep.latencyMs) : null;
    // Exclude reports older than ~3 cycles so a frozen/backgrounded phone stops
    // skewing the recommended speaker delay (live phones report every 2s).
    const fresh = rep && rep.ts != null && (Date.now() - rep.ts) <= 6000;
    if (lat != null && !p.house && fresh) phoneLatencies.push(lat);
    rows.push({
      id: p.id,
      house: p.house,
      state: p.state || '—',
      lat,
      rtt: rep && rep.rttMs != null ? Math.round(rep.rttMs)
        : (p.rttMs != null ? p.rttMs : null),
      jb: rep && rep.jbMs != null ? Math.round(rep.jbMs) : null,
    });
  }

  els.listenerBody.innerHTML = '';
  if (rows.length === 0) {
    els.listenerTable.hidden = true;
  } else {
    els.listenerTable.hidden = false;
    for (const r of rows) {
      const tr = document.createElement('tr');
      tr.innerHTML = `
        <td>${r.id}${r.house ? ' <span class="badge">house</span>' : ''}</td>
        <td class="st-${r.state}">${r.state}</td>
        <td>${r.lat != null ? r.lat + ' ms' : '—'}</td>
        <td>${r.rtt != null ? r.rtt + ' ms' : '—'}</td>
        <td>${r.jb != null ? r.jb + ' ms' : '—'}</td>`;
      els.listenerBody.appendChild(tr);
    }
  }

  // Recommended room-speaker delay = median phone latency (house outputs excluded
  // because they ride the LAN without the wireless hop).
  if (phoneLatencies.length) {
    phoneLatencies.sort((a, b) => a - b);
    const mid = Math.floor(phoneLatencies.length / 2);
    const median = phoneLatencies.length % 2
      ? phoneLatencies[mid]
      : Math.round((phoneLatencies[mid - 1] + phoneLatencies[mid]) / 2);
    const min = phoneLatencies[0];
    const max = phoneLatencies[phoneLatencies.length - 1];
    els.latencyBig.textContent = median + ' ms';
    els.latencyNote.textContent =
      `median of ${phoneLatencies.length} phone(s) · range ${min}–${max} ms · ` +
      `set your room-speaker delay to ≈ this (Option 2), or use House Speaker mode (Option 1).`;
  } else {
    els.latencyBig.textContent = '— ms';
    els.latencyNote.textContent = 'Waiting for a phone to report latency…';
  }
}

function setStatus(text, kind) {
  els.status.textContent = text;
  els.status.className = 'status status-' + (kind || 'idle');
}

// ---------------------------------------------------------------------------
loadInfo();
setStatus('Press “Enable & list audio inputs”, choose BlackHole, then Start.', 'idle');

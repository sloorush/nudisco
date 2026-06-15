// Shared WebRTC config + helpers for both pages.
//
// Tuning lives here on purpose: change a number in one place and both the
// broadcaster and the listener pick it up. This is the place to nudge if you
// want lower latency vs. fewer dropouts.

// LAN-only. Empty iceServers => host candidates only (the Mac's / phone's LAN
// addresses). No STUN, no TURN, nothing leaves the network.
export const RTC_CONFIG = {
  iceServers: [],
  iceTransportPolicy: 'all',
  bundlePolicy: 'max-bundle',
  rtcpMuxPolicy: 'require',
};

// Opus settings. Stereo music, ~160 kbps, in-band FEC on (cheap insurance
// against Wi-Fi packet loss), DTX off (music is continuous).
export const AUDIO = {
  stereo: true,
  bitrate: 160000,   // bits/sec
  fec: true,
  dtx: false,
  minptime: 10,      // allow 10ms frames; encoder still picks the actual ptime
};

// Receiver-side jitter-buffer presets (listeners). The decoder holds this much
// audio before playout: bigger = smoother under Wi-Fi jitter/loss, but more
// latency. These are Chrome hints (iOS Safari manages its own buffer); the real
// cross-browser smoothness comes from FEC + RED + NACK (see configureOpus /
// preferRed). Default is Smooth — choppiness is worse than a bit more delay, and
// the displayed latency just tells you how much to delay the room speakers.
export const BUFFER_PRESETS = {
  smooth:   { label: 'Smooth',      playoutDelayHint: 0.20, jitterBufferTarget: 200 },
  balanced: { label: 'Balanced',    playoutDelayHint: 0.12, jitterBufferTarget: 120 },
  low:      { label: 'Low latency', playoutDelayHint: 0.04, jitterBufferTarget: 40 },
};
export const DEFAULT_BUFFER = 'smooth';

const BUFFER_KEY = 'nudisco.buffer';
export function getBufferPref() {
  try { const k = localStorage.getItem(BUFFER_KEY); if (k && BUFFER_PRESETS[k]) return k; } catch {}
  return DEFAULT_BUFFER;
}
export function setBufferPref(key) {
  if (!BUFFER_PRESETS[key]) return;
  try { localStorage.setItem(BUFFER_KEY, key); } catch {}
}

// Rough fixed overhead added to the MEASURED network + jitter-buffer delay to
// approximate full mouth-to-ear latency. The jitter-buffer stat only covers
// time-in-buffer BEFORE decode, so this constant must absorb BOTH:
//   - broadcaster: getUserMedia capture buffer + Opus encode framing (~10–25ms)
//   - listener: decode + audio render + OS/hardware OUTPUT buffer (~20–40ms),
//     none of which appear in jitterBufferDelay.
// It intentionally errs LOW; for speaker sync that means the room speakers may
// LEAD the phones (slap/echo). If speakers sound ahead of the phones, nudge the
// room-speaker delay UP. (Does NOT include Bluetooth earbud latency — keep
// guests on WIRED earphones.)
export const PIPELINE_CONST_MS = 48;

export function wsUrl() {
  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  return `${proto}//${location.host}/ws`;
}

// Detect whether WebRTC receive is actually usable in this context. On some
// mobile browsers RTCPeerConnection is gated behind a secure context.
export function webrtcAvailable() {
  return typeof RTCPeerConnection !== 'undefined';
}

export function isIOS() {
  return /iP(hone|od|ad)/.test(navigator.userAgent) ||
    // iPadOS reports as Mac; detect by touch.
    (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
}

// --- SDP munging ----------------------------------------------------------
// There's no JS API to request stereo Opus, so we rewrite the fmtp line.
// Bitrate is also set via RTCRtpSender.setParameters elsewhere; setting
// maxaveragebitrate here too keeps the negotiated ceiling consistent.
export function configureOpus(sdp, opts = AUDIO) {
  const lines = sdp.split(/\r\n/);

  // Find the Opus payload type (rtpmap: <pt> opus/48000/2).
  let pt = null;
  for (const l of lines) {
    const m = l.match(/^a=rtpmap:(\d+)\s+opus\/48000/i);
    if (m) { pt = m[1]; break; }
  }
  if (!pt) return sdp; // no Opus offered — leave SDP untouched

  const params = [
    `minptime=${opts.minptime}`,
    `useinbandfec=${opts.fec ? 1 : 0}`,
    `usedtx=${opts.dtx ? 1 : 0}`,
    `stereo=${opts.stereo ? 1 : 0}`,
    `sprop-stereo=${opts.stereo ? 1 : 0}`,
    `maxaveragebitrate=${opts.bitrate}`,
    `maxplaybackrate=48000`,
  ].join(';');

  const fmtpIdx = lines.findIndex((l) => l.startsWith(`a=fmtp:${pt} `) || l === `a=fmtp:${pt}`);
  if (fmtpIdx >= 0) {
    lines[fmtpIdx] = `a=fmtp:${pt} ${params}`;
  } else {
    const rtpmapIdx = lines.findIndex((l) => l.startsWith(`a=rtpmap:${pt} `));
    lines.splice(rtpmapIdx + 1, 0, `a=fmtp:${pt} ${params}`);
  }

  // Audio NACK: let the receiver request retransmission of lost packets. Cheap
  // and effective on a low-RTT LAN (given enough jitter buffer to wait for the
  // resend). Add `a=rtcp-fb:<pt> nack` for Opus and, if offered, RED.
  let redPt = null;
  for (const l of lines) {
    const m = l.match(/^a=rtpmap:(\d+)\s+red\/48000/i);
    if (m) { redPt = m[1]; break; }
  }
  for (const p of [pt, redPt]) {
    if (!p || lines.includes(`a=rtcp-fb:${p} nack`)) continue;
    const idx = lines.findIndex((l) => l.startsWith(`a=fmtp:${p}`) || l.startsWith(`a=rtpmap:${p} `));
    if (idx >= 0) lines.splice(idx + 1, 0, `a=rtcp-fb:${p} nack`);
  }

  return lines.join('\r\n');
}

// Activate Opus RED (redundant audio) by preferring the `red` codec ahead of
// `opus` on a transceiver — call BEFORE createOffer/createAnswer. RED resends
// recent audio frames inline, so a single lost packet rarely causes a gap. No-op
// where unsupported (older Safari) — falls back to plain Opus + in-band FEC.
export function preferRed(transceiver) {
  try {
    if (!transceiver || typeof transceiver.setCodecPreferences !== 'function') return;
    const caps = RTCRtpReceiver.getCapabilities && RTCRtpReceiver.getCapabilities('audio');
    if (!caps || !caps.codecs) return;
    const isRed = (c) => c.mimeType.toLowerCase() === 'audio/red';
    if (!caps.codecs.some(isRed)) return;                 // RED unavailable — keep default order
    const ordered = [...caps.codecs].sort((a, b) => (isRed(b) ? 1 : 0) - (isRed(a) ? 1 : 0));
    transceiver.setCodecPreferences(ordered);
  } catch { /* some browsers throw on setCodecPreferences — ignore, fall back */ }
}

// --- tiny WebSocket signaling client --------------------------------------
// Event-style wrapper so page code reads as `signal.on('listener-joined', ...)`.
export class Signal {
  constructor(role, { house = false } = {}) {
    this.role = role;
    this.house = house;
    this.ws = null;
    this.id = null;
    this.handlers = {};
    this._closedByUs = false;
  }

  on(type, fn) { (this.handlers[type] ||= []).push(fn); return this; }
  _emit(type, msg) { (this.handlers[type] || []).forEach((fn) => fn(msg)); }

  connect() {
    this._closedByUs = false;
    this.ws = new WebSocket(wsUrl());
    this.ws.onopen = () => {
      this.send({ type: 'hello', role: this.role, house: this.house });
      this._emit('open');
    };
    this.ws.onmessage = (ev) => {
      let m;
      try { m = JSON.parse(ev.data); } catch { return; }
      if (m.type === 'welcome') this.id = m.id;
      this._emit(m.type, m);
    };
    this.ws.onclose = () => this._emit('close', { byUs: this._closedByUs });
    this.ws.onerror = (e) => this._emit('error', e);
  }

  send(obj) {
    if (this.ws && this.ws.readyState === 1) this.ws.send(JSON.stringify(obj));
  }

  close() {
    this._closedByUs = true;
    try { this.ws && this.ws.close(); } catch {}
  }
}

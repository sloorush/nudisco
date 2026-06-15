// ============================================================================
// SWAPPABLE BROADCAST LAYER  —  mesh implementation
// ============================================================================
// The broadcaster opens ONE RTCPeerConnection per listener and sends the same
// captured audio track down each (a one-to-many "mesh"). Encoding happens once
// per connection, so CPU scales with listener count — fine for ~15 listeners on
// a modern Mac, which is what this is sized for.
//
// To scale further (or if the Mac's CPU starts glitching), replace this class
// with an `SfuBroadcaster` that publishes a single stream to a mediasoup SFU and
// have listeners consume from it. Keep the SAME public interface and the rest of
// the app (broadcast.js, the signaling server, the listener) needs no changes:
//
//   new MeshBroadcaster({ signal, getStream, onPeerChange })
//   .count()            -> number of connected listeners
//   .getPeerStats()     -> [{ id, house, state, rttMs }]
//   .stop()             -> tear everything down
//
// It wires itself to these signaling events: listener-joined, listener-left,
// signal. The broadcaster is always the OFFERER (it owns the media).
// ============================================================================

import { RTC_CONFIG, AUDIO, configureOpus, preferRed } from './rtc-common.js';

export class MeshBroadcaster {
  constructor({ signal, getStream, onPeerChange }) {
    this.signal = signal;
    this.getStream = getStream;             // () => MediaStream (the capture)
    this.onPeerChange = onPeerChange || (() => {});
    this.peers = new Map();                  // listenerId -> { pc, house }
    this._wire();
  }

  _wire() {
    this.signal.on('listener-joined', (m) => this.addListener(m.id, m.house));
    this.signal.on('listener-left', (m) => this.removeListener(m.id));
    this.signal.on('signal', (m) => this._onSignal(m.from, m.data));
  }

  async addListener(id, house = false) {
    if (this.peers.has(id)) return;

    const pc = new RTCPeerConnection(RTC_CONFIG);
    const entry = { pc, house: !!house, pending: [] }; // pending: remote ICE buffered until SRD
    this.peers.set(id, entry);

    // Send our captured audio to this listener.
    const stream = this.getStream();
    for (const track of stream.getTracks()) pc.addTrack(track, stream);

    // Prefer RED (redundant audio) on the audio transceiver before offering.
    preferRed(pc.getTransceivers().find((t) => t.sender && t.sender.track && t.sender.track.kind === 'audio'));

    pc.onicecandidate = (e) => {
      if (e.candidate) this.signal.send({ type: 'signal', to: id, data: { candidate: e.candidate } });
    };
    pc.onconnectionstatechange = () => {
      this.onPeerChange();
      if (pc.connectionState === 'failed' || pc.connectionState === 'closed') {
        this.removeListener(id);
      }
    };

    try {
      const offer = await pc.createOffer();
      offer.sdp = configureOpus(offer.sdp, AUDIO);
      await pc.setLocalDescription(offer);
      await this._setBitrate(pc, AUDIO.bitrate);
      this.signal.send({ type: 'signal', to: id, data: { sdp: pc.localDescription } });
    } catch (err) {
      console.error('offer failed for', id, err);
      this.removeListener(id);
    }
    this.onPeerChange();
  }

  async _setBitrate(pc, bitrate) {
    const sender = pc.getSenders().find((s) => s.track && s.track.kind === 'audio');
    if (!sender) return;
    const p = sender.getParameters();
    if (!p.encodings || !p.encodings.length) p.encodings = [{}];
    p.encodings[0].maxBitrate = bitrate;
    // Prioritize getting packets out fast over throughput.
    p.encodings[0].networkPriority = 'high';
    try { await sender.setParameters(p); } catch (e) { console.warn('setParameters', e); }
  }

  async _onSignal(from, data) {
    const entry = this.peers.get(from);
    if (!entry) return;
    const { pc } = entry;
    try {
      if (data.sdp) {
        await pc.setRemoteDescription(data.sdp);  // the listener's answer
        // Flush any ICE candidates that raced ahead of the answer.
        for (const c of entry.pending) {
          try { await pc.addIceCandidate(c); } catch (e) { console.warn('flush ice', from, e); }
        }
        entry.pending = [];
      } else if (data.candidate) {
        if (pc.remoteDescription && pc.remoteDescription.type) {
          await pc.addIceCandidate(data.candidate);
        } else {
          entry.pending.push(data.candidate);     // SRD not applied yet — buffer
        }
      }
    } catch (e) {
      console.warn('signal handling error for', from, e);
    }
  }

  removeListener(id) {
    const entry = this.peers.get(id);
    if (entry) {
      try { entry.pc.close(); } catch {}
      this.peers.delete(id);
      this.onPeerChange();
    }
  }

  count() { return this.peers.size; }

  // Per-peer transport RTT (from the broadcaster's side) — handy for spotting a
  // single flaky phone. The authoritative end-to-end estimate is computed on
  // the listener and reported via `stats`.
  async getPeerStats() {
    const out = [];
    for (const [id, entry] of this.peers) {
      let rttMs = null;
      try {
        const stats = await entry.pc.getStats();
        stats.forEach((r) => {
          if (r.type === 'candidate-pair' && r.state === 'succeeded' &&
              (r.nominated || r.selected) && r.currentRoundTripTime != null) {
            rttMs = Math.round(r.currentRoundTripTime * 1000);
          }
        });
      } catch {}
      out.push({ id, house: entry.house, state: entry.pc.connectionState, rttMs });
    }
    return out;
  }

  stop() {
    for (const entry of this.peers.values()) {
      try { entry.pc.close(); } catch {}
    }
    this.peers.clear();
    this.onPeerChange();
  }
}

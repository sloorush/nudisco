// Signaling hub: relays WebRTC offer/answer/ICE between ONE broadcaster and
// MANY listeners. It is deliberately transport-agnostic — it never inspects or
// understands the SDP/ICE payloads, it only routes `signal` messages by id.
//
// This is the server half of the "swappable broadcast layer". For the current
// mesh topology the broadcaster opens a peer connection per listener and this
// hub just forwards messages. If you later swap in a mediasoup SFU, the
// broadcaster would instead talk to the SFU and listeners would consume from
// it; this relay would shrink to "tell the SFU who joined/left". The wire
// protocol (hello / welcome / signal / stats) is intentionally simple so either
// model fits.

export class SignalingHub {
  constructor() {
    this.broadcaster = null;      // the single broadcaster ws (or null)
    this.listeners = new Map();   // id -> ws
    this.counter = 0;
  }

  handleConnection(ws) {
    ws.isAlive = true;
    ws.role = null;
    ws.id = null;
    ws.house = false;
    ws.on('pong', () => { ws.isAlive = true; });
    ws.on('message', (buf) => {
      let msg;
      try { msg = JSON.parse(buf.toString()); } catch { return; }
      this.handleMessage(ws, msg);
    });
    ws.on('close', () => this.handleClose(ws));
    ws.on('error', () => { /* ignore; close handler does cleanup */ });
  }

  send(ws, obj) {
    if (ws && ws.readyState === 1 /* OPEN */) {
      try { ws.send(JSON.stringify(obj)); } catch { /* socket went away */ }
    }
  }

  handleMessage(ws, msg) {
    switch (msg.type) {
      case 'hello':  return this.onHello(ws, msg);
      case 'signal': return this.onSignal(ws, msg);
      case 'stats':  return this.onStats(ws, msg);
      default:       return;
    }
  }

  onHello(ws, msg) {
    if (msg.role === 'broadcaster') {
      // Only one broadcaster at a time. A new one replaces the old (e.g. the DJ
      // reloaded the broadcast page).
      if (this.broadcaster && this.broadcaster !== ws) {
        this.send(this.broadcaster, { type: 'replaced' });
        try { this.broadcaster.close(); } catch {}
      }
      ws.role = 'broadcaster';
      ws.id = 'broadcaster';
      this.broadcaster = ws;
      this.send(ws, { type: 'welcome', id: ws.id, role: 'broadcaster' });

      // Re-announce every existing listener so the (possibly reconnected)
      // broadcaster offers to all of them.
      for (const [id, lws] of this.listeners) {
        this.send(ws, { type: 'listener-joined', id, house: lws.house });
        this.send(lws, { type: 'broadcaster-available' });
      }
      this.sendCount();
    } else {
      // Listener.
      const id = 'L' + (++this.counter);
      ws.role = 'listener';
      ws.id = id;
      ws.house = !!msg.house;
      this.listeners.set(id, ws);
      this.send(ws, { type: 'welcome', id, role: 'listener' });
      if (this.broadcaster) {
        this.send(ws, { type: 'broadcaster-available' });
        this.send(this.broadcaster, { type: 'listener-joined', id, house: ws.house });
      } else {
        this.send(ws, { type: 'no-broadcaster' });
      }
      this.sendCount();
    }
  }

  onSignal(ws, msg) {
    // Route an opaque signaling payload to a specific peer.
    const target = msg.to === 'broadcaster'
      ? this.broadcaster
      : this.listeners.get(msg.to);
    if (target) this.send(target, { type: 'signal', from: ws.id, data: msg.data });
  }

  onStats(ws, msg) {
    // Listener -> broadcaster latency/quality telemetry (for the on-screen
    // readout and the recommended room-speaker delay).
    if (ws.role === 'listener' && this.broadcaster) {
      this.send(this.broadcaster, {
        type: 'listener-stats',
        id: ws.id,
        house: !!ws.house,
        stats: msg.stats,
      });
    }
  }

  handleClose(ws) {
    if (ws.role === 'broadcaster' && this.broadcaster === ws) {
      this.broadcaster = null;
      for (const lws of this.listeners.values()) {
        this.send(lws, { type: 'broadcaster-gone' });
      }
    } else if (ws.role === 'listener') {
      this.listeners.delete(ws.id);
      if (this.broadcaster) this.send(this.broadcaster, { type: 'listener-left', id: ws.id });
      this.sendCount();
    }
  }

  sendCount() {
    if (this.broadcaster) {
      this.send(this.broadcaster, { type: 'listener-count', count: this.listeners.size });
    }
  }
}

import Foundation
import Combine
import WebRTC

/// Orchestrates signaling + WebRTC + audio + reconnect for the listener, exactly
/// like the web listener.js but native. The app is just another `role:listener`
/// peer; the broadcaster offers, we answer.
@MainActor
final class PlayerViewModel: ObservableObject {
    enum Status: String {
        case idle = "Idle"
        case connecting = "Connecting…"
        case waiting = "Waiting for the DJ…"
        case live = "Connected — enjoy 🎧"
        case error = "Reconnecting…"
    }

    @Published var status: Status = .idle
    @Published var latencyText = "— ms"
    @Published var preset: BufferPreset = .saved()
    @Published var isMuted = false
    @Published var isActive = false       // a connect attempt is in progress / live

    init() {
        #if DEBUG
        // Screenshot/demo state — never compiled into Release. Launch with `--demo`
        // (`simctl launch … --demo`) to render the connected screen with no session.
        if CommandLine.arguments.contains("--demo") {
            isActive = true
            status = .live
            latencyText = "92 ms"
        }
        #endif
    }

    private var signaling: Signaling?
    private var webrtc: WebRTCClient?
    private var serverURL: URL?
    private var statsTimer: Timer?
    private var reconnectWork: DispatchWorkItem?
    private var manualStop = false

    /// Accepts "http://192.168.1.5:3000/", "192.168.1.5:3000", or "192.168.1.5".
    func connect(to raw: String) {
        guard let ws = Self.wsURL(from: raw), let host = ws.host else { status = .error; return }
        serverURL = ws
        manualStop = false
        isActive = true
        status = .connecting
        AudioSessionManager.activate()      // turn on the audio session now (not at launch)
        AudioSessionManager.setupRemoteCommands(
            play: { [weak self] in self?.setMuted(false) },
            pause: { [weak self] in self?.setMuted(true) })
        // Surface the iOS Local Network permission prompt + confirm reachability
        // before opening the WebSocket (URLSession to a LAN IP otherwise -1009s
        // until access is granted). Proceed regardless of the probe result.
        let port = UInt16(ws.port ?? 3000)
        LocalNetwork.prime(host: host, port: port) { [weak self] (_: Bool) in
            self?.startSignaling()
        }
    }

    func disconnect() {
        manualStop = true
        reconnectWork?.cancel()
        teardownPeer()
        signaling?.close(); signaling = nil
        isActive = false; status = .idle
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        webrtc?.setMuted(muted)
        AudioSessionManager.updateNowPlaying(title: "nudisco — live",
                                             subtitle: muted ? "Paused" : "Live",
                                             isPlaying: !muted)
    }

    /// Jitter-buffer size is fixed when the peer is created, so apply a new preset
    /// by briefly reconnecting (a fresh offer rebuilds the peer with it).
    func changePreset(_ p: BufferPreset) {
        preset = p; p.save()
        guard isActive, !manualStop else { return }
        reconnectNow()
    }

    // MARK: signaling
    private func startSignaling() {
        guard let url = serverURL else { return }
        status = .connecting
        let s = Signaling(url: url)
        s.onOpen = { [weak self] in
            self?.signaling?.send(["type": "hello", "role": "listener", "house": false])
        }
        s.onMessage = { [weak self] msg in self?.handle(msg) }
        s.onClose = { [weak self] in
            guard let self, !self.manualStop else { return }
            self.status = .error
            self.scheduleReconnect()
        }
        signaling = s
        s.connect()
    }

    private func handle(_ msg: [String: Any]) {
        switch msg["type"] as? String {
        case "broadcaster-available": status = .connecting
        case "no-broadcaster":        status = .waiting
        case "broadcaster-gone":      status = .waiting; teardownPeer()
        case "signal":
            guard let data = msg["data"] as? [String: Any] else { return }
            if let sdp = data["sdp"] as? [String: Any],
               (sdp["type"] as? String) == "offer", let s = sdp["sdp"] as? String {
                startPeerAndAnswer(offer: s)
            } else if data["candidate"] != nil {
                webrtc?.addRemoteCandidate(data)
            }
        default: break
        }
    }

    // MARK: peer
    private func startPeerAndAnswer(offer: String) {
        teardownPeer()
        let client = WebRTCClient(preset: preset)
        client.delegate = self
        client.start()
        webrtc = client
        client.handleOffer(offer) { [weak self] answerSDP in
            guard let self, let answerSDP else { return }
            self.signaling?.send(["type": "signal", "to": "broadcaster",
                                  "data": ["sdp": ["type": "answer", "sdp": answerSDP]]])
        }
        startStatsLoop()
    }

    private func teardownPeer() {
        statsTimer?.invalidate(); statsTimer = nil
        webrtc?.close(); webrtc = nil
    }

    private func scheduleReconnect() {
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reconnectNow() }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
    private func reconnectNow() {
        guard !manualStop else { return }
        teardownPeer()
        signaling?.close(); signaling = nil
        startSignaling()
    }

    private func startStatsLoop() {
        statsTimer?.invalidate()
        // Timer's closure is @Sendable, so don't touch main-actor state in it —
        // hop to the main actor first, then read webrtc/signaling.
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reportStats() }
        }
    }

    private func reportStats() {
        webrtc?.stats { [weak self] est, rtt, jb, jitter in
            DispatchQueue.main.async {
                guard let self else { return }
                if let est { self.latencyText = "\(Int(est.rounded())) ms" }
                var stats: [String: Any] = [:]
                if let est { stats["latencyMs"] = est }
                if let rtt { stats["rttMs"] = rtt }
                if let jb { stats["jbMs"] = jb }
                if let jitter { stats["jitterMs"] = jitter }
                self.signaling?.send(["type": "stats", "stats": stats])
            }
        }
    }

    static func wsURL(from raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comps = URLComponents(string: s), let host = comps.host {
            return URL(string: "ws://\(host):\(comps.port ?? 3000)/ws")
        }
        if !s.contains("://") {                      // bare "ip" or "ip:port"
            let hostPort = s.contains(":") ? s : "\(s):3000"
            return URL(string: "ws://\(hostPort)/ws")
        }
        return nil
    }
}

extension PlayerViewModel: WebRTCClientDelegate {
    nonisolated func webRTC(_ c: WebRTCClient, didGenerateCandidate dict: [String: Any]) {
        Task { @MainActor in
            self.signaling?.send(["type": "signal", "to": "broadcaster", "data": ["candidate": dict]])
        }
    }
    nonisolated func webRTC(_ c: WebRTCClient, didChangeConnection state: RTCPeerConnectionState) {
        Task { @MainActor in
            switch state {
            case .connected:
                self.status = .live
                AudioSessionManager.updateNowPlaying(title: "nudisco — live", subtitle: "Live", isPlaying: !self.isMuted)
            case .failed:
                self.status = .error; self.scheduleReconnect()
            case .disconnected:
                self.status = .error
            default: break
            }
        }
    }
    nonisolated func webRTCDidReceiveAudio(_ c: WebRTCClient) {
        Task { @MainActor in self.setMuted(self.isMuted) }   // sync track enabled-state
    }
}

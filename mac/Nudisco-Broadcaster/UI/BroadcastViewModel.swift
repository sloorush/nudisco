import Foundation
import SwiftUI
import CoreAudio

/// Orchestrates the whole broadcaster: the embedded server (signaling + serving
/// the web listener), the WebRTC mesh, and audio capture. Mirrors the behavior of
/// public/js/broadcast.js (status, listener count, level meter, join URL + QR,
/// per-listener latency table, recommended room-speaker delay).
@MainActor
final class BroadcastViewModel: ObservableObject {

    enum SourceSelection: Hashable {
        case systemWide
        case testTone                 // Spike 0 / sanity: a 440 Hz tone instead of the tap
        case process(AudioObjectID)
    }

    @Published var isOnAir = false
    @Published var status = "Pick a source and go on air."
    @Published var errorMessage: String?

    @Published var processes: [AudioProcess] = []
    @Published var selection: SourceSelection = .systemWide

    @Published var listenerCount = 0
    @Published var level: Float = 0                 // 0...1 for the meter
    @Published var rows: [ListenerRowModel] = []
    @Published var joinURL = ""
    @Published var recommended = "— ms"
    @Published var recommendedNote = "Waiting for a phone to report latency…"

    private let port = 3000
    private let hub = SignalingHub()
    private lazy var engine = BroadcastEngine(hub: hub)
    private let capture = ProcessTapCapture(device: WebRTCFactory.shared.audioDevice)
    private lazy var sine = SineToneSource(device: WebRTCFactory.shared.audioDevice)
    private var server: EmbeddedServer?

    // listenerId -> latest reported stats + freshness, like broadcast.js latencyById.
    private var latencyById: [String: (stats: [String: Any], house: Bool, ts: Date)] = [:]
    private var refreshTimer: Timer?

    init() {
        wireEngine()
        refreshProcesses()
        capture.levelHandler = { [weak self] lvl in self?.level = lvl }
        #if DEBUG
        // Screenshot/demo state — never compiled into Release. Pass `--demo` (via
        // `open … --args --demo`) to render a populated "on air" screen with no live session.
        if CommandLine.arguments.contains("--demo") { loadDemoState() }
        #endif
    }

    #if DEBUG
    private func loadDemoState() {
        isOnAir = true
        status = "on air — share the link / qr with guests."
        joinURL = "http://192.168.1.50:3000/"
        listenerCount = 3
        level = 0.62
        recommended = "172 ms"
        recommendedNote = "median of 3 phone(s) · range 150–190 ms · set your room-speaker delay to ≈ this."
        rows = [
            ListenerRowModel(id: "L1", house: true,  state: "connected", latency: 60,  rtt: 8,  jb: 120),
            ListenerRowModel(id: "L2", house: false, state: "connected", latency: 168, rtt: 12, jb: 200),
            ListenerRowModel(id: "L3", house: false, state: "connected", latency: 190, rtt: 18, jb: 200),
        ]
    }
    #endif

    // MARK: - source list
    func refreshProcesses() {
        processes = AudioProcessList.current()
    }

    // MARK: - on/off air
    func toggleOnAir() {
        isOnAir ? goOffAir() : goOnAir()
    }

    private func goOnAir() {
        errorMessage = nil

        // 1) Local server (signaling + serving the web listener). Needs Local
        //    Network permission on macOS 15+; reports the real reason if it fails.
        do {
            try startServerIfNeeded()
        } catch {
            errorMessage = "Couldn't start the local server on port \(port). " +
                "Allow Local Network access for nudisco (System Settings ▸ Privacy & " +
                "Security ▸ Local Network), and make sure the port is free. [\(String(describing: error))]"
            return
        }

        // 2) Audio capture (skipped for the test tone, which feeds the ADM directly).
        do {
            switch selection {
            case .testTone:
                sine.start()
            case .systemWide:
                try capture.start(source: .systemWide)
            case .process(let oid):
                try capture.start(source: .processes([oid]))
            }
        } catch {
            errorMessage = "Couldn't start audio capture (allow audio capture when " +
                "prompted). [\(String(describing: error))]"
            return
        }

        engine.start()
        isOnAir = true
        status = "On air — share the link / QR with guests."
        startRefresh()
    }

    private func goOffAir() {
        engine.stop()
        capture.stop()
        sine.stop()
        stopRefresh()
        isOnAir = false
        level = 0
        listenerCount = 0
        rows = []
        latencyById.removeAll()
        recommended = "— ms"
        recommendedNote = "Waiting for a phone to report latency…"
        status = "Stopped."
    }

    private func startServerIfNeeded() throws {
        guard server == nil else { return }
        let s = EmbeddedServer(port: port, hub: hub, publicDir: EmbeddedServer.bundledPublicDir)
        try s.start()
        server = s
        joinURL = "http://\(LanIP.current()):\(port)/"
    }

    // MARK: - engine wiring
    private func wireEngine() {
        engine.onListenerCount = { [weak self] c in self?.listenerCount = c }
        engine.onListenerLeft = { [weak self] id in self?.latencyById[id] = nil }
        engine.onPeersChanged = { [weak self] in self?.renderListeners() }
        engine.onListenerStats = { [weak self] id, house, stats in
            self?.latencyById[id] = (stats, house, Date())
            self?.renderListeners()
        }
        engine.onReplaced = { [weak self] in
            self?.goOffAir()
            self?.status = "Another broadcaster took over this session."
        }
    }

    private func startRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.renderListeners() }
        }
    }
    private func stopRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - listener table + recommended speaker delay (port of renderListeners)
    private func renderListeners() {
        engine.peerStats { [weak self] peerStats in
            guard let self = self else { return }
            var newRows: [ListenerRowModel] = []
            var phoneLatencies: [Int] = []
            let now = Date()

            for p in peerStats {
                let rep = self.latencyById[p.id]
                let lat = Self.intVal(rep?.stats["latencyMs"])
                // Drop reports older than ~3 cycles so a frozen phone stops skewing it.
                let fresh = rep.map { now.timeIntervalSince($0.ts) <= 6 } ?? false
                if let lat = lat, !p.house, fresh { phoneLatencies.append(lat) }
                newRows.append(ListenerRowModel(
                    id: p.id, house: p.house, state: p.state,
                    latency: lat,
                    rtt: Self.intVal(rep?.stats["rttMs"]) ?? p.rttMs.map { Int($0) },
                    jb: Self.intVal(rep?.stats["jbMs"])))
            }
            self.rows = newRows

            if !phoneLatencies.isEmpty {
                phoneLatencies.sort()
                let mid = phoneLatencies.count / 2
                let median = phoneLatencies.count % 2 == 1
                    ? phoneLatencies[mid]
                    : (phoneLatencies[mid - 1] + phoneLatencies[mid]) / 2
                let lo = phoneLatencies.first!, hi = phoneLatencies.last!
                self.recommended = "\(median) ms"
                self.recommendedNote =
                    "median of \(phoneLatencies.count) phone(s) · range \(lo)–\(hi) ms · " +
                    "set your room-speaker delay to ≈ this."
            } else {
                self.recommended = "— ms"
                self.recommendedNote = "Waiting for a phone to report latency…"
            }
        }
    }

    private static func intVal(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let d = v as? Double { return Int(d.rounded()) }
        if let i = v as? Int { return i }
        return nil
    }
}

import Foundation

/// Mirrors the web listener's BUFFER_PRESETS (public/js/rtc-common.js), but the
/// native NetEQ jitter buffer is tuned via max-packets + fast-accelerate rather
/// than a millisecond target (the Obj-C API has no `jitterBufferTarget`). Each
/// "packet" is roughly one Opus frame (~10–20 ms), so maxPackets caps how much
/// the buffer may grow. Values are sensible starting points — tune on-device.
struct BufferPreset: Equatable, Identifiable {
    let id: String
    let label: String
    let jitterMaxPackets: Int32     // RTCConfiguration.audioJitterBufferMaxPackets
    let fastAccelerate: Bool        // drain aggressively toward lower latency

    static let smooth   = BufferPreset(id: "smooth",   label: "Smooth",      jitterMaxPackets: 60, fastAccelerate: false)
    static let balanced = BufferPreset(id: "balanced", label: "Balanced",    jitterMaxPackets: 30, fastAccelerate: true)
    static let low      = BufferPreset(id: "low",      label: "Low latency", jitterMaxPackets: 15, fastAccelerate: true)

    static let all = [smooth, balanced, low]
    static func by(id: String?) -> BufferPreset { all.first { $0.id == id } ?? smooth }

    private static let key = "nudisco.buffer"
    static func saved() -> BufferPreset { by(id: UserDefaults.standard.string(forKey: key)) }
    func save() { UserDefaults.standard.set(id, forKey: BufferPreset.key) }
}

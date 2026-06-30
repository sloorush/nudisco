import Foundation

/// SDP rewriting — a faithful Swift port of `configureOpus()` in
/// public/js/rtc-common.js. There's no API to request stereo/high-bitrate Opus,
/// so we rewrite the `a=fmtp` line and add audio NACK feedback for Opus (+ RED).
/// Applied to the OFFER before setLocalDescription, exactly like the web
/// broadcaster, so listeners negotiate an identical stream.
enum SdpMunge {
    static func configureOpus(_ sdp: String,
                              stereo: Bool = true,
                              bitrate: Int = 160_000,
                              fec: Bool = true,
                              dtx: Bool = false,
                              minptime: Int = 10) -> String {
        var lines = sdp.components(separatedBy: "\r\n")
        guard let pt = payloadType(in: lines, codec: "opus") else { return sdp }  // no Opus — leave as-is

        let params = [
            "minptime=\(minptime)",
            "useinbandfec=\(fec ? 1 : 0)",
            "usedtx=\(dtx ? 1 : 0)",
            "stereo=\(stereo ? 1 : 0)",
            "sprop-stereo=\(stereo ? 1 : 0)",
            "maxaveragebitrate=\(bitrate)",
            "maxplaybackrate=48000",
        ].joined(separator: ";")
        let fmtpLine = "a=fmtp:\(pt) \(params)"

        if let idx = lines.firstIndex(where: { $0 == "a=fmtp:\(pt)" || $0.hasPrefix("a=fmtp:\(pt) ") }) {
            lines[idx] = fmtpLine
        } else if let r = lines.firstIndex(where: { $0.hasPrefix("a=rtpmap:\(pt) ") }) {
            lines.insert(fmtpLine, at: r + 1)
        }

        // Audio NACK: let the receiver request retransmission (cheap on a low-RTT
        // LAN). Add `a=rtcp-fb:<pt> nack` for Opus and, if offered, RED.
        let redPt = payloadType(in: lines, codec: "red")
        for p in [pt, redPt].compactMap({ $0 }) {
            let fb = "a=rtcp-fb:\(p) nack"
            if lines.contains(fb) { continue }
            if let idx = lines.firstIndex(where: { $0.hasPrefix("a=fmtp:\(p)") || $0.hasPrefix("a=rtpmap:\(p) ") }) {
                lines.insert(fb, at: idx + 1)
            }
        }

        // Prefer RED (redundant audio): move its payload type to the FRONT of the
        // `m=audio` line so it's negotiated as the primary codec. This is the same
        // effect as the web `preferRed()` (RTCRtpTransceiver.setCodecPreferences),
        // which this libwebrtc build doesn't expose — so we do it in SDP.
        if let redPt = redPt, let mi = lines.firstIndex(where: { $0.hasPrefix("m=audio ") }) {
            var toks = lines[mi].components(separatedBy: " ")
            if toks.count > 3, let idx = toks[3...].firstIndex(of: redPt) {
                toks.remove(at: idx)
                toks.insert(redPt, at: 3)        // after `m=audio <port> <proto>`
                lines[mi] = toks.joined(separator: " ")
            }
        }

        return lines.joined(separator: "\r\n")
    }

    /// Payload type for `a=rtpmap:<pt> <codec>/48000[...]`.
    private static func payloadType(in lines: [String], codec: String) -> String? {
        let prefix = "a=rtpmap:"
        for line in lines where line.hasPrefix(prefix) {
            let body = line.dropFirst(prefix.count)
            guard let space = body.firstIndex(of: " ") else { continue }
            let pt = String(body[..<space])
            let rest = body[body.index(after: space)...].lowercased()
            if rest.hasPrefix("\(codec)/48000") { return pt }
        }
        return nil
    }
}

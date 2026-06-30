import Foundation
import AVFAudio
import CoreAudio

/// Spike-0 / "Test tone" producer. Generates a 48 kHz stereo sine and pushes it
/// into `NudiscoAudioDevice` exactly like the real capture would — so it isolates
/// the WebRTC custom-audio path (factory + ADM + mesh + signaling) from the Core
/// Audio tap. If a listener hears this tone, PCM injection works end to end and
/// the riskiest assumption in the whole project is proven. Only then does the
/// real tap need to work.
final class SineToneSource {
    private let device: NudiscoAudioDevice
    private let sampleRate: Double = 48_000
    private let channels = 2
    private let frames: AVAudioFrameCount = 480        // 10 ms at 48 kHz
    private let frequency: Double = 440                 // A4
    private let amplitude: Float = 0.2                  // ~ -14 dBFS, gentle
    private let format: AVAudioFormat
    private let queue = DispatchQueue(label: "nudisco.sine", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var phase: Double = 0
    private var sampleTime: Double = 0

    init(device: NudiscoAudioDevice) {
        self.device = device
        self.format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: sampleRate,
                                    channels: AVAudioChannelCount(channels),
                                    interleaved: false)!
    }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buf.frameLength = frames
        guard let chans = buf.floatChannelData else { return }
        let inc = 2.0 * Double.pi * frequency / sampleRate
        for i in 0..<Int(frames) {
            let v = Float(sin(phase)) * amplitude
            for c in 0..<channels { chans[c][i] = v }
            phase += inc
            if phase > 2 * Double.pi { phase -= 2 * Double.pi }
        }
        var ts = AudioTimeStamp()
        ts.mSampleTime = sampleTime
        ts.mFlags = .sampleTimeValid
        sampleTime += Double(frames)
        device.deliver(buf.audioBufferList, format: format, frames: frames, timestamp: &ts)
    }
}

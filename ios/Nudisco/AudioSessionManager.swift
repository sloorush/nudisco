import Foundation
import AVFoundation
import WebRTC
import MediaPlayer

/// The piece that makes locked-screen / background playback work — and keeps the
/// app off the microphone. Two things matter:
///   1. UIBackgroundModes = [audio] in Info.plist (set via project.yml).
///   2. The audio session category is .playback (NOT .playAndRecord). libwebrtc
///      defaults to .playAndRecord (call mode), which both prompts for the mic
///      and behaves like a phone call. We override it to .playback BEFORE the
///      peer connection initializes its audio unit.
enum AudioSessionManager {
    /// Call once at launch, before creating any WebRTCClient.
    static func configureForPlayback() {
        // libwebrtc's default audio engine drives ONE audio unit that includes an
        // input element, so the session needs an input route. A pure .playback
        // session starves it and NOTHING plays (and the latency readout stays
        // blank because no samples are emitted). Use .playAndRecord — what
        // libwebrtc expects — and route to the speaker / Bluetooth. This is also
        // why iOS asks for the microphone: it's needed to start the audio unit.
        // nudisco adds no local track, so it never records or transmits anything.
        let rtc = RTCAudioSessionConfiguration.webRTC()
        rtc.category = AVAudioSession.Category.playAndRecord.rawValue
        rtc.categoryOptions = [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
        rtc.mode = AVAudioSession.Mode.default.rawValue
        RTCAudioSessionConfiguration.setWebRTC(rtc)

        // Apply via the (string-based) configuration object in one call — avoids
        // RTCAudioSession.setCategory/setMode whose argument types differ between
        // libwebrtc versions (String vs AVAudioSession.Category/.Mode).
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        do {
            try session.setConfiguration(rtc, active: true)
        } catch {
            print("audio session config failed:", error)
        }
        session.unlockForConfiguration()
    }

    static func updateNowPlaying(title: String, subtitle: String, isPlaying: Bool) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: subtitle,
        ]
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Wire lock-screen / Control-Center play & pause to the given closures.
    static func setupRemoteCommands(play: @escaping () -> Void, pause: @escaping () -> Void) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.playCommand.addTarget { _ in play(); return .success }
        center.pauseCommand.addTarget { _ in pause(); return .success }
    }
}

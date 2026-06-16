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
    /// Cheap, non-blocking — call at launch. Just tells libwebrtc which audio
    /// category to use when it later starts the audio unit; does NOT touch the
    /// audio hardware (so it doesn't slow down app launch).
    ///
    /// libwebrtc's default engine drives ONE audio unit that includes an input
    /// element, so the session needs an input route — a pure .playback session
    /// starves it and nothing plays. We use .playAndRecord (what libwebrtc
    /// expects) routed to speaker / Bluetooth. (This is also why iOS asks for the
    /// mic — see note below; we never record or transmit it.)
    static func prepare() {
        let rtc = RTCAudioSessionConfiguration.webRTC()
        rtc.category = AVAudioSession.Category.playAndRecord.rawValue
        rtc.categoryOptions = [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
        rtc.mode = AVAudioSession.Mode.default.rawValue
        RTCAudioSessionConfiguration.setWebRTC(rtc)
    }

    /// Activate the session — call when connecting (audio is imminent), NOT at
    /// launch. Activation negotiates the route with the OS and can block briefly.
    static func activate() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        do {
            try session.setConfiguration(RTCAudioSessionConfiguration.webRTC(), active: true)
        } catch {
            print("audio session activate failed:", error)
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

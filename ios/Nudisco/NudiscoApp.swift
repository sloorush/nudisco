import SwiftUI

@main
struct NudiscoApp: App {
    init() {
        // Must run before any peer connection so libwebrtc uses .playback (no mic,
        // background-capable) instead of its default call-style .playAndRecord.
        AudioSessionManager.configureForPlayback()
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

import SwiftUI

@main
struct NudiscoApp: App {
    init() {
        // Cheap: just set the audio category libwebrtc will use. The session is
        // only ACTIVATED on connect (PlayerViewModel) so launch stays fast.
        AudioSessionManager.prepare()
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

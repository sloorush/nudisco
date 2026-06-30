import SwiftUI

@main
struct NudiscoBroadcasterApp: App {
    var body: some Scene {
        WindowGroup("nudisco") {
            ContentView()
            #if DEBUG
                .task { await ScreenshotExporter.exportIfRequested() }
            #endif
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}   // single-window broadcaster
        }
    }
}

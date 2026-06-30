#if DEBUG
import SwiftUI
import AppKit

/// DEBUG-only: renders ContentView straight to a PNG via ImageRenderer (no Screen
/// Recording permission needed, unlike `screencapture`). Used to generate the
/// repo's marketing screenshots deterministically. Launch via `open` so the scene
/// (and this `.task`) actually starts, passing args through `--args`:
///
///   open …/NudiscoBroadcaster.app --args --shot /path/out.png            → setup
///   open …/NudiscoBroadcaster.app --args --shot /path/out.png --demo     → on air
@MainActor
enum ScreenshotExporter {
    static func exportIfRequested() async {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--shot"), i + 1 < args.count else { return }
        let path = args[i + 1]
        let demo = args.contains("--demo")

        // Let AppKit finish launch (custom fonts register) and demo state settle.
        try? await Task.sleep(nanoseconds: 800_000_000)

        _ = demo   // --demo is read by BroadcastViewModel.init to load the on-air state
        let vm = BroadcastViewModel()
        let view = BroadcastBody(vm: vm, screenshot: true)
            .padding(32)
            .frame(width: 720, alignment: .top)   // definite width, natural height (no ScrollView)
            .background(Color.brandYellow)
            .tint(.brandInk)
            .textCase(.lowercase)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2

        if let image = renderer.nsImage,
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        exit(0)
    }
}
#endif

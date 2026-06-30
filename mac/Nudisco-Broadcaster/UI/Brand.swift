import SwiftUI

// enchante brand — mirrors ios/Nudisco/ContentView.swift so the Mac app matches
// the phone app and the web pages (yellow #FFE500 / ink #0D0E12, lowercase
// Satoshi typography).
extension Color {
    static let brandYellow = Color(red: 1.0, green: 0.898, blue: 0.0)     // #FFE500
    static let brandInk    = Color(red: 0.051, green: 0.055, blue: 0.071) // #0D0E12
}

extension Font {
    /// Bundled Satoshi (Contents/Resources/Fonts via ATSApplicationFontsPath).
    static func satoshi(_ size: CGFloat, _ weight: String = "Bold") -> Font {
        .custom("Satoshi-\(weight)", size: size)   // Regular | Medium | Bold | Black
    }
}

/// The enchante loop-badge mark (matches the app icon). Asset lives in
/// Assets.xcassets/BrandLogo.imageset.
struct BrandMark: View {
    var size: CGFloat = 34
    var body: some View {
        Image("BrandLogo")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

/// Renders a crisp QR code for the join URL on-device (the native equivalent of
/// the web broadcaster's `/qr.svg`). Guests scan this with the nudisco phone app.
struct QRImageView: View {
    let text: String

    var body: some View {
        if let image = Self.make(text) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.none)          // keep modules crisp
                .scaledToFit()
        } else {
            Color.clear
        }
    }

    private static func make(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

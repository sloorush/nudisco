import Foundation
import CoreImage
import CoreGraphics

/// Generates an SVG QR code for the join URL — the native equivalent of the
/// `/qr.svg` route in src/server.js (which used the `qrcode` npm lib). Served so
/// the bundled web broadcaster page keeps working; the native UI renders its own
/// QR via CoreImage. Colors match the web (dark #0b0d12 on #ffffff).
enum QRSvg {
    static func svg(for text: String,
                    dark: String = "#0b0d12",
                    light: String = "#ffffff",
                    pixelSize: Int = 320) -> String? {
        guard let data = text.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")     // medium ECC, like the web default
        guard let image = filter.outputImage else { return nil }

        // CIQRCodeGenerator renders one pixel per module (plus a quiet-zone border).
        let extent = image.extent
        let w = Int(extent.width), h = Int(extent.height)
        guard w > 0, h > 0,
              let cg = CIContext().createCGImage(image, from: extent) else { return nil }

        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let gray = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        gray.interpolationQuality = .none
        gray.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var rects = ""
        for y in 0..<h {
            for x in 0..<w {
                // CoreGraphics origin is bottom-left; flip to SVG's top-left.
                if pixels[(h - 1 - y) * w + x] < 128 {
                    rects += "<rect x=\"\(x)\" y=\"\(y)\" width=\"1\" height=\"1\"/>"
                }
            }
        }
        return """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(pixelSize)" height="\(pixelSize)" \
        viewBox="0 0 \(w) \(h)" shape-rendering="crispEdges">\
        <rect width="\(w)" height="\(h)" fill="\(light)"/>\
        <g fill="\(dark)">\(rects)</g></svg>
        """
    }
}

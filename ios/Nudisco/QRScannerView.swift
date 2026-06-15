import SwiftUI
import UIKit
import AVFoundation

/// Scans the broadcaster page's QR (which encodes http://<ip>:<port>/) and hands
/// the raw string back; PlayerViewModel turns it into a ws:// URL.
struct QRScannerView: UIViewControllerRepresentable {
    let onResult: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }
    func makeUIViewController(context: Context) -> ScannerVC {
        let vc = ScannerVC(); vc.coordinator = context.coordinator; return vc
    }
    func updateUIViewController(_ vc: ScannerVC, context: Context) {}

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onResult: (String) -> Void
        private var fired = false
        init(onResult: @escaping (String) -> Void) { self.onResult = onResult }
        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput objects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !fired,
                  let obj = objects.first as? AVMetadataMachineReadableCodeObject,
                  let s = obj.stringValue else { return }
            fired = true
            onResult(s)
        }
    }

    final class ScannerVC: UIViewController {
        weak var coordinator: Coordinator?
        private let session = AVCaptureSession()
        private let preview = AVCaptureVideoPreviewLayer()

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(coordinator, queue: .main)
            output.metadataObjectTypes = [.qr]
            preview.session = session
            preview.videoGravity = .resizeAspectFill
            view.layer.addSublayer(preview)
            DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview.frame = view.layer.bounds
        }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if session.isRunning { session.stopRunning() }
        }
    }
}

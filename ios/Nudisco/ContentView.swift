import SwiftUI

extension Color {
    static let brandYellow = Color(red: 1.0, green: 0.898, blue: 0.0)     // #FFE500
    static let brandInk    = Color(red: 0.051, green: 0.055, blue: 0.071) // #0D0E12
}

// Bundled Satoshi (see ios/Nudisco/Fonts + UIAppFonts in project.yml).
extension Font {
    static func satoshi(_ size: CGFloat, _ weight: String = "Bold") -> Font {
        .custom("Satoshi-\(weight)", size: size)   // Regular | Medium | Bold | Black
    }
}

/// The enchante mark — the actual loop-badge logo (matches the app icon &
/// launch screen). Asset lives in Assets.xcassets/BrandLogo.imageset.
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

struct ContentView: View {
    @StateObject private var vm = PlayerViewModel()
    @State private var manualAddress = ""
    @State private var showScanner = false

    var body: some View {
        ZStack {
            Color.brandYellow.ignoresSafeArea()
            VStack(spacing: 26) {
                HStack(spacing: 12) {
                    BrandMark(size: 34)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("nudisco").font(.satoshi(26, "Bold")).foregroundStyle(Color.brandInk)
                        Text("by enchante").font(.satoshi(12, "Medium")).foregroundStyle(Color.brandInk.opacity(0.6))
                    }
                    Spacer()
                }
                if vm.isActive { connected } else { join }
            }
            .padding(28)
        }
        .tint(.brandInk)
        .textCase(.lowercase)               // all typography in small letters
        .preferredColorScheme(.light)
        .sheet(isPresented: $showScanner) {
            QRScannerView { value in
                showScanner = false
                vm.connect(to: value)
            }
            .ignoresSafeArea()
        }
    }

    // MARK: join
    private var join: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 12)
            Button { showScanner = true } label: {
                Label("Scan QR to Join", systemImage: "qrcode.viewfinder")
                    .font(.satoshi(20, "Bold"))
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
                    .foregroundStyle(Color.brandYellow)
                    .background(Color.brandInk, in: RoundedRectangle(cornerRadius: 16))
            }

            Text("or enter the DJ's address")
                .font(.satoshi(12, "Bold")).foregroundStyle(Color.brandInk.opacity(0.6))

            HStack(spacing: 10) {
                TextField("192.168.x.x:3000", text: $manualAddress)
                    .font(.satoshi(15, "Medium"))
                    .padding(12)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.brandInk, lineWidth: 2))
                    .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("Connect") { vm.connect(to: manualAddress) }
                    .font(.satoshi(15, "Bold")).foregroundStyle(Color.brandYellow)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(Color.brandInk, in: RoundedRectangle(cornerRadius: 10))
                    .opacity(manualAddress.isEmpty ? 0.4 : 1)
                    .disabled(manualAddress.isEmpty)
            }

            Text("Same Wi-Fi as the DJ. Audio keeps playing with the screen locked.")
                .font(.satoshi(13, "Medium")).foregroundStyle(Color.brandInk.opacity(0.6))
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    // MARK: connected
    private var connected: some View {
        VStack(spacing: 22) {
            HStack(spacing: 10) {
                Circle()
                    .fill(vm.status == .error ? Color.brandInk.opacity(0.35) : Color.brandInk)
                    .frame(width: 12, height: 12)
                Text(vm.status.rawValue).font(.satoshi(17, "Bold")).foregroundStyle(Color.brandInk)
                Spacer()
            }

            VStack(spacing: 2) {
                Text(vm.latencyText).font(.satoshi(60, "Black")).foregroundStyle(Color.brandInk)
                Text("estimated latency").font(.satoshi(12, "Bold")).foregroundStyle(Color.brandInk.opacity(0.6))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 22)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.brandInk, lineWidth: 2))

            Picker("Buffer", selection: Binding(
                get: { vm.preset.id },
                set: { vm.changePreset(.by(id: $0)) })) {
                ForEach(BufferPreset.all) { Text($0.label).tag($0.id) }
            }
            .pickerStyle(.segmented)

            Text("If choppy, choose Smooth. Lower = less delay but needs strong Wi-Fi.")
                .font(.satoshi(12, "Medium")).foregroundStyle(Color.brandInk.opacity(0.6))
                .multilineTextAlignment(.center)

            Button { vm.setMuted(!vm.isMuted) } label: {
                Label(vm.isMuted ? "Resume" : "Pause", systemImage: vm.isMuted ? "play.fill" : "pause.fill")
                    .font(.satoshi(16, "Bold")).frame(maxWidth: .infinity).padding(.vertical, 12)
                    .foregroundStyle(Color.brandInk)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.brandInk, lineWidth: 2))
            }

            Button { vm.disconnect() } label: {
                Text("Disconnect").font(.satoshi(16, "Bold"))
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .foregroundStyle(Color.brandInk.opacity(0.7))
            }
            Spacer()
        }
    }
}

#Preview { ContentView() }

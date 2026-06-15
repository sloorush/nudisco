import SwiftUI

struct ContentView: View {
    @StateObject private var vm = PlayerViewModel()
    @State private var manualAddress = ""
    @State private var showScanner = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.04, green: 0.05, blue: 0.07),
                                    Color(red: 0.07, green: 0.05, blue: 0.12)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 26) {
                Text("nudisco")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                if vm.isActive { connected } else { join }
            }
            .padding(28)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showScanner) {
            QRScannerView { value in
                showScanner = false
                vm.connect(to: value)
            }
            .ignoresSafeArea()
        }
    }

    private var join: some View {
        VStack(spacing: 16) {
            Button { showScanner = true } label: {
                Label("Scan QR to Join", systemImage: "qrcode.viewfinder")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)

            Text("or enter the DJ's address")
                .font(.footnote).foregroundStyle(.secondary)

            HStack {
                TextField("192.168.x.x:3000", text: $manualAddress)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Connect") { vm.connect(to: manualAddress) }
                    .disabled(manualAddress.isEmpty)
            }

            Text("Same Wi-Fi as the DJ. Audio keeps playing with the screen locked.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var connected: some View {
        VStack(spacing: 22) {
            HStack(spacing: 10) {
                Circle()
                    .fill(vm.status == .live ? Color.green : Color.yellow)
                    .frame(width: 12, height: 12)
                Text(vm.status.rawValue).foregroundStyle(.white)
            }

            VStack(spacing: 4) {
                Text(vm.latencyText)
                    .font(.system(size: 54, weight: .heavy))
                    .foregroundStyle(.cyan)
                Text("estimated latency")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Picker("Buffer", selection: Binding(
                get: { vm.preset.id },
                set: { vm.changePreset(.by(id: $0)) })) {
                ForEach(BufferPreset.all) { Text($0.label).tag($0.id) }
            }
            .pickerStyle(.segmented)

            Text("If choppy, choose Smooth. Lower = less delay but needs strong Wi-Fi.")
                .font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button { vm.setMuted(!vm.isMuted) } label: {
                Label(vm.isMuted ? "Resume" : "Pause",
                      systemImage: vm.isMuted ? "play.fill" : "pause.fill")
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.bordered).tint(.cyan)

            Button(role: .destructive) { vm.disconnect() } label: {
                Text("Disconnect").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }
}

#Preview { ContentView() }

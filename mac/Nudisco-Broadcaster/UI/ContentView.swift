import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var vm = BroadcastViewModel()

    var body: some View {
        ZStack {
            Color.brandYellow.ignoresSafeArea()
            ScrollView {
                BroadcastBody(vm: vm)
                    .padding(32)
                    .frame(maxWidth: 700)
                    .frame(maxWidth: .infinity)
            }
        }
        .tint(.brandInk)
        .textCase(.lowercase)
        .preferredColorScheme(.light)
        .frame(minWidth: 600, minHeight: 700)
    }
}

/// The content column (no ScrollView), shared by `ContentView` and the screenshot
/// exporter. Kept separate so `ImageRenderer` can render it at its natural height
/// (ScrollView renders empty offscreen).
struct BroadcastBody: View {
    @ObservedObject var vm: BroadcastViewModel
    /// When true, render the source control as a static pill (ImageRenderer can't
    /// draw an interactive Menu offscreen). Only set by the screenshot exporter.
    var screenshot: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if !vm.status.isEmpty {
                Text(vm.status)
                    .font(.satoshi(12, "Medium"))
                    .foregroundStyle(Color.brandInk.opacity(0.55))
            }
            if let err = vm.errorMessage { banner(err) }
            if vm.isOnAir { onAir } else { setup }
            footer
        }
    }

    // MARK: header
    private var header: some View {
        HStack(spacing: 12) {
            BrandMark(size: 36)
            VStack(alignment: .leading, spacing: 0) {
                Text("nudisco").font(.satoshi(28, "Bold")).foregroundStyle(Color.brandInk)
                Text("by enchante").font(.satoshi(12, "Medium")).foregroundStyle(Color.brandInk.opacity(0.6))
            }
            Spacer()
            statusPill
        }
    }

    private var statusPill: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(vm.isOnAir ? Color.brandInk : Color.brandInk.opacity(0.3))
                .frame(width: 9, height: 9)
            Text(vm.isOnAir ? "on air" : "off air")
                .font(.satoshi(12, "Bold")).foregroundStyle(Color.brandInk)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.white.opacity(0.55), in: Capsule())
    }

    private func banner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12))
            Text(text).font(.satoshi(13, "Medium"))
        }
        .foregroundStyle(Color.brandYellow)
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(Color.brandInk, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: off air
    private var setup: some View {
        VStack(alignment: .leading, spacing: 16) {
            card(title: "capture source") {
                VStack(alignment: .leading, spacing: 12) {
                    sourcePicker
                    Text("“whole system” captures everything your Mac plays — app-wide. your speakers keep playing; nudisco only listens in.")
                        .font(.satoshi(12, "Medium")).foregroundStyle(Color.brandInk.opacity(0.55))
                }
            }
            primaryButton("go on air") { vm.toggleOnAir() }
            Text("macos asks once to allow audio capture. tip: turn on do not disturb so notification sounds don't leak into the mix.")
                .font(.satoshi(11, "Medium")).foregroundStyle(Color.brandInk.opacity(0.5))
                .multilineTextAlignment(.center).frame(maxWidth: .infinity)
        }
    }

    private var sourcePicker: some View {
        HStack(spacing: 10) {
            Group {
                if screenshot {
                    sourceLabelPill                      // static stand-in for rendering
                } else {
                    Menu {
                        Button("whole system (everything the Mac plays)") { vm.selection = .systemWide }
                        Button("test tone (sanity check)") { vm.selection = .testTone }
                        if !vm.processes.isEmpty {
                            Section("just one app") {
                                ForEach(vm.processes) { p in
                                    Button(p.name) { vm.selection = .process(p.id) }
                                }
                            }
                        }
                    } label: {
                        sourceLabelPill
                    }
                    .menuStyle(.borderlessButton)
                }
            }
            .frame(maxWidth: 420)

            Button { vm.refreshProcesses() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.brandYellow)
                    .frame(width: 44, height: 44)
                    .background(Color.brandInk, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .help("refresh the app list")
        }
    }

    private var sourceLabelPill: some View {
        HStack(spacing: 8) {
            Text(sourceLabel).font(.satoshi(15, "Bold")).lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(Color.brandYellow)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Color.brandInk, in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private var sourceLabel: String {
        switch vm.selection {
        case .systemWide: return "whole system"
        case .testTone:   return "test tone (sanity check)"
        case .process(let id): return vm.processes.first { $0.id == id }?.name ?? "selected app"
        }
    }

    // MARK: on air
    private var onAir: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                statTile(value: "\(vm.listenerCount)",
                         label: vm.listenerCount == 1 ? "listener" : "listeners")
                statTile(value: vm.recommended, label: "room-speaker delay")
            }
            card(title: "source · \(sourceLabel)") { meterBar }
            card(title: "guests join here") { joinContent }
            card(title: "connected listeners") { listenerContent }
            secondaryButton("go off air") { vm.toggleOnAir() }
        }
    }

    private var meterBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.brandInk.opacity(0.12))
                Capsule().fill(Color.brandInk)
                    .frame(width: max(3, geo.size.width * CGFloat(vm.level)))
            }
        }
        .frame(height: 12)
    }

    private var joinContent: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text(vm.joinURL).font(.satoshi(19, "Bold")).foregroundStyle(Color.brandInk)
                    .textSelection(.enabled).lineLimit(1).minimumScaleFactor(0.7)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(vm.joinURL, forType: .string)
                } label: {
                    Label("copy link", systemImage: "doc.on.doc")
                        .font(.satoshi(13, "Bold")).foregroundStyle(Color.brandYellow)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.brandInk, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                Text("phone app or any browser — same Wi-Fi, no install.")
                    .font(.satoshi(11, "Medium")).foregroundStyle(Color.brandInk.opacity(0.55))
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            QRImageView(text: vm.joinURL)
                .frame(width: 128, height: 128)
                .padding(8)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.brandInk.opacity(0.12), lineWidth: 1))
        }
    }

    @ViewBuilder private var listenerContent: some View {
        if vm.rows.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right").font(.system(size: 14))
                Text("waiting for guests to join…").font(.satoshi(13, "Medium"))
            }
            .foregroundStyle(Color.brandInk.opacity(0.5))
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    tableHead("listener", .leading)
                    tableHead("state", .leading)
                    tableHead("latency", .trailing)
                    tableHead("rtt", .trailing)
                    tableHead("buffer", .trailing)
                }
                .padding(.bottom, 4)
                Divider().overlay(Color.brandInk.opacity(0.18))
                ForEach(vm.rows) { ListenerRow(model: $0) }
            }
            Text(vm.recommendedNote)
                .font(.satoshi(11, "Medium")).foregroundStyle(Color.brandInk.opacity(0.5))
                .padding(.top, 8)
        }
    }

    private func tableHead(_ t: String, _ align: Alignment) -> some View {
        Text(t).font(.satoshi(10, "Bold")).foregroundStyle(Color.brandInk.opacity(0.5))
            .frame(maxWidth: .infinity, alignment: align)
    }

    // MARK: footer
    private var footer: some View {
        Text("nudisco · by enchante")
            .font(.satoshi(11, "Medium")).foregroundStyle(Color.brandInk.opacity(0.4))
            .frame(maxWidth: .infinity, alignment: .center).padding(.top, 6)
    }

    // MARK: reusable building blocks
    private func card<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.satoshi(12, "Bold")).foregroundStyle(Color.brandInk.opacity(0.55))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.satoshi(40, "Black")).foregroundStyle(Color.brandYellow)
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(label).font(.satoshi(12, "Bold")).foregroundStyle(Color.brandYellow.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.brandInk, in: RoundedRectangle(cornerRadius: 16))
    }

    private func primaryButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.satoshi(20, "Bold"))
                .frame(maxWidth: .infinity).padding(.vertical, 18)
                .foregroundStyle(Color.brandYellow)
                .background(Color.brandInk, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private func secondaryButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.satoshi(16, "Bold"))
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .foregroundStyle(Color.brandInk)
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.brandInk, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}

#Preview { ContentView() }

import SwiftUI

/// One row in the connected-listeners table — mirrors the columns the web
/// broadcaster shows (id / state / latency / rtt / jitter-buffer + house badge).
struct ListenerRowModel: Identifiable, Equatable {
    let id: String
    let house: Bool
    let state: String
    let latency: Int?
    let rtt: Int?
    let jb: Int?
}

struct ListenerRow: View {
    let model: ListenerRowModel

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(model.id).font(.satoshi(13, "Bold"))
                if model.house {
                    Text("house")
                        .font(.satoshi(10, "Bold"))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.brandInk.opacity(0.12), in: Capsule())
                }
            }.frame(maxWidth: .infinity, alignment: .leading)

            Text(model.state).font(.satoshi(12, "Medium"))
                .foregroundStyle(model.state == "connected" ? Color.brandInk : Color.brandInk.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
            cell(model.latency)
            cell(model.rtt)
            cell(model.jb)
        }
        .foregroundStyle(Color.brandInk)
        .padding(.vertical, 4)
    }

    private func cell(_ value: Int?) -> some View {
        Text(value.map { "\($0) ms" } ?? "—")
            .font(.satoshi(12, "Medium"))
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

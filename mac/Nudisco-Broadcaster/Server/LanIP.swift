import Foundation

/// LAN IPv4 detection — a faithful port of `lanIp()` in src/server.js: prefer
/// en0 (typical Mac Wi-Fi), then any other non-internal IPv4, else loopback.
enum LanIP {
    static func current() -> String {
        var candidates: [(name: String, addr: String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return "127.0.0.1" }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
                  let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if ip.hasPrefix("169.254") { continue }   // skip link-local
            candidates.append((String(cString: cur.pointee.ifa_name), ip))
        }

        if let en0 = candidates.first(where: { $0.name == "en0" }) { return en0.addr }
        return candidates.first?.addr ?? "127.0.0.1"
    }
}

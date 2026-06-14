import Foundation

/// One selectable server profile = a complete Xray config object plus a display name.
struct XrayProfile {
    let id: String
    let name: String
    let config: [String: Any]

    /// Proxy outbound protocols we know how to run.
    static let proxyProtocols: Set<String> = ["vless", "vmess", "trojan", "shadowsocks"]

    /// Server addresses of every proxy outbound (ignoring direct/block/dns).
    var serverAddresses: [String] {
        var out: [String] = []
        let outbounds = config["outbounds"] as? [[String: Any]] ?? []
        for o in outbounds {
            guard let proto = o["protocol"] as? String,
                  XrayProfile.proxyProtocols.contains(proto) else { continue }
            let settings = o["settings"] as? [String: Any] ?? [:]
            if let vnext = settings["vnext"] as? [[String: Any]] {
                for v in vnext { if let a = v["address"] as? String { out.append(a) } }
            }
            if let servers = settings["servers"] as? [[String: Any]] {
                for s in servers { if let a = s["address"] as? String { out.append(a) } }
            }
        }
        return out
    }

    /// True when the only nodes are the "client not supported" / device-limit stubs.
    var isPlaceholder: Bool {
        let addrs = serverAddresses
        guard !addrs.isEmpty else { return true }
        return addrs.allSatisfy { $0 == "0.0.0.0" || $0 == "127.0.0.1" || $0.isEmpty }
    }
}

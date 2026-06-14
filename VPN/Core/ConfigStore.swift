import Foundation

/// Transforms a fetched profile into a config the bundled Xray (v1.8.23) can run,
/// and writes it to a temp file.
///
/// Key transforms (see project notes):
///  - Drop `xhttp` outbounds — v1.8.23 doesn't know that transport. Every region
///    also ships gRPC nodes, so connectivity is preserved.
///  - Replace routing with a simple "private → direct, everything → balancer" so we
///    don't depend on the provider's custom geosite categories (e.g. TORRENT).
///  - Force local SOCKS/HTTP inbounds on our chosen loopback ports.
///  - Add a burst observatory + leastPing balancer so dead nodes are avoided.
enum ConfigStore {

    static let privateCIDRs = ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12",
                               "192.168.0.0/16", "169.254.0.0/16", "::1/128",
                               "fc00::/7", "fe80::/10"]
    static let probeURL = "https://www.gstatic.com/generate_204"

    /// Returns a runnable config, or nil if the profile has no usable proxy nodes.
    static func makeRunnable(_ profile: XrayProfile, socks: Int, http: Int) -> [String: Any]? {
        guard let data = try? JSONSerialization.data(withJSONObject: profile.config),
              var cfg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        // --- outbounds ---
        var outbounds = (cfg["outbounds"] as? [[String: Any]]) ?? []
        outbounds = outbounds.filter { ob in
            let net = (ob["streamSettings"] as? [String: Any])?["network"] as? String
            return net != "xhttp"   // unsupported by v1.8.23
        }
        var proxyTags: [String] = []
        var hasDirect = false, hasBlock = false
        for i in outbounds.indices {
            if outbounds[i]["tag"] == nil { outbounds[i]["tag"] = "out-\(i)" }
            let tag = outbounds[i]["tag"] as? String ?? "out-\(i)"
            let proto = outbounds[i]["protocol"] as? String ?? ""
            if proto == "freedom", tag == "direct" { hasDirect = true }
            if proto == "blackhole", tag == "block" { hasBlock = true }
            if XrayProfile.proxyProtocols.contains(proto), !isPlaceholder(outbounds[i]) {
                proxyTags.append(tag)
            }
        }
        guard !proxyTags.isEmpty else { return nil }
        if !hasDirect { outbounds.append(["protocol": "freedom", "tag": "direct"]) }
        if !hasBlock  { outbounds.append(["protocol": "blackhole", "tag": "block"]) }
        cfg["outbounds"] = outbounds

        // --- inbounds ---
        var keep: [[String: Any]] = []
        var haveSocks = false, haveHttp = false
        for var ib in (cfg["inbounds"] as? [[String: Any]]) ?? [] {
            switch ib["protocol"] as? String {
            case "socks":
                ib["listen"] = "127.0.0.1"; ib["port"] = socks; haveSocks = true; keep.append(ib)
            case "http":
                ib["listen"] = "127.0.0.1"; ib["port"] = http; haveHttp = true; keep.append(ib)
            default:
                break
            }
        }
        if !haveSocks { keep.append(socksInbound(socks)) }
        if !haveHttp  { keep.append(httpInbound(http)) }
        cfg["inbounds"] = keep

        // --- routing ---
        cfg["routing"] = [
            "domainStrategy": "AsIs",
            "balancers": [["tag": "VPN_BAL", "selector": proxyTags,
                           "strategy": ["type": "leastPing"]]],
            "rules": [
                ["type": "field", "ip": privateCIDRs, "outboundTag": "direct"],
                ["type": "field", "network": "tcp,udp", "balancerTag": "VPN_BAL"]
            ]
        ]
        cfg["burstObservatory"] = [
            "subjectSelector": proxyTags,
            "pingConfig": ["destination": probeURL, "interval": "45s",
                           "timeout": "4s", "sampling": 2]
        ]
        cfg.removeValue(forKey: "observatory")
        cfg["dns"] = ["servers": ["1.1.1.1", "8.8.8.8"]]
        cfg["log"] = ["loglevel": "warning"]
        for k in ["stats", "policy", "api", "metrics", "fakedns"] { cfg.removeValue(forKey: k) }
        return cfg
    }

    static func writeTemp(_ cfg: [String: Any]) throws -> URL {
        let data = try JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vpn-\(UUID().uuidString).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - helpers

    private static func isPlaceholder(_ ob: [String: Any]) -> Bool {
        let settings = ob["settings"] as? [String: Any] ?? [:]
        var addrs: [String] = []
        if let vnext = settings["vnext"] as? [[String: Any]] {
            addrs += vnext.compactMap { $0["address"] as? String }
        }
        if let servers = settings["servers"] as? [[String: Any]] {
            addrs += servers.compactMap { $0["address"] as? String }
        }
        if addrs.isEmpty { return false }
        return addrs.allSatisfy { $0 == "0.0.0.0" || $0 == "127.0.0.1" || $0.isEmpty }
    }

    private static func socksInbound(_ port: Int) -> [String: Any] {
        ["tag": "socks", "protocol": "socks", "listen": "127.0.0.1", "port": port,
         "settings": ["udp": true, "auth": "noauth"],
         "sniffing": ["enabled": true, "destOverride": ["http", "tls"]]]
    }
    private static func httpInbound(_ port: Int) -> [String: Any] {
        ["tag": "http", "protocol": "http", "listen": "127.0.0.1", "port": port,
         "sniffing": ["enabled": true, "destOverride": ["http", "tls"]]]
    }
}

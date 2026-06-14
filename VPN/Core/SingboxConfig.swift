import Foundation

/// Builds a sing-box TUN config from a fetched profile, for system-wide mode.
///
/// sing-box (Catalina-safe v1.9.0) creates the utun, takes over the default route
/// (`auto_route`), and binds its own upstream connections to the physical interface
/// (`auto_detect_interface`) so the VPN's traffic to the servers doesn't loop back
/// through the tunnel. A `urltest` group auto-selects the fastest live node.
///
/// xhttp nodes are dropped (kept for parity with the proxy path); gRPC / REALITY /
/// Vision / WS / TCP nodes are translated to sing-box outbounds.
enum SingboxConfig {

    static func makeTUN(_ profile: XrayProfile) -> [String: Any]? {
        let xrayOutbounds = (profile.config["outbounds"] as? [[String: Any]]) ?? []
        var nodes: [[String: Any]] = []
        var tags: [String] = []

        for ob in xrayOutbounds {
            guard (ob["protocol"] as? String) == "vless" else { continue }
            let ss = ob["streamSettings"] as? [String: Any] ?? [:]
            if (ss["network"] as? String) == "xhttp" { continue }   // unsupported here
            guard let node = translateVLESS(ob) else { continue }
            let tag = (ob["tag"] as? String) ?? "node-\(tags.count)"
            var n = node; n["tag"] = tag
            nodes.append(n)
            tags.append(tag)
        }
        guard !tags.isEmpty else { return nil }

        var outbounds: [[String: Any]] = []
        outbounds.append([
            "type": "urltest", "tag": "auto", "outbounds": tags,
            "url": "https://www.gstatic.com/generate_204",
            "interval": "3m", "tolerance": 50
        ])
        outbounds.append(contentsOf: nodes)
        outbounds.append(["type": "direct", "tag": "direct"])
        outbounds.append(["type": "block", "tag": "block"])
        outbounds.append(["type": "dns", "tag": "dns-out"])

        return [
            "log": ["level": "warn", "timestamp": true],
            "dns": [
                "servers": [
                    ["tag": "remote", "address": "tls://8.8.8.8"],
                    ["tag": "local", "address": "https://1.1.1.1/dns-query", "detour": "direct"]
                ],
                // Resolve the proxy servers' own hostnames directly (anti-loop).
                "rules": [["outbound": "any", "server": "local"]],
                // ipv4_only: the tun has no IPv6 route, so don't let apps try AAAA.
                "strategy": "ipv4_only"
            ],
            "inbounds": [[
                "type": "tun", "tag": "tun-in",
                "inet4_address": "172.19.0.1/30",
                // Low MTU leaves room for VLESS/TLS/gRPC overhead so TLS handshakes
                // aren't dropped (the cause of the "SSL error" over the tunnel).
                "mtu": 1280,
                "auto_route": true,
                "strict_route": false,
                "stack": "gvisor",
                "sniff": true
            ]],
            "outbounds": outbounds,
            "route": [
                "auto_detect_interface": true,
                "rules": [
                    ["protocol": "dns", "outbound": "dns-out"],
                    ["ip_is_private": true, "outbound": "direct"]
                ],
                "final": "auto"
            ]
        ]
    }

    // MARK: - node translation

    private static func translateVLESS(_ ob: [String: Any]) -> [String: Any]? {
        let settings = ob["settings"] as? [String: Any] ?? [:]
        guard let vnext = (settings["vnext"] as? [[String: Any]])?.first,
              let address = vnext["address"] as? String, address != "0.0.0.0",
              let port = vnext["port"] as? Int,
              let user = (vnext["users"] as? [[String: Any]])?.first,
              let uuid = user["id"] as? String else { return nil }

        var node: [String: Any] = [
            "type": "vless", "server": address, "server_port": port, "uuid": uuid
        ]
        if let flow = user["flow"] as? String, !flow.isEmpty { node["flow"] = flow }

        let ss = ob["streamSettings"] as? [String: Any] ?? [:]
        let security = ss["security"] as? String ?? "none"
        let network = ss["network"] as? String ?? "tcp"

        // TLS / REALITY
        if security == "tls" {
            let t = ss["tlsSettings"] as? [String: Any] ?? [:]
            var tls: [String: Any] = ["enabled": true,
                                      "server_name": (t["serverName"] as? String) ?? address,
                                      "utls": ["enabled": true, "fingerprint": "chrome"]]
            if let alpn = t["alpn"] as? [String], !alpn.isEmpty { tls["alpn"] = alpn }
            if (t["allowInsecure"] as? Bool) == true { tls["insecure"] = true }
            node["tls"] = tls
        } else if security == "reality" {
            let r = ss["realitySettings"] as? [String: Any] ?? [:]
            var reality: [String: Any] = ["enabled": true]
            if let pbk = r["publicKey"] as? String { reality["public_key"] = pbk }
            if let sid = r["shortId"] as? String { reality["short_id"] = sid }
            let tls: [String: Any] = ["enabled": true,
                                      "server_name": (r["serverName"] as? String) ?? address,
                                      "utls": ["enabled": true,
                                               "fingerprint": (r["fingerprint"] as? String) ?? "chrome"],
                                      "reality": reality]
            node["tls"] = tls
        }

        // transport
        switch network {
        case "grpc":
            let g = ss["grpcSettings"] as? [String: Any] ?? [:]
            node["transport"] = ["type": "grpc", "service_name": (g["serviceName"] as? String) ?? ""]
        case "ws":
            let w = ss["wsSettings"] as? [String: Any] ?? [:]
            var transport: [String: Any] = ["type": "ws", "path": (w["path"] as? String) ?? "/"]
            if let headers = w["headers"] as? [String: Any], let host = headers["Host"] as? String {
                transport["headers"] = ["Host": host]
            }
            node["transport"] = transport
        case "http":
            let h = ss["httpSettings"] as? [String: Any] ?? [:]
            var transport: [String: Any] = ["type": "http"]
            if let path = h["path"] as? String { transport["path"] = path }
            node["transport"] = transport
        default:
            break   // tcp: no transport block
        }
        return node
    }
}

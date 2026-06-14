import Foundation

/// Builds Xray outbounds from classic share-link URIs (vless/vmess/trojan/ss),
/// used when a subscription returns a base64 URI list instead of a JSON config.
enum URIOutboundBuilder {

    /// Wraps parsed outbounds into a minimal config object (ConfigStore normalizes
    /// inbounds/routing/dns afterwards). Returns nil if no nodes parsed.
    static func wrap(uris: [String], name: String) -> [String: Any]? {
        var outbounds: [[String: Any]] = []
        for (i, uri) in uris.enumerated() {
            if var ob = outbound(from: uri) {
                ob["tag"] = "node-\(i)"
                outbounds.append(ob)
            }
        }
        guard !outbounds.isEmpty else { return nil }
        outbounds.append(["protocol": "freedom", "tag": "direct"])
        outbounds.append(["protocol": "blackhole", "tag": "block"])
        return ["remarks": name, "outbounds": outbounds]
    }

    static func outbound(from uri: String) -> [String: Any]? {
        let s = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("vless://")  { return vless(s) }
        if s.hasPrefix("trojan://") { return trojan(s) }
        if s.hasPrefix("vmess://")  { return vmess(s) }
        if s.hasPrefix("ss://")     { return shadowsocks(s) }
        return nil
    }

    // MARK: vless / trojan share a URL shape: scheme://cred@host:port?params#name

    private static func vless(_ uri: String) -> [String: Any]? {
        guard let c = URLComponents(string: uri),
              let host = c.host, let port = c.port, let id = c.user else { return nil }
        let q = query(c)
        var user: [String: Any] = ["id": id, "encryption": q["encryption"] ?? "none"]
        if let flow = q["flow"], !flow.isEmpty { user["flow"] = flow }
        let settings: [String: Any] = ["vnext": [["address": host, "port": port, "users": [user]]]]
        return ["protocol": "vless", "settings": settings,
                "streamSettings": streamSettings(host: host, q: q)]
    }

    private static func trojan(_ uri: String) -> [String: Any]? {
        guard let c = URLComponents(string: uri),
              let host = c.host, let port = c.port, let pw = c.user else { return nil }
        let q = query(c)
        let settings: [String: Any] = ["servers": [["address": host, "port": port, "password": pw]]]
        return ["protocol": "trojan", "settings": settings,
                "streamSettings": streamSettings(host: host, q: q, defaultSecurity: "tls")]
    }

    private static func vmess(_ uri: String) -> [String: Any]? {
        let b64 = String(uri.dropFirst("vmess://".count))
        guard let data = Data(base64Encoded: padded(b64)),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let host = j["add"] as? String else { return nil }
        let port = intValue(j["port"]) ?? 443
        let user: [String: Any] = ["id": j["id"] as? String ?? "",
                                   "alterId": intValue(j["aid"]) ?? 0,
                                   "security": "auto"]
        let settings: [String: Any] = ["vnext": [["address": host, "port": port, "users": [user]]]]
        var q: [String: String] = [:]
        q["type"] = (j["net"] as? String) ?? "tcp"
        q["security"] = ((j["tls"] as? String) == "tls") ? "tls" : "none"
        q["path"] = j["path"] as? String
        q["host"] = j["host"] as? String
        q["sni"] = j["sni"] as? String
        q["serviceName"] = j["path"] as? String
        return ["protocol": "vmess", "settings": settings,
                "streamSettings": streamSettings(host: host, q: q)]
    }

    private static func shadowsocks(_ uri: String) -> [String: Any]? {
        // ss://base64(method:password)@host:port#name  OR  ss://base64(method:password@host:port)#name
        var body = String(uri.dropFirst("ss://".count))
        if let hash = body.firstIndex(of: "#") { body = String(body[..<hash]) }
        var method = "", password = "", host = "", port = 0
        if let at = body.firstIndex(of: "@") {
            let credPart = String(body[..<at])
            let hostPart = String(body[body.index(after: at)...])
            if let d = Data(base64Encoded: padded(credPart)),
               let dec = String(data: d, encoding: .utf8),
               let colon = dec.firstIndex(of: ":") {
                method = String(dec[..<colon]); password = String(dec[dec.index(after: colon)...])
            }
            if let colon = hostPart.lastIndex(of: ":") {
                host = String(hostPart[..<colon]); port = Int(hostPart[hostPart.index(after: colon)...]) ?? 0
            }
        } else if let d = Data(base64Encoded: padded(body)),
                  let dec = String(data: d, encoding: .utf8),
                  let at = dec.firstIndex(of: "@") {
            let cred = String(dec[..<at]); let hp = String(dec[dec.index(after: at)...])
            if let colon = cred.firstIndex(of: ":") {
                method = String(cred[..<colon]); password = String(cred[cred.index(after: colon)...])
            }
            if let colon = hp.lastIndex(of: ":") {
                host = String(hp[..<colon]); port = Int(hp[hp.index(after: colon)...]) ?? 0
            }
        }
        guard !host.isEmpty, port > 0, !method.isEmpty else { return nil }
        let settings: [String: Any] = ["servers": [["address": host, "port": port,
                                                     "method": method, "password": password]]]
        return ["protocol": "shadowsocks", "settings": settings]
    }

    // MARK: - stream settings

    private static func streamSettings(host: String, q: [String: String],
                                       defaultSecurity: String = "none") -> [String: Any] {
        let network = q["type"] ?? "tcp"
        let security = q["security"] ?? defaultSecurity
        var ss: [String: Any] = ["network": network, "security": security]

        if security == "tls" {
            var tls: [String: Any] = ["serverName": q["sni"] ?? q["host"] ?? host]
            if let fp = q["fp"], !fp.isEmpty { tls["fingerprint"] = fp }
            if let alpn = q["alpn"], !alpn.isEmpty { tls["alpn"] = alpn.split(separator: ",").map(String.init) }
            ss["tlsSettings"] = tls
        } else if security == "reality" {
            var r: [String: Any] = ["serverName": q["sni"] ?? host]
            if let fp = q["fp"] { r["fingerprint"] = fp }
            if let pbk = q["pbk"] { r["publicKey"] = pbk }
            if let sid = q["sid"] { r["shortId"] = sid }
            if let spx = q["spx"] { r["spiderX"] = spx }
            ss["realitySettings"] = r
        }

        switch network {
        case "ws":
            var w: [String: Any] = ["path": q["path"] ?? "/"]
            if let h = q["host"], !h.isEmpty { w["headers"] = ["Host": h] }
            ss["wsSettings"] = w
        case "grpc":
            ss["grpcSettings"] = ["serviceName": q["serviceName"] ?? q["path"] ?? ""]
        case "tcp":
            break
        default:
            break
        }
        return ss
    }

    // MARK: - helpers

    private static func query(_ c: URLComponents) -> [String: String] {
        var out: [String: String] = [:]
        for item in c.queryItems ?? [] { out[item.name] = item.value ?? "" }
        return out
    }
    private static func padded(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let rem = t.count % 4
        if rem > 0 { t += String(repeating: "=", count: 4 - rem) }
        return t
    }
    private static func intValue(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let s = v as? String { return Int(s) }
        if let n = v as? NSNumber { return n.intValue }
        return nil
    }
}

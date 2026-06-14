import Foundation

/// Happ/Remnawave subscription metadata carried in HTTP response headers.
struct SubMetadata: Codable {
    var title: String?
    var used: Int64?
    var total: Int64?
    var expire: Date?
    var announce: String?
    var supportURL: String?
    var updateIntervalHours: Int?

    init() {}

    init(headers: [AnyHashable: Any]) {
        func h(_ key: String) -> String? {
            if let v = headers[key] as? String { return v }
            // header keys are case-insensitive
            for (k, v) in headers {
                if let ks = k as? String, ks.caseInsensitiveCompare(key) == .orderedSame {
                    return v as? String
                }
            }
            return nil
        }
        title = SubMetadata.decode(h("profile-title"))
        announce = SubMetadata.decode(h("announce"))
        supportURL = h("support-url")
        updateIntervalHours = h("profile-update-interval").flatMap { Int($0) }

        if let info = h("subscription-userinfo") {
            var kv: [String: String] = [:]
            for part in info.split(separator: ";") {
                let pair = part.split(separator: "=", maxSplits: 1)
                if pair.count == 2 {
                    kv[pair[0].trimmingCharacters(in: .whitespaces)] =
                        pair[1].trimmingCharacters(in: .whitespaces)
                }
            }
            let up = Int64(kv["upload"] ?? "0") ?? 0
            let dn = Int64(kv["download"] ?? "0") ?? 0
            used = up + dn
            total = Int64(kv["total"] ?? "0")
            if let e = kv["expire"], let t = TimeInterval(e), t > 0 {
                expire = Date(timeIntervalSince1970: t)
            }
        }
    }

    /// Decodes the `base64:...` header values Happ/Remnawave use.
    static func decode(_ raw: String?) -> String? {
        guard var s = raw else { return nil }
        if s.hasPrefix("base64:") { s.removeFirst("base64:".count) }
        if let d = Data(base64Encoded: s), let str = String(data: d, encoding: .utf8) {
            return str
        }
        return raw
    }

    /// Human-readable usage/expiry line, e.g. "34.6 GB used · expires Sep 7, 2026".
    var usageLine: String? {
        var parts: [String] = []
        if let used = used, used > 0 {
            parts.append("\(SubMetadata.bytes(used)) used")
        }
        if let exp = expire {
            let f = DateFormatter()
            f.dateStyle = .medium
            parts.append("expires \(f.string(from: exp))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        return f.string(fromByteCount: n)
    }
}

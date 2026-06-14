import Foundation

/// Detects the subscription body format and produces selectable profiles.
enum SubscriptionParser {

    static func parse(data: Data, fallbackName: String) throws -> [XrayProfile] {
        guard !data.isEmpty else { throw VPNError.emptyBody }

        // Path 1: JSON — a single Xray config object or an array of them.
        if let json = try? JSONSerialization.jsonObject(with: data) {
            if let arr = json as? [[String: Any]] {
                return arr.enumerated().map { idx, cfg in
                    XrayProfile(id: "\(idx)",
                                name: name(of: cfg, fallback: "\(fallbackName) \(idx + 1)"),
                                config: cfg)
                }
            }
            if let obj = json as? [String: Any] {
                return [XrayProfile(id: "0", name: name(of: obj, fallback: fallbackName), config: obj)]
            }
        }

        // Path 2: base64 (or raw) list of share-link URIs.
        if let text = decodeText(data) {
            let uris = text
                .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.contains("://") }
            if !uris.isEmpty {
                guard let cfg = URIOutboundBuilder.wrap(uris: uris, name: fallbackName) else {
                    throw VPNError.noNodes
                }
                return [XrayProfile(id: "0", name: fallbackName, config: cfg)]
            }
            if text.contains("proxies:") { throw VPNError.clashUnsupported }
        }

        throw VPNError.unknownFormat
    }

    private static func name(of cfg: [String: Any], fallback: String) -> String {
        if let r = cfg["remarks"] as? String, !r.trimmingCharacters(in: .whitespaces).isEmpty {
            return r
        }
        return fallback
    }

    /// Returns the body as text, base64-decoding it first if it looks base64.
    private static func decodeText(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) {
            let compact = s.replacingOccurrences(of: "\n", with: "")
                           .replacingOccurrences(of: "\r", with: "")
                           .trimmingCharacters(in: .whitespaces)
            // base64 charset only?
            let b64set = CharacterSet(charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
            if !compact.isEmpty,
               compact.unicodeScalars.allSatisfy({ b64set.contains($0) }),
               let d = Data(base64Encoded: pad(compact)),
               let decoded = String(data: d, encoding: .utf8),
               decoded.contains("://") {
                return decoded
            }
            return s
        }
        return nil
    }

    private static func pad(_ s: String) -> String {
        let rem = s.count % 4
        return rem == 0 ? s : s + String(repeating: "=", count: 4 - rem)
    }
}

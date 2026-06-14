import Foundation
import CFNetwork

/// Fetches a subscription URL with the Happ/v2RayTun request signature and parses
/// it into selectable profiles. Network only — persistence lives in AppModel.
final class SubscriptionManager {

    /// A session that ALWAYS connects directly, ignoring any system proxy. The
    /// subscription download is a control-plane call and must never be routed through
    /// (a possibly broken) VPN proxy — otherwise it fails with an SSL/connection error.
    private let session: URLSession = {
        let conf = URLSessionConfiguration.ephemeral
        conf.requestCachePolicy = .reloadIgnoringLocalCacheData
        conf.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 0,
            kCFNetworkProxiesHTTPSEnable as String: 0,
            kCFNetworkProxiesSOCKSEnable as String: 0
        ]
        return URLSession(configuration: conf)
    }()

    struct Fetched {
        let profiles: [XrayProfile]
        let meta: SubMetadata
        let raw: Data
    }

    /// v2RayTun UA → the provider serves a native Xray JSON config array.
    private let userAgent = "v2RayTun/2.0"

    func fetch(_ urlString: String,
               completion: @escaping (Result<Fetched, Error>) -> Void) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return onMain { completion(.failure(VPNError.badURL)) }
        }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(HWID.current(), forHTTPHeaderField: "x-hwid")
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")

        session.dataTask(with: req) { [weak self] data, resp, err in
            guard let self = self else { return }
            if let err = err {
                return self.onMain { completion(.failure(VPNError.network(err.localizedDescription))) }
            }
            guard let http = resp as? HTTPURLResponse else {
                return self.onMain { completion(.failure(VPNError.badResponse(0))) }
            }
            guard (200..<300).contains(http.statusCode) else {
                return self.onMain { completion(.failure(VPNError.badResponse(http.statusCode))) }
            }
            guard let data = data, !data.isEmpty else {
                return self.onMain { completion(.failure(VPNError.emptyBody)) }
            }

            let meta = SubMetadata(headers: http.allHeaderFields)
            do {
                let name = meta.title ?? url.host ?? "Subscription"
                let parsed = try SubscriptionParser.parse(data: data, fallbackName: name)
                let real = parsed.filter { !$0.isPlaceholder }
                if real.isEmpty {
                    let names = parsed.map { $0.name }
                    return self.onMain { completion(.failure(VPNError.deviceLimited(names))) }
                }
                self.onMain { completion(.success(Fetched(profiles: real, meta: meta, raw: data))) }
            } catch {
                self.onMain { completion(.failure(error)) }
            }
        }.resume()
    }

    private func onMain(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }
}

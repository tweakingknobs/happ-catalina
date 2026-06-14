import Foundation
import CFNetwork

/// Verifies the local SOCKS proxy actually provides egress by fetching a small
/// endpoint *through* it. Used as the real readiness signal (vs. just port-open),
/// and retried during balancer/observatory warmup.
enum EgressProbe {

    /// Performs one probe; calls completion(true) if traffic flowed through the proxy.
    static func check(socksPort: Int, timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        let conf = URLSessionConfiguration.ephemeral
        conf.requestCachePolicy = .reloadIgnoringLocalCacheData
        conf.timeoutIntervalForRequest = timeout
        conf.timeoutIntervalForResource = timeout
        conf.connectionProxyDictionary = [
            kCFNetworkProxiesSOCKSEnable as String: 1,
            kCFNetworkProxiesSOCKSProxy as String: "127.0.0.1",
            kCFNetworkProxiesSOCKSPort as String: socksPort
        ]
        let session = URLSession(configuration: conf)
        guard let url = URL(string: "https://www.gstatic.com/generate_204") else {
            completion(false); return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        let task = session.dataTask(with: req) { _, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let ok = (err == nil) && (code == 204 || (200..<400).contains(code))
            session.finishTasksAndInvalidate()
            completion(ok)
        }
        task.resume()
    }

    /// Retries the SOCKS probe every `interval` seconds until success or `deadline`.
    static func waitForEgress(socksPort: Int, deadline: TimeInterval,
                              interval: TimeInterval = 2.5,
                              completion: @escaping (Bool) -> Void) {
        wait(deadline: deadline, interval: interval,
             attempt: { cb in check(socksPort: socksPort, timeout: 6, completion: cb) },
             completion: completion)
    }

    /// Plain connectivity check (no proxy). In TUN mode this traverses the tunnel.
    static func checkDirect(timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        let conf = URLSessionConfiguration.ephemeral
        conf.requestCachePolicy = .reloadIgnoringLocalCacheData
        conf.timeoutIntervalForRequest = timeout
        conf.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: conf)
        guard let url = URL(string: "https://www.gstatic.com/generate_204") else {
            completion(false); return
        }
        var req = URLRequest(url: url); req.timeoutInterval = timeout
        session.dataTask(with: req) { _, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let ok = (err == nil) && (code == 204 || (200..<400).contains(code))
            session.finishTasksAndInvalidate()
            completion(ok)
        }.resume()
    }

    /// Retries a plain connectivity check until success or `deadline` (TUN warmup).
    static func waitForGeneralEgress(deadline: TimeInterval, interval: TimeInterval = 2.5,
                                     completion: @escaping (Bool) -> Void) {
        wait(deadline: deadline, interval: interval,
             attempt: { cb in checkDirect(timeout: 6, completion: cb) },
             completion: completion)
    }

    private static func wait(deadline: TimeInterval, interval: TimeInterval,
                             attempt: @escaping (@escaping (Bool) -> Void) -> Void,
                             completion: @escaping (Bool) -> Void) {
        let start = Date()
        func go() {
            attempt { ok in
                if ok { DispatchQueue.main.async { completion(true) }; return }
                if Date().timeIntervalSince(start) >= deadline {
                    DispatchQueue.main.async { completion(false) }; return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + interval) { go() }
            }
        }
        go()
    }
}

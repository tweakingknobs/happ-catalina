import Foundation

/// App-side XPC client for the privileged helper.
final class HelperClient {

    private var connection: NSXPCConnection?

    private func proxy(_ onError: @escaping (Error) -> Void) -> VPNHelperProtocol? {
        if connection == nil {
            let c = NSXPCConnection(machServiceName: kHelperMachLabel, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: VPNHelperProtocol.self)
            c.invalidationHandler = { [weak self] in self?.connection = nil }
            c.interruptionHandler = { [weak self] in self?.connection = nil }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler(onError) as? VPNHelperProtocol
    }

    func startTUN(config: [String: Any], completion: @escaping (Bool, String) -> Void) {
        guard let data = try? JSONSerialization.data(withJSONObject: config) else {
            completion(false, "Couldn't encode tunnel config."); return
        }
        guard let p = proxy({ e in main { completion(false, e.localizedDescription) } }) else {
            completion(false, "Helper unavailable."); return
        }
        p.startTUN(configJSON: data) { ok, msg in main { completion(ok, msg) } }
    }

    func stopTUN(completion: @escaping (Bool, String) -> Void) {
        guard let p = proxy({ e in main { completion(false, e.localizedDescription) } }) else {
            completion(false, "Helper unavailable."); return
        }
        p.stopTUN { ok, msg in main { completion(ok, msg) } }
    }

    func status(completion: @escaping (Bool) -> Void) {
        guard let p = proxy({ _ in main { completion(false) } }) else { completion(false); return }
        p.getStatus { running, _ in main { completion(running) } }
    }

    func uninstall(completion: @escaping (Bool) -> Void) {
        guard let p = proxy({ _ in main { completion(false) } }) else { completion(false); return }
        p.uninstall { ok in main { completion(ok) }; self.connection?.invalidate(); self.connection = nil }
    }

    func invalidate() { connection?.invalidate(); connection = nil }

    /// Synchronous best-effort stop for app-quit cleanup. Safe to call from the main
    /// thread: the XPC reply arrives on the connection's private queue, not main.
    func stopTUNSync(timeout: TimeInterval) {
        let sem = DispatchSemaphore(value: 0)
        let c = NSXPCConnection(machServiceName: kHelperMachLabel, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: VPNHelperProtocol.self)
        c.resume()
        let p = c.remoteObjectProxyWithErrorHandler { _ in sem.signal() } as? VPNHelperProtocol
        if let p = p { p.stopTUN { _, _ in sem.signal() } } else { sem.signal() }
        _ = sem.wait(timeout: .now() + timeout)
        c.invalidate()
    }
}

private func main(_ block: @escaping () -> Void) { DispatchQueue.main.async(execute: block) }

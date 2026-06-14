import Foundation
import Darwin

/// Finds free loopback TCP ports for the local SOCKS/HTTP inbounds.
enum PortFinder {
    /// Returns a (socks, http) pair, preferring the conventional 10808/10809
    /// but falling back if they're taken (e.g. another proxy client is running).
    static func freePair() -> (socks: Int, http: Int) {
        let preferred: [(Int, Int)] = [(10808, 10809), (11808, 11809), (12808, 12809)]
        for (s, h) in preferred where isFree(s) && isFree(h) {
            return (s, h)
        }
        // last resort: ask the OS for two ephemeral ports
        let s = ephemeral() ?? 10808
        let h = ephemeral() ?? 10809
        return (s, h)
    }

    static func isFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }

    private static func ephemeral() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 { return nil }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        var bound_addr = sockaddr_in()
        let ok = withUnsafeMutablePointer(to: &bound_addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        if ok != 0 { return nil }
        return Int(UInt16(bigEndian: bound_addr.sin_port))
    }
}

import Foundation

/// Toggles the macOS system SOCKS + HTTP/HTTPS proxy to point at our local Xray,
/// and reliably restores the previous settings on disconnect / quit / crash.
///
/// Strategy: build all `networksetup` commands for the active network services and
/// try to run them directly (works for admin users on many setups, no prompt).
/// If that fails, run the whole batch once via `osascript ... with administrator
/// privileges` — a single password prompt for the entire operation.
enum SystemProxy {

    private static let networksetup = "/usr/sbin/networksetup"

    // MARK: - Snapshot model

    struct Snapshot: Codable {
        struct Entry: Codable {
            var service: String
            var socksEnabled: Bool; var socksHost: String; var socksPort: String
            var webEnabled: Bool;   var webHost: String;   var webPort: String
            var secEnabled: Bool;   var secHost: String;   var secPort: String
        }
        var entries: [Entry]
    }

    static var backupURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VPN", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("proxy-backup.json")
    }

    // MARK: - Public API

    /// Snapshots current state, persists it, then routes the system proxy to us.
    @discardableResult
    static func enable(socksPort: Int, httpPort: Int) -> Bool {
        let services = activeServices()
        guard !services.isEmpty else { return false }
        let snap = snapshot(services: services)
        saveBackup(snap)

        var cmds: [[String]] = []
        for s in services {
            cmds.append(["-setsocksfirewallproxy", s, "127.0.0.1", "\(socksPort)"])
            cmds.append(["-setsocksfirewallproxystate", s, "on"])
            cmds.append(["-setwebproxy", s, "127.0.0.1", "\(httpPort)"])
            cmds.append(["-setwebproxystate", s, "on"])
            cmds.append(["-setsecurewebproxy", s, "127.0.0.1", "\(httpPort)"])
            cmds.append(["-setsecurewebproxystate", s, "on"])
        }
        let ok = apply(cmds)
        if !ok { clearBackup() }   // nothing changed; don't leave a stale backup
        return ok
    }

    /// Restores the snapshot saved by `enable` (or just turns proxies off).
    static func disableAndRestore() {
        if let snap = loadBackup() {
            restore(snap)
        } else {
            var cmds: [[String]] = []
            for s in activeServices() {
                cmds.append(["-setsocksfirewallproxystate", s, "off"])
                cmds.append(["-setwebproxystate", s, "off"])
                cmds.append(["-setsecurewebproxystate", s, "off"])
            }
            _ = apply(cmds)
        }
        clearBackup()
    }

    /// Restores a snapshot's exact previous values (host/port/enabled per service).
    static func restore(_ snap: Snapshot) {
        var cmds: [[String]] = []
        for e in snap.entries {
            cmds.append(["-setsocksfirewallproxy", e.service,
                         e.socksHost.isEmpty ? "127.0.0.1" : e.socksHost,
                         e.socksPort.isEmpty ? "0" : e.socksPort])
            cmds.append(["-setsocksfirewallproxystate", e.service, e.socksEnabled ? "on" : "off"])
            cmds.append(["-setwebproxy", e.service,
                         e.webHost.isEmpty ? "127.0.0.1" : e.webHost,
                         e.webPort.isEmpty ? "0" : e.webPort])
            cmds.append(["-setwebproxystate", e.service, e.webEnabled ? "on" : "off"])
            cmds.append(["-setsecurewebproxy", e.service,
                         e.secHost.isEmpty ? "127.0.0.1" : e.secHost,
                         e.secPort.isEmpty ? "0" : e.secPort])
            cmds.append(["-setsecurewebproxystate", e.service, e.secEnabled ? "on" : "off"])
        }
        _ = apply(cmds)
    }

    /// True if a crash left a backup behind (proxy possibly still pointing at us).
    static func hasPendingBackup() -> Bool {
        FileManager.default.fileExists(atPath: backupURL.path)
    }

    // MARK: - Service discovery & snapshot

    static func activeServices() -> [String] {
        guard let out = readOutput([ "-listallnetworkservices" ]) else { return [] }
        return out.split(separator: "\n").dropFirst()      // first line is a legend
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("*") }    // "*Name" = disabled
    }

    private static func snapshot(services: [String]) -> Snapshot {
        var entries: [Snapshot.Entry] = []
        for s in services {
            let socks = parseGet(readOutput(["-getsocksfirewallproxy", s]))
            let web   = parseGet(readOutput(["-getwebproxy", s]))
            let sec   = parseGet(readOutput(["-getsecurewebproxy", s]))
            entries.append(.init(service: s,
                                 socksEnabled: socks.enabled, socksHost: socks.host, socksPort: socks.port,
                                 webEnabled: web.enabled, webHost: web.host, webPort: web.port,
                                 secEnabled: sec.enabled, secHost: sec.host, secPort: sec.port))
        }
        return Snapshot(entries: entries)
    }

    private static func parseGet(_ text: String?) -> (enabled: Bool, host: String, port: String) {
        guard let text = text else { return (false, "", "") }
        var enabled = false, host = "", port = ""
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "Enabled": enabled = (parts[1].lowercased() == "yes")
            case "Server":  host = parts[1]
            case "Port":    port = parts[1]
            default: break
            }
        }
        return (enabled, host, port)
    }

    // MARK: - Backup persistence

    private static func saveBackup(_ snap: Snapshot) {
        if let data = try? JSONEncoder().encode(snap) { try? data.write(to: backupURL, options: .atomic) }
    }
    private static func loadBackup() -> Snapshot? {
        guard let data = try? Data(contentsOf: backupURL) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
    private static func clearBackup() {
        try? FileManager.default.removeItem(at: backupURL)
    }

    // MARK: - Command execution

    /// Runs each networksetup command directly; if any needs privileges, re-runs the
    /// whole batch once with an admin prompt.
    private static func apply(_ cmds: [[String]]) -> Bool {
        guard !cmds.isEmpty else { return true }
        var needsAdmin = false
        for c in cmds {
            if runStatus(networksetup, c) != 0 { needsAdmin = true; break }
        }
        if !needsAdmin { return true }
        return applyWithAdmin(cmds)
    }

    private static func applyWithAdmin(_ cmds: [[String]]) -> Bool {
        // Write a temp shell script (handles service names with spaces cleanly).
        let script = cmds.map { c in
            ([networksetup] + c).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
                .joined(separator: " ")
        }.joined(separator: "\n")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vpn-proxy-\(UUID().uuidString).sh")
        guard (try? script.write(to: tmp, atomically: true, encoding: .utf8)) != nil else { return false }
        defer { try? FileManager.default.removeItem(at: tmp) }

        let apple = "do shell script \"/bin/sh \\\"\(tmp.path)\\\"\" with administrator privileges"
        return runStatus("/usr/bin/osascript", ["-e", apple]) == 0
    }

    // MARK: - Process helpers

    @discardableResult
    private static func runStatus(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    private static func readOutput(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: networksetup)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

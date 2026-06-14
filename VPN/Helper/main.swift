import Foundation

/// Appends a line to the helper log (root-writable).
func hlog(_ message: String) {
    let line = "[\(Date())] \(message)\n"
    let data = line.data(using: .utf8) ?? Data()
    if let fh = FileHandle(forWritingAtPath: kHelperLogPath) {
        fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: kHelperLogPath, contents: data)
    }
}

/// Privileged helper. Installed as a root LaunchDaemon; vends an XPC mach service the
/// app uses to start/stop the system-wide tunnel. It runs the bundled sing-box and,
/// crucially, GUARANTEES the routing table is restored when the tunnel stops or dies —
/// so a non-working tunnel can never leave the Mac offline.
final class HelperService: NSObject, NSXPCListenerDelegate, VPNHelperProtocol {

    private var singbox: Process?
    private var intentionalStop = false
    private var savedGateway: String?
    private var savedInterface: String?
    private let queue = DispatchQueue(label: "ru.local.vpn.helper.work")

    // MARK: NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        hlog("accepting connection from pid \(conn.processIdentifier)")
        conn.exportedInterface = NSXPCInterface(with: VPNHelperProtocol.self)
        conn.exportedObject = self
        conn.resume()
        return true
    }

    // MARK: VPNHelperProtocol

    func startTUN(configJSON: Data, withReply reply: @escaping (Bool, String) -> Void) {
        queue.async {
            hlog("startTUN: \(configJSON.count) bytes")
            do {
                try configJSON.write(to: URL(fileURLWithPath: kHelperConfigPath), options: .atomic)
            } catch {
                reply(false, "write config failed: \(error.localizedDescription)"); return
            }
            self.stopSingbox(restore: false)   // stop any previous; a new one is coming
            self.saveDefaultRoute()            // remember the real route to restore later

            let sb = Process()
            sb.executableURL = URL(fileURLWithPath: kSingboxInstalledPath)
            sb.arguments = ["run", "-c", kHelperConfigPath]
            let logURL = URL(fileURLWithPath: kHelperInstallDir + "/singbox.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            if let fh = try? FileHandle(forWritingTo: logURL) {
                sb.standardOutput = fh; sb.standardError = fh
            }
            // If sing-box dies on its own, restore routing immediately.
            sb.terminationHandler = { [weak self] _ in
                guard let self = self else { return }
                self.queue.async {
                    guard !self.intentionalStop, self.singbox != nil else { return }
                    hlog("sing-box exited unexpectedly — restoring routing")
                    self.singbox = nil
                    self.restoreRouting()
                }
            }
            self.intentionalStop = false
            do { try sb.run() } catch {
                hlog("sing-box launch failed: \(error)")
                self.restoreRouting()
                reply(false, "sing-box launch failed: \(error.localizedDescription)"); return
            }
            self.singbox = sb
            hlog("sing-box started pid \(sb.processIdentifier)")
            reply(true, "started")
        }
    }

    func stopTUN(withReply reply: @escaping (Bool, String) -> Void) {
        queue.async { self.stopSingbox(restore: true); reply(true, "stopped") }
    }

    func getStatus(withReply reply: @escaping (Bool, String) -> Void) {
        queue.async { reply(self.singbox?.isRunning ?? false, kHelperVersion) }
    }

    func uninstall(withReply reply: @escaping (Bool) -> Void) {
        queue.async {
            self.stopSingbox(restore: true)
            reply(true)
            let script = "/bin/launchctl bootout system \(kHelperPlistPath) 2>/dev/null; " +
                         "/bin/rm -f \(kHelperPlistPath); /bin/rm -rf '\(kHelperInstallDir)'"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", script]
            try? p.run()
        }
    }

    // MARK: - sing-box lifecycle

    private func stopSingbox(restore: Bool) {
        let wasRunning = singbox?.isRunning ?? false
        intentionalStop = true
        if let p = singbox, p.isRunning {
            p.terminate()                                   // SIGTERM -> sing-box restores routes
            let deadline = Date().addingTimeInterval(8)
            while p.isRunning && Date() < deadline { usleep(100_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL); usleep(500_000) }
        }
        singbox = nil
        // Kill ANY leftover/orphaned sing-box (e.g. from an older helper) that could
        // still be holding tun routes — otherwise the next start fails with
        // "add route: ...: file exists".
        sh("/usr/bin/pkill", ["-f", "/Library/Application Support/VPN/sing-box"])
        usleep(700_000)                                     // let the utun + its routes tear down
        deleteTunRoutes()                                   // sweep any dangling utun routes
        if restore && wasRunning { restoreRouting() }
    }

    /// Deletes any IPv4 routes still pointing at a utun interface (leftover sing-box
    /// routes). Safe here because the physical default route is on en0/Wi-Fi.
    private func deleteTunRoutes() {
        let out = capture("/usr/sbin/netstat", ["-rn", "-f", "inet"])
        for raw in out.split(separator: "\n") {
            let line = String(raw)
            guard line.contains("utun") else { continue }
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let dest = cols.first, dest != "default", dest != "Destination" else { continue }
            sh("/sbin/route", ["-n", "delete", dest])
        }
    }

    // MARK: - routing safety net

    private func saveDefaultRoute() {
        let out = capture("/sbin/route", ["-n", "get", "default"])
        var gw: String?, iff: String?
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("gateway:") {
                gw = String(line.dropFirst("gateway:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("interface:") {
                iff = String(line.dropFirst("interface:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        // Don't overwrite a good saved value with a tunnel interface.
        if let iff = iff, !iff.hasPrefix("utun") {
            savedInterface = iff
            savedGateway = gw
            hlog("saved default route gw=\(gw ?? "-") if=\(iff)")
        }
    }

    /// Guarantees a working physical default route after the tunnel goes away.
    private func restoreRouting() {
        // 1. Remove sing-box auto_route split routes (harmless if absent).
        sh("/sbin/route", ["-n", "delete", "-net", "0.0.0.0/1"])
        sh("/sbin/route", ["-n", "delete", "-net", "128.0.0.0/1"])
        // 2. Drop any default route still pointing at a tunnel.
        if capture("/sbin/route", ["-n", "get", "default"]).contains("utun") {
            sh("/sbin/route", ["-n", "delete", "default"])
        }
        // 3. Re-add the saved physical gateway.
        if let gw = savedGateway, !gw.isEmpty {
            sh("/sbin/route", ["-n", "add", "default", gw])
            sh("/sbin/route", ["-n", "change", "default", gw])
        }
        // 4. Catch-all: renew DHCP on the physical interface (rebuilds the route).
        if let iff = savedInterface { sh("/usr/sbin/ipconfig", ["set", iff, "DHCP"]) }
        hlog("restoreRouting done (gw=\(savedGateway ?? "-") if=\(savedInterface ?? "-"))")
    }

    // MARK: - process helpers

    private func capture(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: d, encoding: .utf8) ?? ""
    }
    @discardableResult
    private func sh(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

// MARK: - entry point

hlog("helper launched (v\(kHelperVersion))")
let service = HelperService()
let listener = NSXPCListener(machServiceName: kHelperMachLabel)
listener.delegate = service
listener.resume()
RunLoop.main.run()

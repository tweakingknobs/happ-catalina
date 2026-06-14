import Foundation

/// Launches and supervises the bundled Xray process.
final class XrayRunner {
    private var process: Process?
    private var intentionalStop = false
    private(set) var configURL: URL?
    private let killQueue = DispatchQueue(label: "ru.local.vpn.xray.kill")

    /// Forwarded log lines (already newline-delimited chunks from Xray).
    var onLog: ((String) -> Void)?
    /// Called when Xray exits without us asking it to.
    var onUnexpectedExit: (() -> Void)?

    var isRunning: Bool { process?.isRunning ?? false }

    func start(configURL: URL) throws {
        stop()  // ensure no stale process
        let bin = try XrayBinary.prepared()
        let p = Process()
        p.executableURL = bin
        p.arguments = ["run", "-c", configURL.path]
        var env = ProcessInfo.processInfo.environment
        if let asset = XrayBinary.assetDir()?.path { env["XRAY_LOCATION_ASSET"] = asset }
        p.environment = env

        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        let handler: (FileHandle) -> Void = { [weak self] fh in
            let d = fh.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            self?.onLog?(s)
        }
        outPipe.fileHandleForReading.readabilityHandler = handler
        errPipe.fileHandleForReading.readabilityHandler = handler

        p.terminationHandler = { [weak self] _ in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            guard let self = self else { return }
            if !self.intentionalStop {
                DispatchQueue.main.async { self.onUnexpectedExit?() }
            }
        }

        do { try p.run() }
        catch { throw VPNError.launchFailed(error.localizedDescription) }

        process = p
        self.configURL = configURL
        intentionalStop = false
    }

    func stop() {
        intentionalStop = true
        if let p = process, p.isRunning {
            let pid = p.processIdentifier
            p.terminate()
            killQueue.asyncAfter(deadline: .now() + 3) {
                if p.isRunning { kill(pid, SIGKILL) }
            }
        }
        process = nil
        if let c = configURL { try? FileManager.default.removeItem(at: c) }
        configURL = nil
    }
}

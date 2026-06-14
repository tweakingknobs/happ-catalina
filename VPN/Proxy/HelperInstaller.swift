import Foundation

/// Installs/uninstalls the privileged helper LaunchDaemon. Installation needs one
/// admin prompt (ever); after that the helper runs as root on demand with no prompts.
enum HelperInstaller {

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: kHelperBinPath) &&
        FileManager.default.fileExists(atPath: kHelperPlistPath) &&
        FileManager.default.fileExists(atPath: kSingboxInstalledPath)
    }

    /// Version of the currently-installed helper (nil if unknown/not installed).
    static var installedVersion: String? {
        (try? String(contentsOfFile: kHelperVersionPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True if the helper is missing or older than the one bundled in this app.
    static var needsInstall: Bool {
        !isInstalled || installedVersion != kHelperVersion
    }

    /// Copies helper + sing-box + LaunchDaemon plist into place and loads the daemon.
    /// Returns (success, message). Shows a single admin-password prompt.
    static func install() -> (ok: Bool, message: String) {
        guard let res = Bundle.main.resourceURL else { return (false, "No app bundle.") }
        let helperSrc = res.appendingPathComponent("helper/vpnhelper").path
        let singboxSrc = res.appendingPathComponent("singbox/sing-box").path
        let plistSrc = res.appendingPathComponent("helper/ru.local.vpn.helper.plist").path
        for p in [helperSrc, singboxSrc, plistSrc] where !FileManager.default.fileExists(atPath: p) {
            return (false, "Missing bundled component: \((p as NSString).lastPathComponent)")
        }

        let script = """
        set -e
        mkdir -p "\(kHelperInstallDir)"
        cp "\(helperSrc)" "\(kHelperBinPath)"
        cp "\(singboxSrc)" "\(kSingboxInstalledPath)"
        cp "\(plistSrc)" "\(kHelperPlistPath)"
        chown root:wheel "\(kHelperBinPath)" "\(kSingboxInstalledPath)" "\(kHelperPlistPath)" "\(kHelperInstallDir)"
        chmod 755 "\(kHelperBinPath)" "\(kSingboxInstalledPath)"
        chmod 644 "\(kHelperPlistPath)"
        xattr -dr com.apple.quarantine "\(kHelperInstallDir)" 2>/dev/null || true
        launchctl bootout system "\(kHelperPlistPath)" 2>/dev/null || true
        launchctl bootstrap system "\(kHelperPlistPath)" 2>/dev/null || launchctl load -w "\(kHelperPlistPath)"
        printf '%s' '\(kHelperVersion)' > "\(kHelperVersionPath)"
        """
        return runAdmin(script, prompt: "VPN wants to install its system-wide VPN helper.")
    }

    /// Removes the daemon + files (admin prompt). Prefer the helper's own uninstall
    /// (no prompt) when the helper is reachable; this is the fallback.
    static func uninstall() -> (ok: Bool, message: String) {
        let script = """
        launchctl bootout system "\(kHelperPlistPath)" 2>/dev/null || true
        rm -f "\(kHelperPlistPath)"
        rm -rf "\(kHelperInstallDir)"
        """
        return runAdmin(script, prompt: "VPN wants to remove its system-wide VPN helper.")
    }

    // MARK: - admin execution (osascript -> single password prompt)

    private static func runAdmin(_ shellScript: String, prompt: String) -> (Bool, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vpn-helper-install-\(UUID().uuidString).sh")
        do { try shellScript.write(to: tmp, atomically: true, encoding: .utf8) }
        catch { return (false, "Couldn't stage installer.") }
        defer { try? FileManager.default.removeItem(at: tmp) }

        let apple = "do shell script \"/bin/sh \\\"\(tmp.path)\\\"\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", apple]
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return (false, error.localizedDescription) }
        p.waitUntilExit()
        if p.terminationStatus == 0 { return (true, "Installed.") }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let msg = String(data: errData, encoding: .utf8) ?? ""
        if msg.contains("-128") || msg.lowercased().contains("cancel") {
            return (false, "Installation cancelled.")
        }
        return (false, msg.isEmpty ? "Installation failed." : msg)
    }
}

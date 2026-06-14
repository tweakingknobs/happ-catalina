import Foundation

/// Locates and prepares the bundled Xray-core executable.
enum XrayBinary {

    /// Resources/xray/xray inside the .app bundle.
    static func binaryURL() -> URL? {
        if let u = Bundle.main.url(forResource: "xray", withExtension: nil, subdirectory: "xray") {
            return u
        }
        return Bundle.main.resourceURL?.appendingPathComponent("xray/xray")
    }

    /// Directory holding geoip.dat / geosite.dat (XRAY_LOCATION_ASSET).
    static func assetDir() -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent("xray")
    }

    /// Ensures the binary is present, executable, and de-quarantined.
    static func prepared() throws -> URL {
        guard let u = binaryURL(), FileManager.default.fileExists(atPath: u.path) else {
            throw VPNError.binaryMissing
        }
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: u.path),
           let perms = attrs[.posixPermissions] as? NSNumber,
           (perms.uint16Value & 0o111) == 0 {
            try? fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: u.path)
        }
        // Best-effort: clear quarantine so Gatekeeper doesn't block the exec.
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-d", "com.apple.quarantine", u.path]
        xattr.standardError = FileHandle.nullDevice
        xattr.standardOutput = FileHandle.nullDevice
        try? xattr.run()
        xattr.waitUntilExit()
        return u
    }
}

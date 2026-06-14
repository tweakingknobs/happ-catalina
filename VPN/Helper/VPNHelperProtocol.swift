import Foundation

/// XPC contract between the app and the privileged helper. Compiled into BOTH the
/// app and the helper executable.
@objc(VPNHelperProtocol) protocol VPNHelperProtocol {
    /// Writes the sing-box config and (re)starts the tunnel as root.
    func startTUN(configJSON: Data, withReply reply: @escaping (Bool, String) -> Void)
    /// Stops the tunnel; sing-box restores the routing table on clean shutdown.
    func stopTUN(withReply reply: @escaping (Bool, String) -> Void)
    /// (isRunning, helperVersion)
    func getStatus(withReply reply: @escaping (Bool, String) -> Void)
    /// Stops the tunnel and removes the helper + LaunchDaemon.
    func uninstall(withReply reply: @escaping (Bool) -> Void)
}

// Shared install locations / identifiers.
let kHelperMachLabel    = "ru.local.vpn.helper"
let kHelperVersion      = "1.3"
let kHelperVersionPath  = "/Library/Application Support/VPN/helper-version"
let kHelperInstallDir   = "/Library/Application Support/VPN"
let kHelperBinPath      = "/Library/Application Support/VPN/vpnhelper"
let kSingboxInstalledPath = "/Library/Application Support/VPN/sing-box"
let kHelperConfigPath   = "/Library/Application Support/VPN/tun.json"
let kHelperLogPath      = "/Library/Application Support/VPN/helper.log"
let kHelperPlistPath    = "/Library/LaunchDaemons/ru.local.vpn.helper.plist"

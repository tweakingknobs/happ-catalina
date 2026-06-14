import Foundation

/// A stored subscription. The raw response body is kept so profiles can be
/// re-parsed on launch without a network round-trip.
struct StoredSubscription: Codable {
    var url: String
    var title: String
    var rawBase64: String
    var meta: SubMetadata
    var fetchedAt: Date

    var rawData: Data { Data(base64Encoded: rawBase64) ?? Data() }
}

/// Central app state + orchestration. UI observes `onChange`.
final class AppModel {

    /// Optionally pre-fill the "Add subscription" field with your own subscription URL.
    /// Left empty so no personal subscription key ships in the repository.
    static let demoURL = ""

    /// How traffic is tunneled.
    enum TunnelMode: String {
        case proxy   // local SOCKS/HTTP + system proxy (Xray) — no admin after first proxy set
        case tun     // system-wide TUN via privileged helper (sing-box) — all apps
        var label: String { self == .tun ? "System-wide (TUN)" : "Proxy only" }
    }

    // Observers
    var onChange: (() -> Void)?

    // Persisted
    private(set) var subscriptions: [StoredSubscription] = []
    private(set) var selectedSubIndex: Int = 0
    private(set) var selectedProfileId: String = "0"

    // Runtime
    private(set) var state: ConnectionState = .disconnected
    private(set) var lastError: String?
    private(set) var profiles: [XrayProfile] = []
    private(set) var mode: TunnelMode = .proxy
    private var activePorts: (socks: Int, http: Int)?

    private let runner = XrayRunner()
    private let subs = SubscriptionManager()
    private let helper = HelperClient()

    private let defaults = UserDefaults.standard
    private let kSubs = "subscriptions"
    private let kSelSub = "selectedSubIndex"
    private let kSelProfile = "selectedProfileId"
    private let kMode = "tunnelMode"

    var helperInstalled: Bool { HelperInstaller.isInstalled }

    // MARK: - Lifecycle

    init() {
        loadPersisted()
        reparseProfiles()
        runner.onUnexpectedExit = { [weak self] in self?.handleUnexpectedExit() }
        runner.onLog = { line in
            #if DEBUG
            FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
            #endif
        }
    }

    /// Restores the system proxy / tears down a leftover tunnel if a previous run
    /// crashed while connected — so a crash can never leave the Mac stranded.
    func recoverFromCrashIfNeeded() {
        if SystemProxy.hasPendingBackup() {
            SystemProxy.disableAndRestore()
        }
        if FileManager.default.fileExists(atPath: tunMarker.path) {
            if HelperInstaller.isInstalled { helper.stopTUNSync(timeout: 8) }
            setTunMarker(false)
        }
    }

    private var appSupportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VPN", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private var tunMarker: URL { appSupportDir.appendingPathComponent("tun-active") }
    private func setTunMarker(_ on: Bool) {
        if on { try? Data().write(to: tunMarker) }
        else { try? FileManager.default.removeItem(at: tunMarker) }
    }

    // MARK: - Derived UI state

    var currentSubscription: StoredSubscription? {
        guard subscriptions.indices.contains(selectedSubIndex) else { return nil }
        return subscriptions[selectedSubIndex]
    }
    var meta: SubMetadata? { currentSubscription?.meta }
    var hasSubscription: Bool { !subscriptions.isEmpty }
    var selectedProfileName: String? {
        profiles.first { $0.id == selectedProfileId }?.name ?? profiles.first?.name
    }
    var isConnected: Bool { state.isConnected }
    var isBusy: Bool { state.isBusy }

    // MARK: - Selection

    func selectProfile(_ id: String) {
        selectedProfileId = id
        defaults.set(id, forKey: kSelProfile)
        notify()
        if isConnected || isBusy { connect() }   // re-connect through the new region
    }

    func selectSubscription(_ index: Int) {
        guard subscriptions.indices.contains(index) else { return }
        selectedSubIndex = index
        defaults.set(index, forKey: kSelSub)
        reparseProfiles()
        selectedProfileId = profiles.first?.id ?? "0"
        defaults.set(selectedProfileId, forKey: kSelProfile)
        notify()
    }

    // MARK: - Connection

    func toggle() { isConnected || isBusy ? disconnect() : connect() }

    func setMode(_ m: TunnelMode) {
        guard m != mode else { return }
        let wasActive = isConnected || isBusy
        if wasActive { disconnect() }
        mode = m
        defaults.set(m.rawValue, forKey: kMode)
        notify()
        if wasActive { connect() }
    }

    func connect() {
        guard let profile = profiles.first(where: { $0.id == selectedProfileId }) ?? profiles.first else {
            setState(.error(VPNError.noProfiles.localizedDescription)); return
        }
        switch mode {
        case .proxy: connectProxy(profile)
        case .tun:   connectTUN(profile)
        }
    }

    // MARK: Proxy mode (Xray + system proxy)

    private func connectProxy(_ profile: XrayProfile) {
        setState(.connecting)
        runner.stop()

        let ports = PortFinder.freePair()
        guard let cfg = ConfigStore.makeRunnable(profile, socks: ports.socks, http: ports.http) else {
            setState(.error(VPNError.noNodes.localizedDescription)); return
        }
        do {
            let url = try ConfigStore.writeTemp(cfg)
            try runner.start(configURL: url)
        } catch {
            setState(.error((error as? VPNError)?.localizedDescription ?? error.localizedDescription))
            return
        }
        activePorts = ports

        // Wait for real egress (balancer/observatory warmup), then set the system proxy.
        EgressProbe.waitForEgress(socksPort: ports.socks, deadline: 30) { [weak self] ok in
            guard let self = self else { return }
            guard self.state.isBusy else { return }   // user cancelled meanwhile
            if ok {
                let set = SystemProxy.enable(socksPort: ports.socks, httpPort: ports.http)
                if set {
                    self.setState(.connected)
                } else {
                    self.runner.stop()
                    self.setState(.error("Couldn't change the system proxy settings."))
                }
            } else {
                self.runner.stop()
                self.activePorts = nil
                self.setState(.error(VPNError.notReady.localizedDescription))
            }
        }
    }

    // MARK: TUN mode (privileged helper + sing-box)

    private func connectTUN(_ profile: XrayProfile) {
        setState(.connecting)
        runner.stop()                     // ensure proxy core isn't also running
        // Install the helper if it's missing or out of date (one admin prompt).
        ensureHelper(reinstall: HelperInstaller.needsInstall) { [weak self] ok, msg in
            guard let self = self, self.state.isBusy else { return }
            if ok { self.startTUNFlow(profile, allowReinstall: true) }
            else { self.setState(.error(msg)) }
        }
    }

    /// Installs/updates the helper off the main thread (so the admin prompt doesn't
    /// block the UI), or completes immediately when no install is needed.
    private func ensureHelper(reinstall: Bool, completion: @escaping (Bool, String) -> Void) {
        guard reinstall else { completion(true, ""); return }
        helper.invalidate()
        DispatchQueue.global().async {
            let res = HelperInstaller.install()
            DispatchQueue.main.async { completion(res.ok, res.message) }
        }
    }

    private func startTUNFlow(_ profile: XrayProfile, allowReinstall: Bool) {
        guard let cfg = SingboxConfig.makeTUN(profile) else {
            setState(.error(VPNError.noNodes.localizedDescription)); return
        }
        setTunMarker(true)   // so a crash mid-tunnel is cleaned up on next launch
        helper.startTUN(config: cfg) { [weak self] ok, msg in
            guard let self = self, self.state.isBusy else { return }
            if ok {
                // Verify the tunnel actually reaches the internet; self-heal (tear down +
                // restore routing) if it never does, so a dead tunnel can't strand the Mac.
                EgressProbe.waitForGeneralEgress(deadline: 30) { reachable in
                    guard self.state.isBusy else { return }
                    // Egress can succeed *directly* if sing-box already died and routing
                    // was restored — so confirm the tunnel process is actually up.
                    self.helper.status { running in
                        guard self.state.isBusy else { return }
                        if reachable && running {
                            self.setState(.connected)
                        } else {
                            self.helper.stopTUN { _, _ in }
                            self.setTunMarker(false)
                            self.setState(.error(VPNError.notReady.localizedDescription))
                        }
                    }
                }
            } else if allowReinstall && msg.lowercased().contains("communicate") {
                // Stale or broken helper — reinstall once and retry.
                self.ensureHelper(reinstall: true) { ok2, msg2 in
                    guard self.state.isBusy else { return }
                    if ok2 { self.startTUNFlow(profile, allowReinstall: false) }
                    else { self.setState(.error(msg2)) }
                }
            } else {
                self.setState(.error("Helper: \(msg)"))
            }
        }
    }

    func disconnect() {
        switch mode {
        case .proxy:
            SystemProxy.disableAndRestore()
            runner.stop()
            activePorts = nil
        case .tun:
            helper.stopTUN { _, _ in }
        }
        setState(.disconnected)
    }

    /// Called on app quit; best-effort cleanup.
    func shutdownForQuit() {
        switch mode {
        case .proxy:
            if isConnected || activePorts != nil { SystemProxy.disableAndRestore() }
            runner.stop()
        case .tun:
            if isConnected || isBusy { helper.stopTUNSync(timeout: 8) }
            setTunMarker(false)
        }
    }

    func uninstallHelper(completion: @escaping (Bool) -> Void) {
        helper.uninstall { ok in
            if !ok { _ = HelperInstaller.uninstall() }
            self.notify()
            completion(true)
        }
    }

    private func handleUnexpectedExit() {
        guard mode == .proxy, state.isConnected || state.isBusy else { return }
        SystemProxy.disableAndRestore()
        activePorts = nil
        setState(.error("The proxy core stopped unexpectedly."))
    }

    // MARK: - Subscriptions

    func addOrUpdateSubscription(_ urlString: String, completion: @escaping (Error?) -> Void) {
        subs.fetch(urlString) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let err):
                completion(err)
            case .success(let fetched):
                let title = fetched.meta.title ?? URL(string: urlString)?.host ?? "Subscription"
                let stored = StoredSubscription(
                    url: urlString,
                    title: title,
                    rawBase64: fetched.raw.base64EncodedString(),
                    meta: fetched.meta,
                    fetchedAt: Date())
                if let idx = self.subscriptions.firstIndex(where: { $0.url == urlString }) {
                    self.subscriptions[idx] = stored
                    self.selectedSubIndex = idx
                } else {
                    self.subscriptions.append(stored)
                    self.selectedSubIndex = self.subscriptions.count - 1
                }
                self.savePersisted()
                self.reparseProfiles()
                if !self.profiles.contains(where: { $0.id == self.selectedProfileId }) {
                    self.selectedProfileId = self.profiles.first?.id ?? "0"
                }
                self.defaults.set(self.selectedSubIndex, forKey: self.kSelSub)
                self.defaults.set(self.selectedProfileId, forKey: self.kSelProfile)
                self.notify()
                completion(nil)
            }
        }
    }

    func refreshSelectedSubscription(completion: @escaping (Error?) -> Void) {
        guard let sub = currentSubscription else { completion(VPNError.noProfiles); return }
        addOrUpdateSubscription(sub.url, completion: completion)
    }

    func resetDeviceID() { HWID.reset() }

    // MARK: - Persistence

    private func loadPersisted() {
        if let data = defaults.data(forKey: kSubs),
           let subs = try? JSONDecoder().decode([StoredSubscription].self, from: data) {
            subscriptions = subs
        }
        selectedSubIndex = defaults.integer(forKey: kSelSub)
        if !subscriptions.indices.contains(selectedSubIndex) { selectedSubIndex = 0 }
        selectedProfileId = defaults.string(forKey: kSelProfile) ?? "0"
        mode = TunnelMode(rawValue: defaults.string(forKey: kMode) ?? "") ?? .proxy
    }

    private func savePersisted() {
        if let data = try? JSONEncoder().encode(subscriptions) {
            defaults.set(data, forKey: kSubs)
        }
    }

    private func reparseProfiles() {
        guard let sub = currentSubscription else { profiles = []; return }
        let name = sub.title
        profiles = (try? SubscriptionParser.parse(data: sub.rawData, fallbackName: name))?
            .filter { !$0.isPlaceholder } ?? []
    }

    // MARK: - State plumbing

    private var tunMonitor: Timer?

    private func setState(_ s: ConnectionState) {
        state = s
        if case .error(let m) = s { lastError = m } else if s == .connected { lastError = nil }
        switch s {
        case .disconnected, .error: setTunMarker(false)
        default: break
        }
        updateTunMonitor()
        notify()
    }

    /// While system-wide and connected, poll the helper so a crashed tunnel doesn't
    /// keep showing "Connected". (The kernel drops routes when the utun disappears.)
    private func updateTunMonitor() {
        let shouldRun = (mode == .tun && state.isConnected)
        if shouldRun {
            if tunMonitor == nil {
                tunMonitor = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                    self?.pollTun()
                }
            }
        } else {
            tunMonitor?.invalidate(); tunMonitor = nil
        }
    }
    private func pollTun() {
        helper.status { [weak self] running in
            guard let self = self else { return }
            if !running, self.mode == .tun, self.state.isConnected {
                self.setState(.error("The tunnel stopped."))
            }
        }
    }
    private func notify() { DispatchQueue.main.async { [weak self] in self?.onChange?() } }
}

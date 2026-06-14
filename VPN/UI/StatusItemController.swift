import AppKit

/// Owns the menu-bar status item and its menu.
final class StatusItemController: NSObject, NSMenuDelegate {

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: AppModel
    private var pulseTimer: Timer?
    private var pulseFilled = false

    init(model: AppModel) {
        self.model = model
        super.init()
        item.button?.image = StatusIcon.shield(filled: false)
        item.button?.toolTip = "VPN"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        model.onChange = { [weak self] in self?.update() }
        update()
    }

    // MARK: - Icon

    private func update() {
        switch model.state {
        case .connected:
            stopPulse(); item.button?.image = StatusIcon.shield(filled: true)
        case .connecting:
            startPulse()
        case .disconnected, .error:
            stopPulse(); item.button?.image = StatusIcon.shield(filled: false)
        }
    }

    private func startPulse() {
        guard pulseTimer == nil else { return }
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.pulseFilled.toggle()
            self.item.button?.image = StatusIcon.shield(filled: self.pulseFilled)
        }
    }
    private func stopPulse() {
        pulseTimer?.invalidate(); pulseTimer = nil; pulseFilled = false
    }

    // MARK: - Menu (rebuilt each open)

    func menuWillOpen(_ menu: NSMenu) { rebuild(menu) }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        let title = model.meta?.title ?? model.currentSubscription?.title ?? "VPN"
        menu.addItem(disabled(title))
        menu.addItem(disabled("● " + model.state.label))
        menu.addItem(.separator())

        if model.hasSubscription {
            let toggle = NSMenuItem(
                title: model.isConnected ? "Disconnect" : (model.isBusy ? "Cancel" : "Connect"),
                action: #selector(toggleConnection), keyEquivalent: "")
            toggle.target = self
            menu.addItem(toggle)

            // Tunnel mode
            let modeItem = NSMenuItem(title: "Mode: \(model.mode.label)", action: nil, keyEquivalent: "")
            let modeSub = NSMenu()
            for m in [AppModel.TunnelMode.tun, .proxy] {
                let mi = NSMenuItem(title: m.label, action: #selector(pickMode(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = m.rawValue
                mi.state = (m == model.mode) ? .on : .off
                if m == .tun && !model.helperInstalled {
                    mi.title = m.label + " — installs helper"
                }
                modeSub.addItem(mi)
            }
            modeItem.submenu = modeSub
            menu.addItem(modeItem)

            if !model.profiles.isEmpty {
                let region = NSMenuItem(title: "Region: \(model.selectedProfileName ?? "—")",
                                        action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for p in model.profiles {
                    let mi = NSMenuItem(title: p.name, action: #selector(pickRegion(_:)), keyEquivalent: "")
                    mi.target = self
                    mi.representedObject = p.id
                    mi.state = (p.id == model.selectedProfileId) ? .on : .off
                    sub.addItem(mi)
                }
                region.submenu = sub
                menu.addItem(region)
            }

            if let usage = model.meta?.usageLine {
                menu.addItem(disabled(usage))
            }
            menu.addItem(.separator())
            addAction(menu, "Update subscription", #selector(updateSubscription))
        }

        addAction(menu, model.hasSubscription ? "Change subscription…" : "Add subscription…",
                  #selector(changeSubscription))
        if model.subscriptions.count > 1 {
            let pick = NSMenuItem(title: "Subscriptions", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (i, s) in model.subscriptions.enumerated() {
                let mi = NSMenuItem(title: s.title, action: #selector(pickSubscription(_:)), keyEquivalent: "")
                mi.target = self; mi.representedObject = i
                mi.state = (i == model.selectedSubIndex) ? .on : .off
                sub.addItem(mi)
            }
            pick.submenu = sub
            menu.addItem(pick)
        }
        addAction(menu, "Reset device ID", #selector(resetDeviceID))
        if model.helperInstalled {
            addAction(menu, "Remove system VPN helper", #selector(removeHelper))
        }

        if let support = model.meta?.supportURL, let _ = URL(string: support) {
            addAction(menu, "Support…", #selector(openSupport))
        }

        menu.addItem(.separator())
        addAction(menu, "Quit VPN", #selector(quit))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }
    private func addAction(_ menu: NSMenu, _ title: String, _ sel: Selector) {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        mi.target = self
        menu.addItem(mi)
    }

    // MARK: - Actions

    @objc private func toggleConnection() { model.toggle() }
    @objc private func pickRegion(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { model.selectProfile(id) }
    }
    @objc private func pickMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String,
           let m = AppModel.TunnelMode(rawValue: raw) { model.setMode(m) }
    }
    @objc private func removeHelper() {
        model.uninstallHelper { _ in
            AddSubscriptionWindow.showError("The system VPN helper was removed.")
        }
    }
    @objc private func pickSubscription(_ sender: NSMenuItem) {
        if let i = sender.representedObject as? Int { model.selectSubscription(i) }
    }
    @objc private func updateSubscription() {
        model.refreshSelectedSubscription { err in
            if let err = err { AddSubscriptionWindow.showError(err.localizedDescription) }
        }
    }
    @objc private func changeSubscription() {
        let prefill = model.currentSubscription?.url ?? AppModel.demoURL
        AddSubscriptionWindow.present(prefill: prefill) { [weak self] url in
            guard let self = self, let url = url else { return }
            self.model.addOrUpdateSubscription(url) { err in
                if let err = err { AddSubscriptionWindow.showError(err.localizedDescription) }
            }
        }
    }
    @objc private func resetDeviceID() {
        model.resetDeviceID()
        AddSubscriptionWindow.showError("A new device ID was generated. If the provider enforces a device limit, you may need a free slot, then press “Update subscription”.")
    }
    @objc private func openSupport() {
        if let s = model.meta?.supportURL, let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
    @objc private func quit() {
        model.shutdownForQuit()
        NSApp.terminate(nil)
    }
}

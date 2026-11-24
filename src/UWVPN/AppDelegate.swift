import AppKit
import Network
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let relay = GatewayRelay()
    private var runner: TunnelRunner?
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let pathMonitor = NWPathMonitor()
    private var networkDebounce: DispatchWorkItem?
    private var lastPathSatisfied: Bool?

    private var legacyLaunchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(UWConfig.legacyLaunchAgentLabel).plist")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            try relay.start()
        } catch {
            let alert = NSAlert()
            alert.messageText = "UWVPN failed to start local gateway relay"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let r = TunnelRunner(relay: relay) { [weak self] in
            self?.rebuildMenu()
            self?.updateStatusIcon()
        }
        self.runner = r

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = menu
        updateStatusIcon()
        rebuildMenu()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = (path.status == .satisfied)
            DispatchQueue.main.async {
                guard let self else { return }
                if self.lastPathSatisfied == nil {
                    self.lastPathSatisfied = online
                    return
                }
                self.lastPathSatisfied = online
                self.networkDebounce?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    self?.runner?.handleNetworkStatus(online: online)
                }
                self.networkDebounce = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
            }
        }
        pathMonitor.start(queue: DispatchQueue.global(qos: .utility))

        if r.autoConnectEnabled && r.inMemoryCachedSession() != nil {
            r.connect()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        pathMonitor.cancel()
        guard let runner else {
            relay.stop()
            return .terminateNow
        }
        runner.quitAsync { [weak self] in
            self?.relay.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc private func systemDidWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.runner?.handleSystemWake()
        }
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button, let runner else { return }
        let symbolName: String
        switch runner.state {
        case .connected:
            symbolName = "lock.shield.fill"
        case .authenticating, .connecting, .reconnecting:
            symbolName = "arrow.triangle.2.circlepath"
        case .disconnected, .error:
            symbolName = "lock.shield"
        }
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "UWVPN") {
            image.isTemplate = true
            button.image = image
        }
        button.title = runner.state.isConnected ? " UW" : ""
    }

    private func rebuildMenu() {
        guard let runner else { return }
        menu.removeAllItems()

        let header = NSMenuItem(title: "UW-VPN  •  socks5://\(UWConfig.loopbackHost):\(UWConfig.socksPort)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let gw = runner.selectedGateway
        let cached = runner.inMemoryCachedSession()
        let expiryLabel = cached?.remainingDescription.map { "\($0) left" } ?? "active"
        let statusText: String
        switch runner.state {
        case .disconnected:
            if let cached {
                statusText = cached.remainingDescription.map { "Disconnected • Cached Session (\($0) left)" } ?? "Disconnected • Cached Session"
            } else {
                statusText = "Disconnected • Login required"
            }
        case .authenticating:
            statusText = "Waiting for UW NetID / Duo…"
        case .connecting:
            statusText = "Connecting to \(gw.shortLabel)…"
        case .connected:
            statusText = "Connected (\(gw.shortLabel)) • \(expiryLabel)"
        case .reconnecting(let attempt):
            statusText = "Reconnecting (attempt \(attempt))…"
        case .error(let msg):
            statusText = "Error: \(msg)"
        }
        let statusRow = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusRow.isEnabled = false
        menu.addItem(statusRow)

        menu.addItem(.separator())

        if runner.state.isBusyOrUp {
            let disc = NSMenuItem(title: "Disconnect (Keep Session)", action: #selector(disconnectAction), keyEquivalent: "")
            disc.target = self
            menu.addItem(disc)
        } else {
            let title = cached != nil ? "Connect (Use Saved Session)" : "Connect (UW Web Login)…"
            let conn = NSMenuItem(title: title, action: #selector(connectAction), keyEquivalent: "")
            conn.target = self
            menu.addItem(conn)
        }

        let reauth = NSMenuItem(title: "Re-authenticate via Browser…", action: #selector(reauthAction), keyEquivalent: "")
        reauth.target = self
        menu.addItem(reauth)

        let signOut = NSMenuItem(title: "Sign Out & Clear Saved Session", action: #selector(signOutAction), keyEquivalent: "")
        signOut.target = self
        menu.addItem(signOut)

        menu.addItem(.separator())

        let gatewayMenu = NSMenu()
        for option in UWGateway.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(selectGateway(_:)), keyEquivalent: "")
            item.representedObject = option.rawValue
            item.state = (option == runner.selectedGateway) ? .on : .off
            item.target = self
            gatewayMenu.addItem(item)
        }
        let gatewayRoot = NSMenuItem(title: "Gateway: \(gw.shortLabel)", action: nil, keyEquivalent: "")
        gatewayRoot.submenu = gatewayMenu
        menu.addItem(gatewayRoot)

        let testItem = NSMenuItem(title: "Test UW Connectivity", action: #selector(testAction), keyEquivalent: "")
        testItem.target = self
        menu.addItem(testItem)

        let openRules = NSMenuItem(title: "Open Split Rules Folder", action: #selector(openSupportFolder), keyEquivalent: "")
        openRules.target = self
        menu.addItem(openRules)

        menu.addItem(.separator())

        let autoItem = NSMenuItem(title: "Auto-Connect on Launch (if cached)", action: #selector(toggleAutoConnect), keyEquivalent: "")
        autoItem.state = runner.autoConnectEnabled ? .on : .off
        autoItem.target = self
        menu.addItem(autoItem)

        let loginItem = NSMenuItem(title: "Launch UWVPN at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.state = isLaunchAtLoginEnabled() ? .on : .off
        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit UWVPN (Keep Session Cached)", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func isLaunchAtLoginEnabled() -> Bool {
        if SMAppService.mainApp.status == .enabled { return true }
        return FileManager.default.fileExists(atPath: legacyLaunchAgentURL.path)
    }

    @objc private func connectAction() {
        runner?.connect(forceLogin: false)
    }

    @objc private func reauthAction() {
        runner?.connect(forceLogin: true)
    }

    @objc private func disconnectAction() {
        runner?.disconnect(logoutOnServer: false)
    }

    @objc private func signOutAction() {
        runner?.disconnect(logoutOnServer: true)
        rebuildMenu()
    }

    @objc private func selectGateway(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let gw = UWGateway(rawValue: raw) else { return }
        runner?.selectedGateway = gw
    }

    @objc private func testAction() {
        runner?.testConnection { message in
            let alert = NSAlert()
            alert.messageText = "UWVPN Connectivity Test"
            alert.informativeText = message
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func openSupportFolder() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/UWVPN")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func toggleAutoConnect() {
        runner?.autoConnectEnabled.toggle()
    }

    @objc private func toggleLaunchAtLogin() {
        try? FileManager.default.removeItem(at: legacyLaunchAgentURL)
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not update Launch at Login"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        rebuildMenu()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

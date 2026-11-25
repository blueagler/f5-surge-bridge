import AppKit
import Darwin
import Foundation
import OSLog

final class TunnelRunner {
    private static let logger = Logger(subsystem: "com.blueagle.uwvpn", category: "Tunnel")

    private enum StopIntent {
        case none
        case detach
        case logout
    }

    private let relay: GatewayRelay
    private let configuration: GatewayConfiguration
    private let socksPortOverride: UInt16?
    private let onStateChange: () -> Void

    var socksPort: UInt16 {
        socksPortOverride ?? configuration.routes[selectedGateway.id]!.socksPort
    }

    private(set) var state: TunnelState = .disconnected {
        didSet { onStateChange() }
    }

    private var generation: UInt64 = 0
    private var process: Process?
    private var processGateway: UWGateway?
    private var stopIntent: StopIntent = .none
    private var stopKillTimer: DispatchWorkItem?
    private var stopWaiters: [() -> Void] = []
    private var readinessTimer: DispatchWorkItem?
    private var socksHealthTimer: Timer?
    private var socksHealthProbe: UUID?
    private var socksHealthFailures = 0
    private var refreshSessionAfterProbe = false
    private var reconnectWorkItem: DispatchWorkItem?
    private var keepaliveTimer: Timer?
    private var keepaliveTask: URLSessionDataTask?
    private var keepaliveRequest: UUID?
    private var activeLogin: WebLoginController?
    private var clearingWebDataGateways: Set<UWGateway> = []
    private var loggingOutGateways: Set<UWGateway> = []
    private var cachedSessions: [UWGateway: StoredSession] = [:]
    private let serverLogouts = DispatchGroup()

    private var desiredConnected = false
    private var networkOnline = true
    private var lastPhysicalInterface: String?
    private var reconnectAttempts = 0
    private let surgeReload = SurgeReloadCoordinator { completion in
        DispatchQueue.global(qos: .utility).async {
            let succeeded = (try? SurgeModule.command(["reload"])) != nil
            completion(succeeded)
        }
    }
    private var urlSession: URLSession?

    private let selectedGatewayKey = "selectedGateway"
    private let autoConnectKey = "autoConnect"

    var selectedGateway: UWGateway {
        get {
            if let raw = UserDefaults.standard.string(forKey: selectedGatewayKey),
               let gw = configuration.gateways.first(where: { $0.id == raw }) {
                return gw
            }
            return configuration.defaultSelection
        }
        set {
            guard newValue != selectedGateway else { return }
            let wasUp = desiredConnected || state.isBusyOrUp
            if wasUp {
                disconnect(logoutOnServer: false)
            }
            UserDefaults.standard.set(newValue.id, forKey: selectedGatewayKey)
            onStateChange()
            if wasUp {
                connect(forceLogin: false)
            }
        }
    }

    var autoConnectEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: autoConnectKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: autoConnectKey)
            onStateChange()
        }
    }

    init(relay: GatewayRelay, configuration: GatewayConfiguration, socksPort: UInt16? = nil,
         onStateChange: @escaping () -> Void) {
        self.relay = relay
        self.configuration = configuration
        self.socksPortOverride = socksPort
        self.onStateChange = onStateChange
        for gw in configuration.gateways {
            reloadKeychainCache(for: gw)
        }
    }

    func inMemoryCachedSession(for gateway: UWGateway? = nil) -> StoredSession? {
        let gw = gateway ?? selectedGateway
        guard let session = cachedSessions[gw], session.isValidNow else {
            return nil
        }
        return session
    }

    func connect(forceLogin: Bool = false) {
        generation &+= 1
        let gen = generation
        desiredConnected = true
        reconnectAttempts = 0
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        keepaliveRequest = nil
        readinessTimer?.cancel()
        readinessTimer = nil

        let gw = selectedGateway
        if clearingWebDataGateways.contains(gw) || loggingOutGateways.contains(gw) {
            state = .connecting
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.generation == gen, self.desiredConnected else { return }
                self.connect(forceLogin: forceLogin)
            }
            return
        }

        if !forceLogin, let session = inMemoryCachedSession(for: gw) {
            startWhenProcessStopped(generation: gen) { [weak self] in
                self?.startOpenConnect(with: session, gateway: gw, expectedGeneration: gen)
            }
            return
        }

        activeLogin?.closeSilently()
        activeLogin = nil
        startWhenProcessStopped(generation: gen, intent: .detach) { [weak self] in
            self?.openLoginWindow(for: gw, expectedGeneration: gen)
        }
    }

    func disconnect(logoutOnServer: Bool = false) {
        generation &+= 1
        let gen = generation
        desiredConnected = false
        reconnectAttempts = 0
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        readinessTimer?.cancel()
        readinessTimer = nil
        keepaliveTimer?.invalidate()
        keepaliveTimer = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        activeLogin?.closeSilently()
        activeLogin = nil

        let gw = selectedGateway
        if logoutOnServer {
            let hadSession = cachedSessions[gw]
            if hadSession != nil { loggingOutGateways.insert(gw) }
            cachedSessions.removeValue(forKey: gw)
            _ = KeychainStore.clear(gateway: gw)
            if clearingWebDataGateways.insert(gw).inserted {
                WebLoginController.clearWebsiteData(for: gw) { [weak self] in
                    self?.clearingWebDataGateways.remove(gw)
                }
            }
            // A detach already in progress may have sent SIGHUP, or the process
            // may have already exited. Use the saved cookie to log out in either case.
            let intent: StopIntent = processGateway == gw ? .logout : .detach
            stopCurrentProcess(intent: intent) { [weak self] in
                guard let self else { return }
                if let hadSession {
                    self.sendServerHangup(session: hadSession, gateway: gw, expectedGeneration: gen)
                }
                guard self.generation == gen else { return }
                self.state = .disconnected
            }
        } else {
            stopCurrentProcess(intent: .detach) { [weak self] in
                guard let self, self.generation == gen else { return }
                self.state = .disconnected
            }
        }
    }

    func quitAsync(completion: @escaping () -> Void) {
        generation &+= 1
        desiredConnected = false
        reconnectWorkItem?.cancel()
        readinessTimer?.cancel()
        keepaliveTimer?.invalidate()
        keepaliveTask?.cancel()
        activeLogin?.closeSilently()
        activeLogin = nil

        let pending = serverLogouts
        stopCurrentProcess(intent: .detach) {
            pending.notify(queue: .main, execute: completion)
        }
    }

    func handleNetworkStatus(online: Bool) {
        let wasOnline = networkOnline
        networkOnline = online
        relay.invalidateNetworkCache()

        guard desiredConnected, activeLogin == nil else { return }
        if !online {
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            if process != nil, stopIntent == .none { retryAfterStopping(expectedGeneration: generation) }
            return
        }

        let currentIface = relay.currentPhysicalInterfaceName()
        let ifaceChanged = (lastPhysicalInterface != nil && currentIface != nil && currentIface != lastPhysicalInterface)
        if ifaceChanged {
            lastPhysicalInterface = currentIface
        }

        if process == nil || !(process?.isRunning ?? false) {
            if reconnectWorkItem == nil && (!wasOnline || state != .connecting) {
                scheduleReconnect(delay: 1.0)
            }
            return
        }

        if ifaceChanged, stopIntent == .none, let proc = process, proc.isRunning {
            // A fresh connection binds to the new interface and proves an upstream path.
            retryAfterStopping(expectedGeneration: generation)
        } else if !wasOnline {
            checkSocksHealth(refreshSession: true)
        }
    }

    func handleSystemWake() {
        relay.invalidateNetworkCache()
        guard desiredConnected, activeLogin == nil, networkOnline else { return }
        if process == nil || !(process?.isRunning ?? false) {
            scheduleReconnect(delay: 1.5)
            return
        }
        if stopIntent == .none {
            // A successful local SOCKS5 greeting cannot validate a resumed VPN path.
            retryAfterStopping(expectedGeneration: generation)
        }
    }

    private func startSocksHealthMonitoring() {
        stopSocksHealthMonitoring()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.checkSocksHealth()
        }
        timer.tolerance = 0.25
        socksHealthTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopSocksHealthMonitoring() {
        socksHealthTimer?.invalidate()
        socksHealthTimer = nil
        socksHealthProbe = nil
        socksHealthFailures = 0
        refreshSessionAfterProbe = false
    }

    private func checkSocksHealth(refreshSession: Bool = false) {
        guard state.isConnected, desiredConnected, stopIntent == .none,
              let proc = process, proc.isRunning else { return }
        refreshSessionAfterProbe = refreshSessionAfterProbe || refreshSession
        guard socksHealthProbe == nil else { return }
        let gen = generation
        let probe = UUID()
        socksHealthProbe = probe
        let port = socksPort
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ok = Self.probeSocks5Handshake(port: port)
            DispatchQueue.main.async {
                guard let self, self.socksHealthProbe == probe else { return }
                self.socksHealthProbe = nil
                guard self.generation == gen, self.process === proc, proc.isRunning,
                      self.desiredConnected, self.state.isConnected, self.stopIntent == .none else { return }
                if ok {
                    self.socksHealthFailures = 0
                    if case .connected(let since) = self.state, Date().timeIntervalSince(since) >= 60 {
                        self.reconnectAttempts = 0
                    }
                    if self.refreshSessionAfterProbe {
                        self.refreshSessionAfterProbe = false
                        self.keepaliveTask?.cancel()
                        self.keepaliveTask = nil
                        self.keepaliveRequest = nil
                        self.performKeepalive(expectedGeneration: gen)
                    }
                    return
                }

                self.socksHealthFailures += 1
                guard self.socksHealthFailures >= 2 else { return }
                Self.logger.error("SOCKS5 stopped responding while OpenConnect was running. Reconnecting with the saved session.")
                self.retryAfterStopping(expectedGeneration: gen)
            }
        }
    }

    private func retryAfterStopping(expectedGeneration gen: UInt64) {
        reconnectAttempts += 1
        state = .reconnecting(attempt: reconnectAttempts)
        stopCurrentProcess(intent: .detach) { [weak self] in
            guard let self, self.generation == gen, self.desiredConnected else { return }
            self.scheduleReconnect(delay: self.retryDelay)
        }
    }

    private var retryDelay: TimeInterval {
        min(UWConfig.maxReconnectBackoffSec, pow(2.0, Double(max(0, min(reconnectAttempts - 1, 5)))))
    }

    private func reloadKeychainCache(for gateway: UWGateway) {
        switch KeychainStore.load(gateway: gateway) {
        case .success(let session):
            if let session, session.isValidNow {
                cachedSessions[gateway] = session
            } else {
                cachedSessions.removeValue(forKey: gateway)
            }
        case .failure:
            cachedSessions.removeValue(forKey: gateway)
        }
    }

    private func startWhenProcessStopped(generation gen: UInt64, intent: StopIntent = .detach, then action: @escaping () -> Void) {
        guard process != nil else {
            action()
            return
        }
        stopCurrentProcess(intent: intent) { [weak self] in
            guard let self, self.generation == gen, self.desiredConnected else { return }
            action()
        }
    }

    private func openLoginWindow(for gateway: UWGateway, expectedGeneration gen: UInt64) {
        guard generation == gen, desiredConnected, activeLogin == nil else { return }
        state = .authenticating
        let controller = WebLoginController(
            gateway: gateway,
            relayPort: relay.port,
            onComplete: { [weak self] session in
                guard let self, self.generation == gen else { return }
                self.activeLogin = nil
                self.cachedSessions[gateway] = session
                _ = KeychainStore.save(session: session, gateway: gateway)
                self.reconnectAttempts = 0
                if self.desiredConnected && self.selectedGateway == gateway {
                    self.startOpenConnect(with: session, gateway: gateway, expectedGeneration: gen)
                } else {
                    self.state = .disconnected
                }
            },
            onCancel: { [weak self] in
                guard let self, self.generation == gen else { return }
                self.activeLogin = nil
                self.desiredConnected = false
                self.state = .disconnected
            }
        )
        activeLogin = controller
        controller.show()
    }

    private func startOpenConnect(with session: StoredSession, gateway: UWGateway, expectedGeneration gen: UInt64) {
        guard generation == gen, desiredConnected else { return }
        guard networkOnline else {
            scheduleReconnect(delay: retryDelay)
            return
        }

        if Self.isLocalPortOccupied(socksPort) {
            reconnectAttempts += 1
            if reconnectAttempts == 1 {
                Self.logger.notice("The SOCKS5 port is still occupied. Waiting before starting OpenConnect.")
            }
            scheduleReconnect(delay: retryDelay)
            return
        }

        guard let resourceDir = Bundle.main.resourcePath else {
            state = .error("Missing app resources")
            desiredConnected = false
            return
        }

        let openconnectPath = "\(resourceDir)/bin/openconnect"
        let bridgePath = "\(resourceDir)/bin/tun-bridge.sh"
        guard FileManager.default.isExecutableFile(atPath: openconnectPath),
              FileManager.default.isExecutableFile(atPath: "\(resourceDir)/bin/tun-socks"),
              FileManager.default.isExecutableFile(atPath: bridgePath) else {
            state = .error("Missing bundled VPN helpers")
            desiredConnected = false
            return
        }

        state = .connecting
        stopIntent = .none
        lastPhysicalInterface = relay.currentPhysicalInterfaceName()

        let splitStem = gateway.publishesSplitRules ? gateway.ruleFileStem : ""
        let scriptCmd = "exec \(Self.shellQuote(bridgePath)) \(Self.shellQuote(gateway.id)) \(socksPort) \(Self.shellQuote(splitStem))"
        let proc = Process()
        let stdinPipe = Pipe()
        let stderrPipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: openconnectPath)
        proc.arguments = [
            "--protocol=f5",
            "--cookie-on-stdin",
            "--no-dtls",
            "--reconnect-timeout=\(UWConfig.openconnectReconnectTimeoutSec)",
            "--useragent=\(UWConfig.linuxUserAgent)",
            "--proxy=http://\(UWConfig.loopbackHost):\(relay.port)",
            "--script-tun",
            "--script=\(scriptCmd)",
            gateway.gatewayURL.absoluteString
        ]
        proc.standardInput = stdinPipe
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = stderrPipe

        self.process = proc
        self.processGateway = gateway

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                let text = String(decoding: data, as: UTF8.self)
                if let marker = text.range(of: "tun-socks: fatal errno="),
                   let code = Int32(text[marker.upperBound...].prefix(while: { $0.isASCII && $0.isNumber })) {
                    Self.logger.error("tun-socks terminated with errno \(code, privacy: .public).")
                }
            }
        }

        proc.terminationHandler = { [weak self] terminated in
            DispatchQueue.main.async {
                self?.handleProcessExit(process: terminated, exitCode: terminated.terminationStatus, procGeneration: gen, gateway: gateway)
            }
        }

        do {
            try proc.run()
        } catch {
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            try? stdinPipe.fileHandleForWriting.close()
            try? stdinPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            self.process = nil
            self.processGateway = nil
            desiredConnected = false
            state = .error("Failed to launch OpenConnect")
            return
        }

        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: Data((session.cookieHeader + "\n").utf8))
            try stdinPipe.fileHandleForWriting.close()
        } catch {
            try? stdinPipe.fileHandleForWriting.close()
            stopCurrentProcess(intent: .detach) { [weak self] in
                guard let self, self.generation == gen else { return }
                self.reconnectAttempts += 1
                self.scheduleReconnect(delay: self.retryDelay)
            }
            return
        }

        let deadline = DispatchTime.now() + .seconds(30)
        pollForSocksReadiness(expectedGeneration: gen, gateway: gateway, deadline: deadline)
    }

    private func pollForSocksReadiness(expectedGeneration gen: UInt64, gateway: UWGateway, deadline: DispatchTime) {
        guard generation == gen, desiredConnected, stopIntent == .none, let proc = process, proc.isRunning else { return }
        let port = socksPort
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ready = Self.probeSocks5Handshake(port: port)
            DispatchQueue.main.async {
                guard let self, self.generation == gen, self.desiredConnected, self.stopIntent == .none,
                      let currentProc = self.process, currentProc === proc, currentProc.isRunning else {
                    return
                }
                if ready {
                    self.state = .connected(since: Date())
                    self.startSocksHealthMonitoring()
                    self.startKeepaliveTimer(expectedGeneration: gen)
                    if gateway.publishesSplitRules {
                        self.refreshSurgeIfSplitRulesChanged(gateway: gateway)
                    }
                    return
                }
                if DispatchTime.now() >= deadline {
                    Self.logger.error("SOCKS5 startup timed out. Retrying with the saved session.")
                    self.retryAfterStopping(expectedGeneration: gen)
                    return
                }
                let item = DispatchWorkItem { [weak self] in
                    self?.pollForSocksReadiness(expectedGeneration: gen, gateway: gateway, deadline: deadline)
                }
                self.readinessTimer = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
            }
        }
    }

    private func handleProcessExit(process terminated: Process, exitCode: Int32, procGeneration: UInt64, gateway: UWGateway) {
        guard self.process === terminated else { return }
        self.process = nil
        self.processGateway = nil
        stopSocksHealthMonitoring()
        stopKillTimer?.cancel()
        stopKillTimer = nil
        readinessTimer?.cancel()
        readinessTimer = nil
        keepaliveTimer?.invalidate()
        keepaliveTimer = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        keepaliveRequest = nil

        let waiters = stopWaiters
        stopWaiters.removeAll()
        let activeStopIntent = stopIntent
        stopIntent = .none
        for waiter in waiters { waiter() }

        if activeStopIntent != .none || generation != procGeneration || !desiredConnected || selectedGateway != gateway {
            if !desiredConnected && waiters.isEmpty {
                state = .disconnected
            }
            return
        }

        // OpenConnect exits with code 2 on rejected/expired cookie.
        if exitCode == 2 {
            cachedSessions.removeValue(forKey: gateway)
            _ = KeychainStore.clear(gateway: gateway)
            openLoginWindow(for: gateway, expectedGeneration: procGeneration)
            return
        }

        if !networkOnline {
            state = .reconnecting(attempt: reconnectAttempts)
            return
        }

        if let session = inMemoryCachedSession(for: gateway), session.isValidNow {
            reconnectAttempts += 1
            scheduleReconnect(delay: retryDelay)
        } else {
            cachedSessions.removeValue(forKey: gateway)
            _ = KeychainStore.clear(gateway: gateway)
            openLoginWindow(for: gateway, expectedGeneration: procGeneration)
        }
    }

    private func scheduleReconnect(delay: TimeInterval) {
        let gen = generation
        reconnectWorkItem?.cancel()
        let reconnecting = TunnelState.reconnecting(attempt: reconnectAttempts)
        if state != reconnecting { state = reconnecting }
        guard networkOnline else {
            reconnectWorkItem = nil
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == gen, self.desiredConnected, self.networkOnline else { return }
            self.reconnectWorkItem = nil
            let gw = self.selectedGateway
            if let session = self.inMemoryCachedSession(for: gw) {
                self.startWhenProcessStopped(generation: gen) { [weak self] in
                    self?.startOpenConnect(with: session, gateway: gw, expectedGeneration: gen)
                }
            } else {
                self.openLoginWindow(for: gw, expectedGeneration: gen)
            }
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func stopCurrentProcess(intent: StopIntent, completion: @escaping () -> Void) {
        stopSocksHealthMonitoring()
        readinessTimer?.cancel()
        readinessTimer = nil
        keepaliveTimer?.invalidate()
        keepaliveTimer = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        keepaliveRequest = nil
        guard let proc = process else {
            completion()
            return
        }
        stopWaiters.append(completion)
        guard proc.isRunning else { return }
        if stopIntent == .none || (stopIntent == .detach && intent == .logout) {
            stopIntent = intent
            let sig: Int32 = (intent == .logout) ? SIGTERM : SIGHUP
            _ = kill(proc.processIdentifier, sig)

            let killItem = DispatchWorkItem { [weak self] in
                guard let self, let active = self.process, active === proc, active.isRunning else { return }
                _ = kill(active.processIdentifier, SIGKILL)
            }
            stopKillTimer?.cancel()
            stopKillTimer = killItem
            DispatchQueue.main.asyncAfter(deadline: .now() + (intent == .logout ? 2.0 : 1.2), execute: killItem)
        }
    }

    private func managedURLSession() -> URLSession {
        if let urlSession { return urlSession }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: UWConfig.loopbackHost,
            kCFNetworkProxiesHTTPPort as String: Int(relay.port),
            kCFNetworkProxiesHTTPSEnable as String: true,
            kCFNetworkProxiesHTTPSProxy as String: UWConfig.loopbackHost,
            kCFNetworkProxiesHTTPSPort as String: Int(relay.port)
        ]
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 12
        config.httpShouldSetCookies = false
        let s = URLSession(configuration: config)
        urlSession = s
        return s
    }

    private func startKeepaliveTimer(expectedGeneration gen: UInt64) {
        keepaliveTimer?.invalidate()
        keepaliveTimer = Timer.scheduledTimer(withTimeInterval: UWConfig.keepaliveInterval, repeats: true) { [weak self] _ in
            self?.performKeepalive(expectedGeneration: gen)
        }
    }

    private func performKeepalive(expectedGeneration gen: UInt64) {
        guard generation == gen, desiredConnected, state.isConnected, stopIntent == .none else { return }
        let gw = selectedGateway
        guard let session = cachedSessions[gw], keepaliveTask == nil else { return }

        let url = gw.gatewayURL.appendingPathComponent("vdesk/timeoutagent-i.php")
        var req = URLRequest(url: url)
        req.setValue(UWConfig.linuxUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(session.cookieHeader, forHTTPHeaderField: "Cookie")

        let requestID = UUID()
        keepaliveRequest = requestID
        let task = managedURLSession().dataTask(with: req) { [weak self] _, response, error in
            DispatchQueue.main.async {
                guard let self, self.keepaliveRequest == requestID else { return }
                self.keepaliveTask = nil
                self.keepaliveRequest = nil
                guard self.generation == gen, self.desiredConnected, self.selectedGateway == gw else { return }
                if error != nil { return }
                guard let http = response as? HTTPURLResponse else { return }
                guard http.url?.host?.lowercased() == gw.gatewayHost else { return }

                let headerFields = http.allHeaderFields as? [String: String] ?? [:]
                let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
                let deleted = cookies.contains { $0.name == "MRHSession" && $0.value == "deleted" }
                let path = http.url?.path.lowercased() ?? ""
                if deleted || path.contains("hangup") || path.contains("my.policy") || http.statusCode == 401 || http.statusCode == 403 {
                    self.cachedSessions.removeValue(forKey: gw)
                    _ = KeychainStore.clear(gateway: gw)
                    self.stopCurrentProcess(intent: .detach) { [weak self] in
                        guard let self, self.generation == gen, self.desiredConnected else { return }
                        self.openLoginWindow(for: gw, expectedGeneration: gen)
                    }
                    return
                }

                guard (200...399).contains(http.statusCode) else { return }
                var updated = session
                if let mrh = cookies.first(where: { $0.name == "MRHSession" && StoredSession.isValidToken($0.value) }) {
                    updated.sessionID = mrh.value
                }
                if let f5st = cookies.first(where: { $0.name == "F5_ST" && StoredSession.isValidToken($0.value) }) {
                    updated.f5ST = f5st.value
                    updated.expiresAt = StoredSession.parseF5STExpiration(f5st.value) ?? updated.expiresAt
                }
                updated.savedAt = Date().timeIntervalSince1970
                if updated != session {
                    self.cachedSessions[gw] = updated
                    _ = KeychainStore.save(session: updated, gateway: gw)
                    self.onStateChange()
                }
            }
        }
        keepaliveTask = task
        task.resume()
    }

    private func sendServerHangup(session: StoredSession, gateway: UWGateway, expectedGeneration gen: UInt64) {
        let url = gateway.gatewayURL.appendingPathComponent("vdesk/hangup.php3")
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "hangup_error", value: "1")]
        guard let hangupURL = comps?.url else {
            loggingOutGateways.remove(gateway)
            return
        }
        var req = URLRequest(url: hangupURL)
        req.setValue(UWConfig.linuxUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(session.cookieHeader, forHTTPHeaderField: "Cookie")
        let pending = serverLogouts
        pending.enter()
        managedURLSession().dataTask(with: req) { [weak self] _, response, error in
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            let confirmed = error == nil && http?.url?.host?.lowercased() == gateway.gatewayHost &&
                (200..<400).contains(status)
            DispatchQueue.main.async {
                defer { pending.leave() }
                guard let self else { return }
                self.loggingOutGateways.remove(gateway)
                guard !confirmed else { return }
                Self.logger.error("Could not confirm F5 server logout.")
                guard self.generation == gen else { return }
                self.state = .error("Local session cleared. Server sign-out could not be confirmed.")
            }
        }.resume()
    }

    func testConnection(completion: @escaping (String) -> Void) {
        let gw = selectedGateway
        let port = socksPort
        DispatchQueue.global(qos: .userInitiated).async {
            guard Self.probeSocks5Handshake(port: port) else {
                DispatchQueue.main.async {
                    completion("Not connected (SOCKS5 \(UWConfig.loopbackHost):\(port) did not respond).")
                }
                return
            }

            func curlViaSocks(_ url: String) -> (Int32, String) {
                let proc = Process()
                let out = Pipe()
                let err = Pipe()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                proc.arguments = ["-4", "--noproxy", "", "--proxy", "socks5h://\(UWConfig.loopbackHost):\(port)", "-fsSL", "--max-time", "10", url]
                proc.standardOutput = out
                proc.standardError = err
                do {
                    try proc.run()
                    var outData = Data()
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        outData = out.fileHandleForReading.readData(ofLength: 65536)
                        group.leave()
                    }
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        _ = err.fileHandleForReading.readData(ofLength: 8192)
                        group.leave()
                    }
                    proc.waitUntilExit()
                    group.wait()
                    return (proc.terminationStatus, String(data: outData, encoding: .utf8) ?? "")
                } catch {
                    return (-1, "")
                }
            }

            var lines = ["Gateway: \(gw.title)"]
            if gw.isUWPreset {
                let (uwCode, uwBody) = curlViaSocks(UWConfig.campusTestURL)
                lines.append(uwCode == 0 && uwBody.contains("Success!")
                             ? "Campus resource test: Success!"
                             : "Campus resource test: Failed (exit \(uwCode))")
            }

            let (ipCode, ipBody) = curlViaSocks(UWConfig.publicIPTestURL)
            let trimmedIP = ipBody.trimmingCharacters(in: .whitespacesAndNewlines)
            let ipLine: String
            if ipCode == 0 && !trimmedIP.isEmpty {
                ipLine = "Public egress via VPN: \(trimmedIP)"
            } else if gw.publishesSplitRules {
                ipLine = "Public egress via VPN: Unavailable (the gateway may restrict public traffic)"
            } else {
                ipLine = "Public egress via VPN: Failed (exit \(ipCode))"
            }

            let summary = (lines + [ipLine]).joined(separator: "\n")
            DispatchQueue.main.async { completion(summary) }
        }
    }

    private func refreshSurgeIfSplitRulesChanged(gateway: UWGateway) {
        let dir = UWConfig.supportDirectory
        let splitText = (try? String(contentsOf: dir.appendingPathComponent("\(gateway.ruleFileStem)-split.list"), encoding: .utf8)) ?? ""
        let excText = (try? String(contentsOf: dir.appendingPathComponent("\(gateway.ruleFileStem)-exclude.list"), encoding: .utf8)) ?? ""
        let snapshot = [gateway.ruleFileStem, splitText, excText].map { text in
            text.split(separator: "\n").filter { !$0.hasPrefix("#") }.joined(separator: "\n")
        }.joined(separator: "\n\n")
        guard FileManager.default.isExecutableFile(atPath: UWConfig.surgeCLIPath) else { return }
        surgeReload.update(snapshot)
    }

    private static func isLocalPortOccupied(_ port: UInt16) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr(UWConfig.loopbackHost))
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) != 0 && errno == EADDRINUSE
            }
        }
    }

    private static func probeSocks5Handshake(port: UInt16) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr(UWConfig.loopbackHost))
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard connected else { return false }

        let greeting: [UInt8] = [0x05, 0x01, 0x00]
        let sent = greeting.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, greeting.count, 0) }
        guard sent == greeting.count else { return false }

        var reply = [UInt8](repeating: 0, count: 2)
        let n = Darwin.recv(fd, &reply, reply.count, MSG_WAITALL)
        return n == 2 && reply[0] == 0x05 && reply[1] == 0x00
    }

    private static func shellQuote(_ arg: String) -> String {
        "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

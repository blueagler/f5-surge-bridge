import Darwin
import Foundation

// Synthetic sessions only. This fixture never reads the user's Keychain.
enum KeychainStore {
    static var clearError: NSError?

    static func load(gateway: UWGateway) -> Result<StoredSession?, NSError> {
        .success(StoredSession(sessionID: "fixture", f5ST: "fixture", expiresAt: nil, savedAt: 0))
    }

    static func save(session: StoredSession, gateway: UWGateway) -> Result<Void, NSError> { .success(()) }

    static func clear(gateway: UWGateway) -> Result<Void, NSError> {
        clearError.map { .failure($0) } ?? .success(())
    }
}

final class FixtureURLProtocol: URLProtocol {
    static var deleted = false
    static var requests = [URLRequest]()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let headers = Self.deleted ? ["Set-Cookie": "MRHSession=deleted; Path=/; Secure"] : [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!
        DispatchQueue.global().async {
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data("fixture response".utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

@main
struct TunnelHealthLogout {
    static let gateway = UWGateway(
        id: "fixture", name: "Fixture", gatewayURL: URL(string: "https://vpn.example.com/")!,
        splitRules: false, healthCheckURL: URL(string: "https://health.example.com/ready")!
    )
    static let configuration = GatewayConfiguration(defaultGateway: "fixture", gateways: [gateway], directHosts: nil)
    static let relay = GatewayRelay(gateways: [gateway])

    static func main() {
        validateConfiguration()
        testManualCustomHealth()
        testLogoutFailuresAndQuit()
        testWebKitFailureAndSuccessfulLogout()
        print("Verified custom health, logout failures, and delayed cleanup on quit")
    }

    static func validateConfiguration() {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let valid = #"{"defaultGateway":"custom","gateways":[{"id":"custom","name":"Custom","gatewayURL":"https://vpn.example.com/","healthCheckURL":"https://health.example.com/ready"}]}"#
        try! Data(valid.utf8).write(to: file)
        let loaded = try! GatewayConfiguration.load(from: file)
        precondition(loaded.gateways[0].effectiveHealthCheckURL?.host == "health.example.com")
        precondition(UWGateway.allInternet.effectiveHealthCheckURL == URL(string: UWConfig.campusTestURL))
        precondition(UWGateway.campusOnly.effectiveHealthCheckURL == URL(string: UWConfig.campusTestURL))
        for badURL in ["http://health.example.com/ready", "https://user@health.example.com/ready", "https://health.example.com/ready#fragment"] {
            let invalid = valid.replacingOccurrences(of: "https://health.example.com/ready", with: badURL)
            try! Data(invalid.utf8).write(to: file)
            do {
                _ = try GatewayConfiguration.load(from: file)
                preconditionFailure("Invalid health URL must fail configuration validation")
            } catch {}
        }
    }

    static func makeRunner(
        probe: @escaping (UWGateway, UInt16, @escaping (TunnelProbeResult) -> Void) -> Void = { _, _, done in done(.upstream(.unverified)) },
        clear: @escaping (UWGateway, @escaping (Result<Void, NSError>) -> Void) -> Void = { _, done in done(.success(())) },
        defaults: UserDefaults = UserDefaults(suiteName: "com.blueagle.uwvpn.fixture.\(UUID().uuidString)")!
    ) -> TunnelRunner {
        return TunnelRunner(
            relay: relay, configuration: configuration, socksPort: 11081,
            clearWebsiteData: clear, tunnelProbe: probe,
            configureSession: { $0.protocolClasses = [FixtureURLProtocol.self] }, defaults: defaults,
            onStateChange: {}
        )
    }

    static func testManualCustomHealth() {
        let runner = makeRunner(probe: { _, _, done in done(.upstream(.degraded)) })
        runner.testConnection { message in
            precondition(message.contains("health.example.com"))
            precondition(message.contains("Failed"))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    static func testLogoutFailuresAndQuit() {
        FixtureURLProtocol.deleted = false
        KeychainStore.clearError = NSError(domain: "FixtureKeychain", code: 17)
        var webCompletion: ((Result<Void, NSError>) -> Void)?
        let suite = "com.blueagle.uwvpn.fixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let runner = makeRunner(clear: { _, done in webCompletion = done }, defaults: defaults)
        var completed = false
        runner.disconnect(logoutOnServer: true) { result in
            guard case .failure(let error) = result else {
                preconditionFailure("Failed deletion and generic HTTP 200 must fail sign-out")
            }
            precondition(error.localizedDescription.contains("Keychain"))
            precondition(error.localizedDescription.contains("F5 server"))
            completed = true
        }
        precondition(runner.state == .signingOut)
        precondition(runner.inMemoryCachedSession() == nil)
        var quitCompleted = false
        runner.quitAsync { quitCompleted = true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(!completed && !quitCompleted && webCompletion != nil)
        webCompletion?(.success(()))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(completed && quitCompleted)
        precondition(makeRunner(defaults: UserDefaults(suiteName: suite)!).inMemoryCachedSession() == nil)
        precondition(FixtureURLProtocol.requests.contains {
            $0.url?.path == "/vdesk/hangup.php3" && $0.value(forHTTPHeaderField: "Cookie")?.contains("fixture") == true
        })
        precondition(FixtureURLProtocol.requests.allSatisfy {
            ($0.url?.host == "vpn.example.com") && ($0.url?.query == "hangup_error=1")
        })
    }

    static func testWebKitFailureAndSuccessfulLogout() {
        KeychainStore.clearError = nil
        FixtureURLProtocol.deleted = true
        let failing = makeRunner(clear: { _, done in
            done(.failure(NSError(domain: "FixtureWebKit", code: 23)))
        })
        var failed = false
        failing.disconnect(logoutOnServer: true) { result in
            guard case .failure(let error) = result else { preconditionFailure("WebKit failure must be reported") }
            precondition(error.localizedDescription.contains("Browser sign-in data"))
            failed = true
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(failed)

        let successful = makeRunner()
        var succeeded = false
        successful.disconnect(logoutOnServer: true) { result in
            guard case .success = result else { preconditionFailure("Deletion cookie must confirm F5 logout") }
            succeeded = true
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(succeeded && successful.state == .disconnected)
        precondition(successful.inMemoryCachedSession() == nil)
    }
}

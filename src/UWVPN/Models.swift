import CryptoKit
import Darwin
import Foundation

struct UWGateway: Codable, Hashable {
    let id: String
    let name: String
    let gatewayURL: URL
    let splitRules: Bool?
    var fallbackDNSServers: [String]? = nil
    let healthCheckURL: URL?

    var effectiveHealthCheckURL: URL? { healthCheckURL }

    init(id: String, name: String, gatewayURL: URL, splitRules: Bool?, healthCheckURL: URL? = nil) {
        self.id = id
        self.name = name
        self.gatewayURL = gatewayURL
        self.splitRules = splitRules
        self.healthCheckURL = healthCheckURL
    }

    static let allInternet = UWGateway(id: "all", name: "All Internet", gatewayURL: URL(string: "https://huskyonnet-ns.uw.edu/")!, splitRules: false)
    static let campusOnly = UWGateway(id: "campus", name: "Campus Only", gatewayURL: URL(string: "https://huskyonnet.uw.edu/")!, splitRules: true)

    var title: String { "\(name) (\(gatewayHost))" }
    var shortLabel: String { name }
    var publishesSplitRules: Bool { splitRules == true }
    var isUWPreset: Bool { [Self.allInternet.gatewayHost, Self.campusOnly.gatewayHost].contains(gatewayHost) }
    var usesUWRoute: Bool {
        (id == Self.allInternet.id && gatewayHost == Self.allInternet.gatewayHost) ||
        (id == Self.campusOnly.id && gatewayHost == Self.campusOnly.gatewayHost)
    }
    var gatewayDNSFallback: [String] {
        fallbackDNSServers ?? (isUWPreset ? ["1.1.1.1", "2606:4700:4700::1111", "8.8.8.8"] : [])
    }
    var ruleFileStem: String { "uw-\(webStoreUUID.uuidString.lowercased())" }

    var gatewayHost: String {
        gatewayURL.host!.lowercased()
    }

    var sessionAccount: String { "\(id)@\(gatewayHost)" }

    var webStoreUUID: UUID {
        let b = Array(SHA256.hash(data: Data(sessionAccount.utf8)).prefix(16))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

struct GatewayRoute: Hashable {
    let gateway: UWGateway
    let socksPort: UInt16
    let policyName: String
    let splitPolicyName: String

    var usesCustomFallback: Bool {
        !gateway.usesUWRoute && gateway.publishesSplitRules && gateway.effectiveHealthCheckURL != nil
    }

    var splitPolicy: String {
        gateway.usesUWRoute || usesCustomFallback ? splitPolicyName : policyName
    }

    init(gateway: UWGateway) {
        self.gateway = gateway
        if gateway.usesUWRoute {
            socksPort = UWConfig.socksPort
            policyName = "UW-VPN"
            splitPolicyName = "UW-Campus"
        } else {
            let offset = SHA256.hash(data: Data(gateway.sessionAccount.utf8)).prefix(4)
                .reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 48000
            socksPort = UInt16(12000 + offset)
            let suffix = gateway.webStoreUUID.uuidString
            policyName = "UWVPN-\(suffix)"
            splitPolicyName = "\(policyName)-Split"
        }
    }
}

struct GatewayConfiguration: Codable {
    let defaultGateway: String
    let gateways: [UWGateway]
    let directHosts: [String]?

    static let presets = GatewayConfiguration(defaultGateway: "all", gateways: [.allInternet, .campusOnly], directHosts: ["idp.u.washington.edu"])
    static let file = UWConfig.supportDirectory.appendingPathComponent("config.json")

    var defaultSelection: UWGateway { gateways.first { $0.id == defaultGateway }! }
    var routes: [String: GatewayRoute] {
        Dictionary(uniqueKeysWithValues: gateways.map { ($0.id, GatewayRoute(gateway: $0)) })
    }
    var bypassHosts: [String] { Array(Set((gateways.map(\.gatewayHost) + (directHosts ?? [])).map { $0.lowercased() })).sorted() }

    static func load(from file: URL = Self.file) throws -> GatewayConfiguration {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return presets
        }
        return try JSONDecoder().decode(Self.self, from: data).validated()
    }

    static func createIfMissing() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: UWConfig.supportDirectory, withIntermediateDirectories: true)
        do {
            try encoder.encode(presets).write(to: file, options: .withoutOverwriting)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {}
    }

    private func validated() throws -> Self {
        var ids = Set<String>()
        var dnsPolicies: [String: [String]] = [:]
        for gateway in gateways {
            let url = gateway.gatewayURL
            guard gateway.id.range(of: "^[a-zA-Z0-9_-]{1,48}$", options: .regularExpression) != nil,
                  ids.insert(gateway.id).inserted, !gateway.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  gateway.name.rangeOfCharacter(from: .controlCharacters) == nil,
                  url.scheme?.lowercased() == "https", url.user == nil,
                  URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPassword == nil,
                  url.port == nil || url.port == 443, url.query == nil, url.fragment == nil,
                  url.path.isEmpty || url.path == "/",
                  let host = url.host, Self.isHostname(host) else {
                throw ConfigurationError("Invalid gateway \(gateway.id). Use a unique ID, a display name, and a root HTTPS URL on port 443.")
            }
            let servers = gateway.gatewayDNSFallback
            guard servers.allSatisfy({ text in
                var ipv4 = in_addr()
                var ipv6 = in6_addr()
                return !text.utf8.contains(0) && (inet_pton(AF_INET, text, &ipv4) == 1 || inet_pton(AF_INET6, text, &ipv6) == 1)
            }) else { throw ConfigurationError("fallbackDNSServers must contain IP addresses.") }
            if let existing = dnsPolicies.updateValue(servers, forKey: gateway.gatewayHost), existing != servers {
                throw ConfigurationError("Gateways on the same host must use the same fallbackDNSServers.")
            }
        }
        guard ids.contains(defaultGateway) else { throw ConfigurationError("defaultGateway must match a gateway ID.") }
        let routes = gateways.map(GatewayRoute.init)
        for (index, route) in routes.enumerated() {
            for other in routes.dropFirst(index + 1) {
                let canonicalUWPair = route.gateway.usesUWRoute && other.gateway.usesUWRoute
                guard route.socksPort != other.socksPort || canonicalUWPair else {
                    throw ConfigurationError("Gateways \(route.gateway.id) and \(other.gateway.id) have the same SOCKS port \(route.socksPort). Change one gateway ID.")
                }
                guard route.policyName != other.policyName || canonicalUWPair,
                      route.splitPolicyName != other.splitPolicyName || canonicalUWPair,
                      route.policyName != other.splitPolicyName, route.splitPolicyName != other.policyName else {
                    throw ConfigurationError("Gateways \(route.gateway.id) and \(other.gateway.id) have a Surge policy collision. Change one gateway ID.")
                }
            }
        }
        guard (directHosts ?? []).allSatisfy(Self.isHostname) else {
            throw ConfigurationError("directHosts must contain plain hostnames.")
        }
        return self
    }

    private static func isHostname(_ host: String) -> Bool {
        !host.isEmpty && host.utf8.count <= 253 && host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            $0.range(of: "^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$", options: .regularExpression) != nil
        }
    }
}

struct ConfigurationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct StoredSession: Codable, Equatable {
    var sessionID: String
    var f5ST: String
    var expiresAt: TimeInterval?
    var savedAt: TimeInterval

    var cookieHeader: String {
        "MRHSession=\(sessionID); F5_ST=\(f5ST)"
    }

    var isValidNow: Bool {
        guard Self.isValidToken(sessionID), Self.isValidToken(f5ST),
              cookieHeader.utf8.count <= UWConfig.maxCookieHeaderBytes else {
            return false
        }
        if let expiresAt {
            return expiresAt.isFinite && expiresAt > Date().timeIntervalSince1970 + UWConfig.expirySafetyMargin
        }
        return true
    }

    var remainingDescription: String? {
        guard let expiresAt, expiresAt.isFinite else { return nil }
        let delta = max(0, expiresAt - Date().timeIntervalSince1970)
        let capped = min(delta, 365 * 24 * 3600)
        let totalMinutes = Int(capped) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    static func isValidToken(_ value: String) -> Bool {
        !value.isEmpty &&
        value != "deleted" &&
        value.utf8.count <= 2048 &&
        value.utf8.allSatisfy { (0x21...0x7E).contains($0) && $0 != 0x3B }
    }

    static func parseF5STExpiration(_ value: String) -> TimeInterval? {
        // F5 session timeout cookie format (F5 K15387): 1z1z1z<start_epoch_sec>z<duration_sec>
        let parts = value.split(separator: "z", omittingEmptySubsequences: false)
        guard parts.count >= 5,
              let start = UInt64(parts[3]),
              let duration = UInt64(parts[4]),
              start > 0, duration > 0 else {
            return nil
        }
        let (sum, overflow) = start.addingReportingOverflow(duration)
        guard !overflow else { return nil }
        return TimeInterval(sum)
    }
}

enum TunnelState: Equatable {
    case disconnected
    case authenticating
    case connecting
    case connected(since: Date)
    case reconnecting(attempt: Int)
    case error(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isBusyOrUp: Bool {
        switch self {
        case .authenticating, .connecting, .connected, .reconnecting:
            return true
        case .disconnected, .error:
            return false
        }
    }
}

enum UWConfig {
    static let socksPort: UInt16 = 11080
    static let loopbackHost = "127.0.0.1"
    static let httpsPort: UInt16 = 443
    static let dnsPort: UInt16 = 53
    static let maxCookieHeaderBytes = 3840
    static let expirySafetyMargin: TimeInterval = 60
    static let keepaliveInterval: TimeInterval = 480
    static let openconnectReconnectTimeoutSec = 300
    static let maxReconnectBackoffSec: TimeInterval = 30
    static let linuxUserAgent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    static let campusTestURL = "https://husky-onnet-test.uw.edu/vpn-test/"
    static let publicIPTestURL = "https://api.ipify.org/"
    static let surgeCLIPath = "/Applications/Surge.app/Contents/Applications/surge-cli"
    static let supportDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/UWVPN")
}

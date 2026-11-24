import Foundation

enum UWGateway: String, CaseIterable, Identifiable {
    case allInternet = "all"
    case campusOnly = "campus"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allInternet: return "All Internet (huskyonnet-ns.uw.edu)"
        case .campusOnly: return "Campus Only (huskyonnet.uw.edu)"
        }
    }

    var shortLabel: String {
        switch self {
        case .allInternet: return "All Internet"
        case .campusOnly: return "Campus Only"
        }
    }

    var gatewayURL: URL {
        switch self {
        case .allInternet: return URL(string: "https://huskyonnet-ns.uw.edu/")!
        case .campusOnly: return URL(string: "https://huskyonnet.uw.edu/")!
        }
    }

    var gatewayHost: String {
        gatewayURL.host!.lowercased()
    }

    var webStoreUUID: UUID {
        switch self {
        case .allInternet: return UUID(uuidString: "A5428E7A-3C2D-4C86-9F6A-3B57C36A1002")!
        case .campusOnly: return UUID(uuidString: "A5428E7A-3C2D-4C86-9F6A-3B57C36A1001")!
        }
    }

    static var allowedGatewayHosts: Set<String> {
        Set(allCases.map(\.gatewayHost))
    }
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
    static let ocproxyKeepaliveSec = 15
    static let maxReconnectBackoffSec: TimeInterval = 30
    static let linuxUserAgent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    static let campusTestURL = "https://husky-onnet-test.uw.edu/vpn-test/"
    static let publicIPTestURL = "https://api.ipify.org/"
    static let legacyLaunchAgentLabel = "com.blueagle.uwvpn"
    static let surgeCLIPath = "/Applications/Surge.app/Contents/Applications/surge-cli"
}

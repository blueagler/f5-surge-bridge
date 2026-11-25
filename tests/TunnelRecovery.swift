import Darwin
import Foundation

// The fixture uses a synthetic cached session and never accesses the real Keychain.
enum KeychainStore {
    static func load(gateway: UWGateway) -> Result<StoredSession?, NSError> {
        .success(StoredSession(sessionID: "fixture", f5ST: "fixture", expiresAt: nil, savedAt: 0))
    }

    static func save(session: StoredSession, gateway: UWGateway) -> Result<Void, NSError> { .success(()) }
    static func clear(gateway: UWGateway) -> Result<Void, NSError> { .success(()) }
}

@main
struct TunnelRecovery {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let port = UInt16(CommandLine.arguments[2])!
        setenv("UWVPN_FIXTURE_PORT", String(port), 1)
        setenv("UWVPN_FIXTURE_PIDS", fixture.path, 1)
        do {
            _ = try SurgeModule.command(["5"], executable: "/bin/sleep", timeout: 0.1)
            preconditionFailure("A hung Surge command must time out")
        } catch {
            precondition(error.localizedDescription.contains("timed out"))
        }

        let healthOnly = CommandLine.arguments.contains("--health")
        let occupied = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        if !healthOnly {
            precondition(occupied >= 0)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(occupied, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            precondition(bound == 0 && Darwin.listen(occupied, 1) == 0)
        }

        let relay = GatewayRelay(gateways: GatewayConfiguration.presets.gateways)
        var original = [Int32]()
        var sawRecovery = false
        var sawOccupied = false
        var runner: TunnelRunner!
        runner = TunnelRunner(relay: relay, configuration: .presets, socksPort: port) {
            if healthOnly {
                if case .connected(_, .degraded) = runner.state, original.isEmpty {
                    original = try! String(contentsOf: fixture, encoding: .utf8)
                        .split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
                    precondition(original.count == 2)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        precondition(kill(original[0], 0) == 0)
                        print("Silent upstream reported degraded without reconnecting")
                        runner.quitAsync { exit(0) }
                    }
                }
                return
            }
            switch runner.state {
            case .connected:
                let current = try! String(contentsOf: fixture, encoding: .utf8)
                    .split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
                precondition(current.count == 2)
                if original.isEmpty {
                    precondition(sawOccupied)
                    original = current
                    precondition(kill(current[1], SIGKILL) == 0)
                    precondition(kill(current[0], 0) == 0)
                } else {
                    precondition(sawRecovery && current[0] != original[0] && current[1] != original[1])
                    print("Recovered the SOCKS5 listener with the cached session")
                    runner.quitAsync { exit(0) }
                }
            case .reconnecting where original.isEmpty:
                sawOccupied = true
            case .reconnecting where !sawRecovery:
                precondition(original.count == 2 && kill(original[0], 0) == 0)
                sawRecovery = true
            default:
                break
            }
        }
        if !healthOnly {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { Darwin.close(occupied) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            runner.quitAsync { exit(1) }
        }
        runner.connect()
        RunLoop.main.run()
    }
}

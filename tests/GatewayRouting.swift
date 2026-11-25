import Foundation

@main
struct GatewayRoutingTests {
    static func main() throws {
        let work = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let configFile = work.appendingPathComponent("config.json")
        let json = """
        {"defaultGateway":"work","gateways":[
          {"id":"work","name":"Work","gatewayURL":"https://work.example.com/","splitRules":true,"healthCheckURL":"https://health.example.com/check"},
          {"id":"other","name":"Other","gatewayURL":"https://other.example.com/","splitRules":true}
        ],"directHosts":["login.example.com"]}
        """
        try Data(json.utf8).write(to: configFile)
        let config = try GatewayConfiguration.load(from: configFile)
        let workRoute = config.routes["work"]!
        let otherRoute = config.routes["other"]!
        precondition(workRoute.socksPort != otherRoute.socksPort)
        precondition(workRoute.policyName != otherRoute.policyName)
        precondition(GatewayRoute(gateway: .allInternet).socksPort == 11080)
        precondition(GatewayRoute(gateway: .campusOnly).socksPort == 11080)
        precondition(GatewayRoute(gateway: .allInternet).policyName == "UW-VPN")
        precondition(GatewayRoute(gateway: .campusOnly).splitPolicyName == "UW-Campus")
        let legacy = work.appendingPathComponent("legacy.json")
        try Data(#"{"defaultGateway":"all","gateways":[{"id":"all","name":"All Internet","gatewayURL":"https://huskyonnet-ns.uw.edu/","splitRules":false},{"id":"campus","name":"Campus Only","gatewayURL":"https://huskyonnet.uw.edu/","splitRules":true}]}"#.utf8).write(to: legacy)
        _ = try GatewayConfiguration.load(from: legacy)
        let collision = work.appendingPathComponent("collision.json")
        let legacyUW = UWGateway.allInternet
        let duplicateUW = UWGateway(id: "other-uw", name: "Other UW", gatewayURL: legacyUW.gatewayURL, splitRules: false)
        precondition(GatewayRoute(gateway: legacyUW).socksPort != GatewayRoute(gateway: duplicateUW).socksPort)
        let colliding = GatewayConfiguration(defaultGateway: "all", gateways: [legacyUW, duplicateUW], directHosts: nil)
        try JSONEncoder().encode(colliding).write(to: collision)
        _ = try GatewayConfiguration.load(from: collision)

        let support = work.appendingPathComponent("support")
        let cli = work.appendingPathComponent("surge-cli")
        let profile = work.appendingPathComponent("profiles")
        let script = """
        #!/bin/zsh
        if [[ "$1 $2" == "dump policy" ]]; then
          print '\(workRoute.policyName)\n\(workRoute.splitPolicyName)\n\(otherRoute.policyName)'
        elif [[ "$1 $2 $3" == "profile section list" ]]; then
          print 'Profile (\(profile.path)/profile.conf)'
        elif [[ "$1 $2" == "module show" ]]; then
          if [[ -f "\(profile.path)/uw-vpn.sgmodule" ]]; then
            print 'Type: local\nPath: \(profile.path)/uw-vpn.sgmodule\nEnabled: yes'
          else
            exit 1
          fi
        fi
        """
        try Data(script.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        _ = try SurgeModule.install(configuration: config, support: support, executable: cli.path)
        let module = try String(contentsOf: profile.appendingPathComponent("uw-vpn.sgmodule"), encoding: .utf8)
        let definitions = SurgeModule.profileDefinitions(configuration: config)
        precondition(definitions.contains("\(workRoute.policyName) = socks5, 127.0.0.1, \(workRoute.socksPort), udp-relay=true, test-url=https://health.example.com/check"))
        precondition(definitions.contains("\(workRoute.splitPolicyName) = fallback, \(workRoute.policyName), DIRECT"))
        precondition(!module.contains("[Proxy"))
        precondition(module.contains("\(config.gateways[1].ruleFileStem)-split.list,\(otherRoute.policyName)"))
        precondition(module.contains("DOMAIN,login.example.com,DIRECT"))
        precondition(!module.contains("api.ipify.org"))
        print("Custom routes, health URLs, and legacy configuration passed")

        let callbacks = LockedCallbacks()
        var coordinator: SurgeReloadCoordinator!
        coordinator = SurgeReloadCoordinator(retryDelay: 0.05) { completion in
            callbacks.append(completion)
        }
        coordinator.update("old")
        coordinator.update("latest")
        precondition(callbacks.count == 1)
        callbacks.complete(0, success: false)
        drainMain(0.03)
        precondition(callbacks.count == 2, "failed reload must schedule latest snapshot, saw \(callbacks.count)")
        callbacks.complete(1, success: true)
        drainMain(0.12)
        precondition(callbacks.count == 2)
        coordinator.update("latest")
        drainMain(0.08)
        precondition(callbacks.count == 2)
        coordinator.update("first")
        coordinator.update("last")
        precondition(callbacks.count == 3)
        callbacks.complete(2, success: true)
        drainMain(0.03)
        precondition(callbacks.count == 4)
        callbacks.complete(3, success: true)
        drainMain(0.08)
        precondition(callbacks.count == 4)
        coordinator.update("retry")
        precondition(callbacks.count == 5)
        callbacks.complete(4, success: false)
        drainMain(0.09)
        precondition(callbacks.count == 6)
        callbacks.complete(5, success: true)
        drainMain(0.08)
        precondition(callbacks.count == 6)
        coordinator.update("intermediate")
        coordinator.update("retry")
        precondition(callbacks.count == 7)
        callbacks.complete(6, success: true)
        drainMain(0.09)
        precondition(callbacks.count == 8, "Returning to the previous revision must supersede the in-flight reload")
        callbacks.complete(7, success: true)
        drainMain(0.08)
        precondition(callbacks.count == 8)
        print("Retry and latest-wins in-flight reload behavior passed")
        exit(0)
    }

    static func drainMain(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}

final class LockedCallbacks {
    private let lock = NSLock()
    private var completions: [(Bool) -> Void] = []
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return completions.count
    }
    func append(_ completion: @escaping (Bool) -> Void) {
        lock.lock()
        completions.append(completion)
        lock.unlock()
    }
    func complete(_ index: Int, success: Bool) {
        lock.lock()
        let completion = completions[index]
        lock.unlock()
        completion(success)
    }
}

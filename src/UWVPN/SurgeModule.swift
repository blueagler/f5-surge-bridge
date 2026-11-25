import Foundation
import Darwin

final class SurgeReloadCoordinator {
    private var desired: String?
    private var lastLoaded: String?
    private var active = false
    private var retryWork: DispatchWorkItem?
    private let retryDelay: TimeInterval
    private let reload: (@escaping (Bool) -> Void) -> Void

    init(retryDelay: TimeInterval = 5, reload: @escaping (@escaping (Bool) -> Void) -> Void) {
        self.retryDelay = retryDelay
        self.reload = reload
    }

    func update(_ snapshot: String) {
        guard snapshot != desired else { return }
        desired = snapshot
        start()
    }

    private func start() {
        guard !active, let candidate = desired, candidate != lastLoaded else { return }
        retryWork?.cancel()
        retryWork = nil
        active = true
        reload { [weak self] succeeded in
            DispatchQueue.main.async {
                guard let self else { return }
                self.active = false
                self.lastLoaded = succeeded ? candidate : nil
                if succeeded || self.desired != candidate {
                    self.start()
                } else {
                    let retry = DispatchWorkItem { [weak self] in self?.start() }
                    self.retryWork = retry
                    DispatchQueue.main.asyncAfter(deadline: .now() + self.retryDelay, execute: retry)
                }
            }
        }
    }
}

enum SurgeModule {
    private static let name = "UW Husky OnNet"
    private static let filename = "uw-vpn.sgmodule"
    private static let mutationLock = NSLock()

    static func reload() throws {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        _ = try command(["reload"])
    }

    static func install(configuration: GatewayConfiguration, support: URL = UWConfig.supportDirectory,
                        executable: String = UWConfig.surgeCLIPath) throws -> String {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        func command(_ arguments: [String]) throws -> String {
            try Self.command(arguments, executable: executable)
        }
        let policies = try command(["dump", "policy"])
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        var required = Set<String>()
        for gateway in configuration.gateways where gateway.usesUWRoute {
            required.insert("UW-VPN")
            if gateway.publishesSplitRules { required.insert("UW-Campus") }
        }
        guard required.isSubset(of: Set(policies)) else {
            throw ConfigurationError("Add the \(required.sorted().joined(separator: " and ")) definitions to the active Mac Surge profile first. Set udp-relay=true for UW-VPN.")
        }
        let installed = try? command(["module", "show", name])
        let destination = try moduleURL(installed: installed, command: command)
        let module = try render(configuration: configuration, support: support)
        let previous = FileManager.default.fileExists(atPath: destination.path) ? try Data(contentsOf: destination) : nil
        if let previous, !previous.starts(with: Data("#!name=\(name)\n".utf8)) {
            throw ConfigurationError("A different module already exists at \(destination.path).")
        }
        let previousText = previous.map { String(decoding: $0, as: UTF8.self) } ?? ""
        for route in configuration.routes.values where !route.gateway.usesUWRoute {
            let usesGroup = route.gateway.publishesSplitRules && route.gateway.effectiveHealthCheckURL != nil
            let names = [route.policyName] + (usesGroup ? [route.splitPolicyName] : [])
            for policy in names where policies.contains(policy) && !previousText.contains("\(policy) =") {
                throw ConfigurationError("Surge already has a policy named \(policy). Choose a different gateway ID.")
            }
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(module.utf8).write(to: destination, options: .atomic)
        do {
            _ = try command(["reload"])
            let discovered = try command(["module", "show", name])
            guard let path = reportedPath(discovered),
                  path.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() else {
                throw ConfigurationError("Surge did not load the module at \(destination.path).")
            }
            if !isEnabled(discovered) {
                _ = try command(["module", "enable", name])
            }
            guard isEnabled(try command(["module", "show", name])) else {
                throw ConfigurationError("Surge did not enable the module.")
            }
        } catch {
            let originalError = error
            do {
                if let previous {
                    try previous.write(to: destination, options: .atomic)
                } else {
                    try FileManager.default.removeItem(at: destination)
                }
                _ = try command(["reload"])
            } catch {
                throw ConfigurationError("\(originalError.localizedDescription) Rollback also failed. \(error.localizedDescription)")
            }
            throw originalError
        }
        return "\(destination.path)\n\nFor UDP, set udp-relay=true on UW-VPN in the active Mac profile."
    }

    private static func render(configuration: GatewayConfiguration, support: URL) throws -> String {
        var rules = configuration.bypassHosts.map { "DOMAIN,\($0),DIRECT" }
        var proxies = [String]()
        var groups = [String]()
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        for gateway in configuration.gateways {
            let route = configuration.routes[gateway.id]!
            let health = gateway.effectiveHealthCheckURL?.absoluteString
            if !gateway.usesUWRoute {
                let testURL = health.map { ", test-url=\($0.replacingOccurrences(of: ",", with: "%2C"))" } ?? ""
                proxies.append("\(route.policyName) = socks5, \(UWConfig.loopbackHost), \(route.socksPort), udp-relay=true\(testURL)")
            }
            guard gateway.publishesSplitRules else { continue }
            let usesGroup = gateway.usesUWRoute || health != nil
            for (suffix, policy) in [("exclude", "DIRECT"), ("split", usesGroup ? route.splitPolicyName : route.policyName)] {
                let file = support.appendingPathComponent("\(gateway.ruleFileStem)-\(suffix).list")
                guard !file.path.contains(","), file.path.rangeOfCharacter(from: .newlines) == nil else {
                    throw ConfigurationError("The split rules folder has a path Surge cannot use.")
                }
                do {
                    try Data("# Populated when \(gateway.name) connects.\n".utf8).write(to: file, options: .withoutOverwriting)
                } catch let error as CocoaError where error.code == .fileWriteFileExists {}
                rules.append("RULE-SET,\(file.path),\(policy)")
            }
            if !gateway.usesUWRoute && usesGroup {
                groups.append("\(route.splitPolicyName) = fallback, \(route.policyName), DIRECT, interval=60, evaluate-before-use=true")
            }
        }
        return """
        #!name=\(name)
        #!desc=Route each VPN through its own gateway and send configured login hosts direct
        #!system=mac

        [Proxy]
        \(proxies.joined(separator: "\n"))

        [Proxy Group]
        \(groups.joined(separator: "\n"))

        [Rule]
        \(rules.joined(separator: "\n"))

        """
    }

    private static func moduleURL(installed: String?, command: ([String]) throws -> String) throws -> URL {
        if let installed {
            guard installed.split(whereSeparator: \.isNewline).contains("Type: local"),
                  let path = reportedPath(installed), path.lastPathComponent == filename else {
                throw ConfigurationError("Surge already has a different module named \(name).")
            }
            return path.resolvingSymlinksInPath()
        }
        if let sections = try? command(["profile", "section", "list"]),
           let profile = sections.split(whereSeparator: \.isNewline).first,
           profile.hasSuffix(")"), let path = profile.range(of: " (/", options: .backwards) {
            let profilePath = "/" + profile[path.upperBound...].dropLast()
            return URL(fileURLWithPath: String(profilePath)).deletingLastPathComponent().appendingPathComponent(filename)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/iCloud~com~nssurge~inc/Documents", isDirectory: true)
        let local = home.appendingPathComponent("Library/Application Support/Surge/Profiles", isDirectory: true)
        let directory = FileManager.default.fileExists(atPath: iCloud.path) ? iCloud : local
        return directory.appendingPathComponent(filename)
    }

    private static func reportedPath(_ output: String) -> URL? {
        guard let line = output.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("Path: /") }) else { return nil }
        return URL(fileURLWithPath: String(line.dropFirst("Path: ".count)))
    }

    private static func isEnabled(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains("Enabled: yes")
    }

    static func command(_ arguments: [String], executable: String = UWConfig.surgeCLIPath, timeout: TimeInterval = 12) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ConfigurationError("Install Surge for Mac in /Applications first.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("output")
        try Data().write(to: outputURL)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let process = Process()
        let exited = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            throw ConfigurationError("Surge timed out while running \(arguments.joined(separator: " ")).")
        }
        let text = String(decoding: try Data(contentsOf: outputURL), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ConfigurationError("Surge could not \(arguments.joined(separator: " ")). \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return text
    }
}

import Foundation

enum SurgeModule {
    private static let name = "UW Husky OnNet"
    private static let filename = "uw-vpn.sgmodule"

    static func install(configuration: GatewayConfiguration) throws -> String {
        let policies = try command(["dump", "policy"])
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let required = configuration.gateways.contains(where: \.publishesSplitRules) ? ["UW-VPN", "UW-Campus"] : ["UW-VPN"]
        guard required.allSatisfy(policies.contains) else {
            throw ConfigurationError("Add the \(required.joined(separator: " and ")) definitions to the active Mac Surge profile first. Set udp-relay=true for UW-VPN.")
        }
        let installed = try? command(["module", "show", name])
        let destination = try moduleURL(installed: installed)
        let module = try render(configuration: configuration, support: UWConfig.supportDirectory)
        let previous = FileManager.default.fileExists(atPath: destination.path) ? try Data(contentsOf: destination) : nil
        if let previous, !previous.starts(with: Data("#!name=\(name)\n".utf8)) {
            throw ConfigurationError("A different module already exists at \(destination.path).")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(module.utf8).write(to: destination, options: .atomic)
        do {
            _ = try command(["reload"])
            let discovered = try command(["module", "show", name])
            guard let path = reportedPath(discovered), path.standardizedFileURL == destination.standardizedFileURL else {
                throw ConfigurationError("Surge did not load the module at \(destination.path).")
            }
            if !isEnabled(discovered) {
                _ = try command(["module", "enable", name])
            }
            guard isEnabled(try command(["module", "show", name])) else {
                throw ConfigurationError("Surge did not enable the module.")
            }
        } catch {
            if let previous {
                try previous.write(to: destination, options: .atomic)
            } else {
                try FileManager.default.removeItem(at: destination)
            }
            _ = try? command(["reload"])
            throw error
        }
        return "\(destination.path)\n\nFor UDP, set udp-relay=true on UW-VPN in the active Mac profile."
    }

    private static func render(configuration: GatewayConfiguration, support: URL) throws -> String {
        var rules = configuration.bypassHosts.map { "DOMAIN,\($0),DIRECT" }
        if let gateway = configuration.gateways.first(where: \.publishesSplitRules) {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            for (suffix, policy) in [("exclude", "DIRECT"), ("split", "UW-Campus")] {
                let file = support.appendingPathComponent("\(gateway.ruleFileStem)-\(suffix).list")
                guard !file.path.contains(","), file.path.rangeOfCharacter(from: .newlines) == nil else {
                    throw ConfigurationError("The split rules folder has a path Surge cannot use.")
                }
                do {
                    try Data("# Populated when \(gateway.name) connects.\n".utf8).write(to: file, options: .withoutOverwriting)
                } catch let error as CocoaError where error.code == .fileWriteFileExists {}
                rules.append("RULE-SET,\(file.path),\(policy)")
            }
        }
        return """
        #!name=\(name)
        #!desc=Route VPN split rules and send configured login hosts direct
        #!system=mac

        [Rule]
        \(rules.joined(separator: "\n"))

        """
    }

    private static func moduleURL(installed: String?) throws -> URL {
        if let installed {
            guard installed.split(whereSeparator: \.isNewline).contains("Type: local"),
                  let path = reportedPath(installed), path.lastPathComponent == filename else {
                throw ConfigurationError("Surge already has a different module named \(name).")
            }
            return path
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

    private static func command(_ arguments: [String]) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: UWConfig.surgeCLIPath) else {
            throw ConfigurationError("Install Surge for Mac in /Applications first.")
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: UWConfig.surgeCLIPath)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ConfigurationError("Surge could not \(arguments.joined(separator: " ")). \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return text
    }
}

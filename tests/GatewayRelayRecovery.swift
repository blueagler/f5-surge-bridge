import Darwin
import Foundation

@main
struct GatewayRelayRecovery {
    static func main() throws {
        let configFile = URL(fileURLWithPath: CommandLine.arguments[1])
        let gateway = #"{"id":"office","name":"Office","gatewayURL":"https://vpn.example.com/"}"#
        func load(_ entry: String) throws -> GatewayConfiguration {
            try Data("{\"defaultGateway\":\"office\",\"gateways\":[\(entry)]}".utf8).write(to: configFile)
            return try GatewayConfiguration.load(from: configFile)
        }
        let config = try load(gateway)
        precondition(config.defaultSelection.gatewayDNSFallback.isEmpty)
        let explicit = try load(gateway.dropLast() + #", "fallbackDNSServers":["2001:db8::53"]}"#)
        precondition(explicit.defaultSelection.gatewayDNSFallback == ["2001:db8::53"])
        let invalid = gateway.dropLast() + #", "fallbackDNSServers":["invalid"]}"#
        precondition((try? load(String(invalid))) == nil)

        // One recoverable capacity error, followed by an error that requires rebinding.
        var failures: [Int32] = [EMFILE, EINVAL]
        let relay = GatewayRelay(gateways: config.gateways) { listener in
            if !failures.isEmpty { errno = failures.removeFirst(); return -1 }
            return Darwin.accept(listener, nil, nil)
        }
        try relay.start()
        defer { relay.stop() }
        let port = relay.port
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if rejectsUnknownHost(port) {
                precondition(relay.port == port)
                print("Gateway relay recovered its original port and enforced the gateway allowlist")
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        fatalError("Gateway relay did not resume accepting connections")
    }

    static func rejectsUnknownHost(_ port: UInt16) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var noPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout.size(ofValue: noPipe)))
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var endpoint = sockaddr_in()
        endpoint.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        endpoint.sin_family = sa_family_t(AF_INET)
        endpoint.sin_port = port.bigEndian
        endpoint.sin_addr.s_addr = inet_addr("127.0.0.1")
        guard withUnsafePointer(to: &endpoint, { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }) == 0 else { return false }
        let request = Data("CONNECT other.invalid:443 HTTP/1.1\r\n\r\n".utf8)
        guard request.withUnsafeBytes({ Darwin.send(fd, $0.baseAddress, $0.count, 0) }) == request.count else { return false }
        var response = [UInt8](repeating: 0, count: 128)
        let count = Darwin.recv(fd, &response, response.count, 0)
        return count > 0 && String(decoding: response.prefix(count), as: UTF8.self).hasPrefix("HTTP/1.1 403")
    }
}

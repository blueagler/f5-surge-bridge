import Darwin
import Foundation
import SystemConfiguration

final class GatewayRelay {
    private let allowedHosts: Set<String>
    private let maxHeaderBytes = 8192
    private let maxConcurrentTunnels = 64
    private let ioBufferBytes = 16384
    private let handshakeTimeoutSec: TimeInterval = 15.0
    private let dnsTimeoutSec = 1
    private let dnsCacheTTL: TimeInterval = 60.0
    private let pathCacheTTL: TimeInterval = 15.0

    init(gateways: [UWGateway]) {
        allowedHosts = Set(gateways.map(\.gatewayHost))
    }

    private enum IPAddress {
        case v4(in_addr)
        case v6(in6_addr)

        init?(_ text: String) {
            var v4 = in_addr()
            var v6 = in6_addr()
            if inet_pton(AF_INET, text, &v4) == 1 {
                self = .v4(v4)
            } else if inet_pton(AF_INET6, text, &v6) == 1 {
                self = .v6(v6)
            } else {
                return nil
            }
        }

        init(_ address: UnsafePointer<sockaddr>) {
            if address.pointee.sa_family == AF_INET6 {
                self = .v6(address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr })
            } else {
                self = .v4(address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr })
            }
        }

        var family: Int32 {
            if case .v4 = self { return AF_INET }
            return AF_INET6
        }

        var isUsable: Bool {
            switch self {
            case .v4(let address):
                let ip = UInt32(bigEndian: address.s_addr)
                return ip != 0 && ip & 0xFFFE_0000 != 0xC612_0000 // Surge 198.18.0.0/15
            case .v6(var address):
                return withUnsafeBytes(of: &address) { ip in
                    let surgePrefix: [UInt8] = [0xfd, 0, 0x61, 0x52]
                    return ip.contains { $0 != 0 } && !ip.starts(with: surgePrefix)
                }
            }
        }

        func connect(_ fd: Int32, port: UInt16, ifaceIndex: UInt32) -> Int32 {
            switch self {
            case .v4(let address):
                var endpoint = sockaddr_in()
                endpoint.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                endpoint.sin_family = sa_family_t(AF_INET)
                endpoint.sin_port = port.bigEndian
                endpoint.sin_addr = address
                return withUnsafePointer(to: &endpoint) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            case .v6(let address):
                var endpoint = sockaddr_in6()
                endpoint.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                endpoint.sin6_family = sa_family_t(AF_INET6)
                endpoint.sin6_port = port.bigEndian
                endpoint.sin6_addr = address
                if withUnsafeBytes(of: address, { $0[0] == 0xfe && $0[1] & 0xc0 == 0x80 }) {
                    endpoint.sin6_scope_id = ifaceIndex
                }
                return withUnsafePointer(to: &endpoint) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
                }
            }
        }
    }

    private struct NetworkSnapshot {
        let ifaceName: String
        let ifaceIndex: UInt32
        let dnsServers: [String]
        let capturedAt: TimeInterval
    }

    private struct CachedAddresses {
        let addresses: [IPAddress]
        let expiresAt: TimeInterval
    }

    private final class DNSAnswers: @unchecked Sendable {
        private let lock = NSLock()
        private var addresses: [UInt8: [IPAddress]] = [:]

        func store(_ result: [IPAddress], type: UInt8) {
            lock.lock()
            addresses[type] = result
            lock.unlock()
        }

        var combined: [IPAddress] {
            lock.lock()
            defer { lock.unlock() }
            return (addresses[1] ?? []) + (addresses[28] ?? [])
        }
    }

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private(set) var port: UInt16 = 0
    private var running = false
    private var activeFDs: Set<Int32> = []
    private var activeTunnelCount = 0
    private var cachedSnapshot: NetworkSnapshot?
    private var dnsCache: [String: CachedAddresses] = [:]
    private let workerQueue = DispatchQueue(label: "com.blueagle.uwvpn.relay.workers", attributes: .concurrent)

    func start() throws {
        lock.lock()
        if running {
            lock.unlock()
            return
        }
        lock.unlock()

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        configureSocketFlags(fd)

        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr(UWConfig.loopbackHost))

        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0 else {
            let err = errno
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameRes = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &len)
            }
        }
        guard nameRes == 0 else {
            let err = errno
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }

        guard Darwin.listen(fd, 64) == 0 else {
            let err = errno
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }

        lock.lock()
        port = UInt16(bigEndian: bound.sin_port)
        listenFD = fd
        running = true
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        lock.lock()
        running = false
        let lfd = listenFD
        listenFD = -1
        let fds = activeFDs
        activeFDs.removeAll()
        lock.unlock()

        if lfd >= 0 { Darwin.close(lfd) }
        for fd in fds {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }

    func invalidateNetworkCache() {
        lock.lock()
        cachedSnapshot = nil
        dnsCache.removeAll()
        lock.unlock()
    }

    func currentPhysicalInterfaceName() -> String? {
        currentNetworkSnapshot()?.ifaceName
    }

    private func isRunning() -> Bool {
        lock.lock()
        let r = running
        lock.unlock()
        return r
    }

    private func registerFD(_ fd: Int32) {
        lock.lock()
        activeFDs.insert(fd)
        lock.unlock()
    }

    private func closeTrackedFD(_ fd: Int32) {
        lock.lock()
        let removed = activeFDs.remove(fd) != nil
        lock.unlock()
        if removed {
            Darwin.close(fd)
        }
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let shouldContinue = running
            let fd = listenFD
            lock.unlock()
            guard shouldContinue, fd >= 0 else { break }

            var clientAddr = sockaddr_storage()
            var addrLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(fd, $0, &addrLen)
                }
            }
            if clientFD < 0 {
                if errno == EINTR { continue }
                break
            }

            configureSocketFlags(clientFD)

            lock.lock()
            let canAccept = running && activeTunnelCount < maxConcurrentTunnels
            if canAccept {
                activeTunnelCount += 1
                activeFDs.insert(clientFD)
            }
            lock.unlock()

            if !canAccept {
                sendAll(clientFD, Data("HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n".utf8))
                Darwin.close(clientFD)
                continue
            }

            workerQueue.async { [weak self] in
                self?.handleClient(clientFD)
            }
        }
    }

    private func handleClient(_ clientFD: Int32) {
        var remoteFD: Int32 = -1
        defer {
            if remoteFD >= 0 { closeTrackedFD(remoteFD) }
            closeTrackedFD(clientFD)
            lock.lock()
            activeTunnelCount = max(0, activeTunnelCount - 1)
            lock.unlock()
        }

        let deadline = Date().addingTimeInterval(handshakeTimeoutSec)
        let headerOutcome = readConnectHeader(clientFD: clientFD, deadline: deadline)
        let headerBytes: Data
        let trailingBytes: Data
        switch headerOutcome {
        case .ok(let h, let t):
            headerBytes = h
            trailingBytes = t
        case .tooLarge:
            sendAll(clientFD, Data("HTTP/1.1 431 Request Header Fields Too Large\r\nConnection: close\r\n\r\n".utf8))
            return
        case .badRequest:
            sendAll(clientFD, Data("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n".utf8))
            return
        case .closedOrTimeout:
            return
        }

        guard let headerText = String(data: headerBytes, encoding: .utf8) else {
            sendAll(clientFD, Data("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendAll(clientFD, Data("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else {
            sendAll(clientFD, Data("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        guard parts[0] == "CONNECT" else {
            sendAll(clientFD, Data("HTTP/1.1 405 Method Not Allowed\r\nConnection: close\r\n\r\n".utf8))
            return
        }

        for line in lines.dropFirst() where !line.isEmpty {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") || lower.hasPrefix("transfer-encoding:") {
                sendAll(clientFD, Data("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n".utf8))
                return
            }
        }

        let authority = parts[1]
        let suffix = ":\(UWConfig.httpsPort)"
        let host = authority.dropLast(suffix.count).lowercased()
        guard authority.hasSuffix(suffix),
              allowedHosts.contains(host) else {
            sendAll(clientFD, Data("HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n".utf8))
            return
        }

        guard let snapshot = currentNetworkSnapshot() else {
            sendAll(clientFD, Data("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n".utf8))
            return
        }

        let candidates = resolveGateway(host: host, snapshot: snapshot, deadline: deadline)
        guard !candidates.isEmpty else {
            sendAll(clientFD, Data("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n".utf8))
            return
        }

        guard let connectedFD = dialCandidates(candidates, ifaceIndex: snapshot.ifaceIndex, deadline: deadline) else {
            sendAll(clientFD, Data("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        remoteFD = connectedFD

        guard sendAll(clientFD, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)) else {
            return
        }
        if !trailingBytes.isEmpty && !sendAll(remoteFD, trailingBytes) {
            return
        }

        pump(fdA: clientFD, fdB: remoteFD)
    }

    private enum HeaderReadResult {
        case ok(Data, Data)
        case tooLarge
        case badRequest
        case closedOrTimeout
    }

    private func readConnectHeader(clientFD: Int32, deadline: Date) -> HeaderReadResult {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 2048)
        let delimiter = Data("\r\n\r\n".utf8)

        while true {
            let remainingMs = Int32(max(0, deadline.timeIntervalSinceNow * 1000.0))
            if remainingMs <= 0 { return .closedOrTimeout }
            var pfd = pollfd(fd: clientFD, events: Int16(POLLIN), revents: 0)
            let pr = Darwin.poll(&pfd, 1, remainingMs)
            if pr < 0 {
                if errno == EINTR { continue }
                return .closedOrTimeout
            }
            if pr == 0 { return .closedOrTimeout }

            let maxToRead = min(chunk.count, maxHeaderBytes + 1 - data.count)
            if maxToRead <= 0 { return .tooLarge }

            let n = Darwin.recv(clientFD, &chunk, maxToRead, 0)
            if n < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                return .closedOrTimeout
            }
            if n == 0 { return data.isEmpty ? .closedOrTimeout : .badRequest }
            data.append(contentsOf: chunk[0..<n])

            if let range = data.range(of: delimiter) {
                if range.upperBound > maxHeaderBytes { return .tooLarge }
                return .ok(data.subdata(in: 0..<range.upperBound), data.subdata(in: range.upperBound..<data.count))
            }
            if data.count >= maxHeaderBytes { return .tooLarge }
        }
    }

    private func dialCandidates(_ addresses: [IPAddress], ifaceIndex: UInt32, deadline: Date) -> Int32? {
        for addr in addresses {
            if !isRunning() || Date() >= deadline { return nil }
            let fd = Darwin.socket(addr.family, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            configureSocketFlags(fd)

            guard bindInterface(fd, family: addr.family, ifaceIndex: ifaceIndex) else {
                Darwin.close(fd)
                continue
            }
            setNonBlocking(fd, enabled: true)

            let res = addr.connect(fd, port: UWConfig.httpsPort, ifaceIndex: ifaceIndex)
            if res == 0 {
                setNonBlocking(fd, enabled: false)
                registerFD(fd)
                return fd
            }
            if errno != EINPROGRESS {
                Darwin.close(fd)
                continue
            }

            var connected = false
            let attemptDeadline = min(deadline, Date().addingTimeInterval(3))
            while isRunning() {
                let remainingMs = Int32(max(0, attemptDeadline.timeIntervalSinceNow * 1000.0))
                if remainingMs <= 0 { break }
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let pr = Darwin.poll(&pfd, 1, remainingMs)
                if pr < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if pr == 0 { break }
                var soErr: Int32 = 0
                var errLen = socklen_t(MemoryLayout<Int32>.size)
                if getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &errLen) == 0 && soErr == 0 {
                    connected = true
                }
                break
            }

            if connected {
                setNonBlocking(fd, enabled: false)
                registerFD(fd)
                return fd
            }
            Darwin.close(fd)
        }
        return nil
    }

    private func bindInterface(_ fd: Int32, family: Int32, ifaceIndex: UInt32) -> Bool {
        var idx = ifaceIndex
        let level = family == AF_INET6 ? IPPROTO_IPV6 : IPPROTO_IP
        let option = family == AF_INET6 ? IPV6_BOUND_IF : IP_BOUND_IF
        return setsockopt(fd, level, option, &idx, socklen_t(MemoryLayout<UInt32>.size)) == 0
    }

    private func pump(fdA: Int32, fdB: Int32) {
        var aReadOpen = true
        var bReadOpen = true
        var buf = [UInt8](repeating: 0, count: ioBufferBytes)

        while isRunning() && (aReadOpen || bReadOpen) {
            var fds = [
                pollfd(fd: fdA, events: aReadOpen ? Int16(POLLIN) : 0, revents: 0),
                pollfd(fd: fdB, events: bReadOpen ? Int16(POLLIN) : 0, revents: 0)
            ]
            let ready = Darwin.poll(&fds, 2, 1000)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { continue }

            if aReadOpen && (fds[0].revents & Int16(POLLIN | POLLHUP | POLLERR)) != 0 {
                let n = Darwin.recv(fdA, &buf, buf.count, 0)
                if n > 0 {
                    if !sendAll(fdB, Data(buf[0..<n])) { break }
                } else if n == 0 || (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
                    aReadOpen = false
                    Darwin.shutdown(fdB, SHUT_WR)
                }
            }
            if bReadOpen && (fds[1].revents & Int16(POLLIN | POLLHUP | POLLERR)) != 0 {
                let n = Darwin.recv(fdB, &buf, buf.count, 0)
                if n > 0 {
                    if !sendAll(fdA, Data(buf[0..<n])) { break }
                } else if n == 0 || (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
                    bReadOpen = false
                    Darwin.shutdown(fdA, SHUT_WR)
                }
            }
            if (fds[0].revents & Int16(POLLNVAL)) != 0 || (fds[1].revents & Int16(POLLNVAL)) != 0 {
                break
            }
        }
    }

    @discardableResult
    private func sendAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < data.count {
                let n = Darwin.send(fd, base.advanced(by: sent), data.count - sent, 0)
                if n > 0 {
                    sent += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private func configureSocketFlags(_ fd: Int32) {
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFD, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
        }
    }

    private func setNonBlocking(_ fd: Int32, enabled: Bool) {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { return }
        let updated = enabled ? (flags | O_NONBLOCK) : (flags & ~O_NONBLOCK)
        _ = fcntl(fd, F_SETFL, updated)
    }

    private func setUDPTimers(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func currentNetworkSnapshot() -> NetworkSnapshot? {
        let now = Date().timeIntervalSince1970
        lock.lock()
        if let snap = cachedSnapshot, (now - snap.capturedAt) < pathCacheTTL {
            lock.unlock()
            return snap
        }
        lock.unlock()

        guard let store = SCDynamicStoreCreate(nil, "com.blueagle.uwvpn" as CFString, nil, nil) else {
            return nil
        }

        // Prefer primary interface if it is a physical en* interface; otherwise inspect all active services.
        var candidateIfaces: [(name: String, index: UInt32, dns: [String])] = []
        var primaryName: String?
        for family in ["IPv4", "IPv6"] {
            if let state = SCDynamicStoreCopyValue(store, "State:/Network/Global/\(family)" as CFString) as? [String: Any],
               let name = state["PrimaryInterface"] as? String, name.hasPrefix("en") {
                primaryName = name
                break
            }
        }

        let serviceOrder = ["IPv4", "IPv6"].flatMap { family -> [String] in
            let order = SCDynamicStoreCopyValue(store, "Setup:/Network/Global/\(family)" as CFString) as? [String: Any]
            return order?["ServiceOrder"] as? [String] ?? []
        }
        var seenServices = Set<String>()
        do {
            for serviceID in serviceOrder where seenServices.insert(serviceID).inserted {
                let ifName = ["IPv4", "IPv6"].compactMap { family -> String? in
                    let state = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(serviceID)/\(family)" as CFString) as? [String: Any]
                    return state?["InterfaceName"] as? String
                }.first { $0.hasPrefix("en") }
                guard let ifName else {
                    continue
                }
                let idx = if_nametoindex(ifName)
                guard idx != 0 else { continue }
                var dns: [String] = []
                if let dnsDict = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(serviceID)/DNS" as CFString) as? [String: Any],
                   let servers = dnsDict["ServerAddresses"] as? [String] {
                    dns = servers
                }
                candidateIfaces.append((ifName, idx, dns))
            }
        }

        let chosen: (name: String, index: UInt32, dns: [String])?
        if let pName = primaryName, pName.hasPrefix("en"),
           let match = candidateIfaces.first(where: { $0.name == pName }) {
            chosen = match
        } else if let first = candidateIfaces.first {
            chosen = first
        } else {
            chosen = fallbackActivePhysicalInterface()
        }

        guard let selected = chosen else { return nil }
        let snap = NetworkSnapshot(ifaceName: selected.name, ifaceIndex: selected.index, dnsServers: selected.dns, capturedAt: now)
        lock.lock()
        cachedSnapshot = snap
        lock.unlock()
        return snap
    }

    private func fallbackActivePhysicalInterface() -> (name: String, index: UInt32, dns: [String])? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(first) }
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let node = cur {
            let flags = Int32(node.pointee.ifa_flags)
            if (flags & IFF_UP) != 0, (flags & IFF_RUNNING) != 0,
               let namePtr = node.pointee.ifa_name,
               let sa = node.pointee.ifa_addr, [UInt8(AF_INET), UInt8(AF_INET6)].contains(sa.pointee.sa_family) {
                let name = String(cString: namePtr)
                if name.hasPrefix("en") {
                    let idx = if_nametoindex(name)
                    if idx != 0 { return (name, idx, []) }
                }
            }
            cur = node.pointee.ifa_next
        }
        return nil
    }

    private func resolveGateway(host: String, snapshot: NetworkSnapshot, deadline: Date) -> [IPAddress] {
        if let address = IPAddress(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) {
            return address.isUsable ? [address] : []
        }
        let now = Date().timeIntervalSince1970
        lock.lock()
        if let entry = dnsCache[host], entry.expiresAt > now, !entry.addresses.isEmpty {
            lock.unlock()
            return entry.addresses
        }
        lock.unlock()

        // Try physical-interface DHCP DNS first, then public DNS fallback on the bound physical NIC.
        var servers = Array(snapshot.dnsServers.prefix(3))
        for fallbackDNS in ["1.1.1.1", "2606:4700:4700::1111", "8.8.8.8"] where !servers.contains(fallbackDNS) {
            servers.append(fallbackDNS)
        }
        var directAddrs: [IPAddress] = []
        let lookupDeadline = min(deadline.addingTimeInterval(-3), Date().addingTimeInterval(5))
        for server in servers {
            let literal = server.split(separator: "%", maxSplits: 1).first.map(String.init) ?? ""
            guard let address = IPAddress(literal), address.isUsable else { continue }
            guard Date() < lookupDeadline else { break }
            let answers = DNSAnswers()
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                let type: UInt8 = index == 0 ? 1 : 28
                answers.store(self.resolveViaDirectDNS(host: host, ifaceIndex: snapshot.ifaceIndex, server: address, type: type), type: type)
            }
            directAddrs = answers.combined
            if !directAddrs.isEmpty || Date() >= lookupDeadline { break }
        }
        if !directAddrs.isEmpty {
            lock.lock()
            dnsCache[host] = CachedAddresses(addresses: directAddrs, expiresAt: now + dnsCacheTTL)
            lock.unlock()
            return directAddrs
        }

        var sysAddrs: [IPAddress] = []
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        if getaddrinfo(host, nil, &hints, &res) == 0, let first = res {
            defer { freeaddrinfo(first) }
            var cur: UnsafeMutablePointer<addrinfo>? = first
            while let node = cur {
                if let sa = node.pointee.ai_addr, [AF_INET, AF_INET6].contains(node.pointee.ai_family) {
                    let address = IPAddress(sa)
                    if address.isUsable { sysAddrs.append(address) }
                }
                cur = node.pointee.ai_next
            }
        }
        return sysAddrs
    }

    private func resolveViaDirectDNS(host: String, ifaceIndex: UInt32, server: IPAddress, type: UInt8) -> [IPAddress] {
        let txID = UInt16.random(in: 1...UInt16.max)
        var packet = Data([
            UInt8(txID >> 8), UInt8(txID & 0xFF),
            0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
        ])
        for label in host.split(separator: ".") {
            let bytes = Array(label.utf8)
            guard !bytes.isEmpty, bytes.count < 64 else { return [] }
            packet.append(UInt8(bytes.count))
            packet.append(contentsOf: bytes)
        }
        packet.append(contentsOf: [0x00, 0x00, type, 0x00, 0x01])

        do {
            let fd = Darwin.socket(server.family, SOCK_DGRAM, 0)
            guard fd >= 0 else { return [] }
            configureSocketFlags(fd)
            defer { Darwin.close(fd) }

            guard bindInterface(fd, family: server.family, ifaceIndex: ifaceIndex) else {
                return []
            }
            setUDPTimers(fd, seconds: dnsTimeoutSec)

            guard server.connect(fd, port: UWConfig.dnsPort, ifaceIndex: ifaceIndex) == 0 else { return [] }

            let sent = packet.withUnsafeBytes { raw in
                Darwin.send(fd, raw.baseAddress, packet.count, 0)
            }
            guard sent == packet.count else { return [] }

            var resp = [UInt8](repeating: 0, count: 1024)
            let n = Darwin.recv(fd, &resp, resp.count, 0)
            guard n >= 12 else { return [] }

            let respID = (UInt16(resp[0]) << 8) | UInt16(resp[1])
            let flags = (UInt16(resp[2]) << 8) | UInt16(resp[3])
            let isResponse = (flags & 0x8000) != 0
            let isTruncated = (flags & 0x0200) != 0
            let rcode = flags & 0x000F
            let qdcount = (Int(resp[4]) << 8) | Int(resp[5])
            let ancount = (Int(resp[6]) << 8) | Int(resp[7])
            guard respID == txID, isResponse, !isTruncated, rcode == 0, qdcount == 1 else { return [] }

            guard var pos = skipDNSName(resp, length: n, start: 12), pos + 4 <= n else { return [] }
            pos += 4 // QTYPE + QCLASS

            var results: [IPAddress] = []
            for _ in 0..<ancount {
                guard let afterName = skipDNSName(resp, length: n, start: pos),
                      afterName + 10 <= n else { break }
                let rtype = (UInt16(resp[afterName]) << 8) | UInt16(resp[afterName + 1])
                let rclass = (UInt16(resp[afterName + 2]) << 8) | UInt16(resp[afterName + 3])
                let rdlen = (Int(resp[afterName + 8]) << 8) | Int(resp[afterName + 9])
                let rdataStart = afterName + 10
                guard rdataStart + rdlen <= n else { break }
                let bytes = resp[rdataStart..<(rdataStart + rdlen)]
                if rtype == UInt16(type) && rclass == 1 {
                    let address: IPAddress?
                    if type == 1 && rdlen == 4 {
                        var value = in_addr()
                        withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: bytes) }
                        address = .v4(value)
                    } else if type == 28 && rdlen == 16 {
                        var value = in6_addr()
                        withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: bytes) }
                        address = .v6(value)
                    } else {
                        address = nil
                    }
                    if let address, address.isUsable { results.append(address) }
                }
                pos = rdataStart + rdlen
            }
            return results
        }
    }

    private func skipDNSName(_ packet: [UInt8], length: Int, start: Int) -> Int? {
        var pos = start
        var jumped = false
        var nextAfterFirstJump = 0
        var jumps = 0
        var visited: Set<Int> = []

        while pos < length {
            let lenByte = packet[pos]
            if lenByte == 0 {
                return jumped ? nextAfterFirstJump : (pos + 1)
            }
            if (lenByte & 0xC0) == 0xC0 {
                guard pos + 1 < length else { return nil }
                let offset = ((Int(lenByte & 0x3F)) << 8) | Int(packet[pos + 1])
                guard offset < pos, offset >= 12, !visited.contains(offset), jumps < 16 else { return nil }
                visited.insert(offset)
                if !jumped { nextAfterFirstJump = pos + 2 }
                jumped = true
                jumps += 1
                pos = offset
            } else if (lenByte & 0xC0) == 0 {
                let next = pos + 1 + Int(lenByte)
                guard next <= length else { return nil }
                pos = next
            } else {
                return nil
            }
        }
        return nil
    }

}

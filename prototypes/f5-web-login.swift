import AppKit
import Network
import WebKit

// Run as a foreground process. The session is delivered only to the child
// OpenConnect process over its stdin, never to the terminal or command line.
final class Login: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKHTTPCookieStoreObserver {
    let gateway: URL
    let executable: URL
    let proxyPort: NWEndpoint.Port?
    let ocproxyPath: String?
    let socksPort: UInt16
    let store = WKWebsiteDataStore.nonPersistent()
    var window: NSWindow!
    var webView: WKWebView!
    var completed = false
    var checking = false

    init(gateway: URL, executable: URL, proxyPort: NWEndpoint.Port?, ocproxyPath: String?, socksPort: UInt16) {
        self.gateway = gateway
        self.executable = executable
        self.proxyPort = proxyPort
        self.ocproxyPath = ocproxyPath
        self.socksPort = socksPort
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let proxyPort, #available(macOS 14.0, *) {
            let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: proxyPort)
            var proxy = ProxyConfiguration(httpCONNECTProxy: endpoint)
            proxy.matchDomains = [gateway.host!]
            store.proxyConfigurations = [proxy]
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        webView = WKWebView(frame: .zero, configuration: configuration)
        // Bypass UW's macOS-browser client block; UW's APM sends Linux browsers directly to SAML/Duo SSO.
        webView.customUserAgent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        webView.navigationDelegate = self
        store.httpCookieStore.add(self)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.title = "F5 Web Login — \(gateway.host!)"
        window.delegate = self
        window.contentView = webView
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        webView.load(URLRequest(url: gateway))
    }

    func windowWillClose(_ notification: Notification) {
        if !completed { fail("F5 Web Login was cancelled.") }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if url.scheme == "f5-vpn" {
            decisionHandler(.cancel)
            readSession()
        } else {
            decisionHandler(["https", "about"].contains(url.scheme) ? .allow : .cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let host = webView.url?.host {
            window.title = "F5 Web Login — \(host)"
            let path = webView.url?.path ?? ""
            FileHandle.standardError.write(Data("Loaded \(host)\(path)\n".utf8))
        }
        readSession()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        let failure = error as NSError
        if failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled { return }
        fail("F5 Web Login navigation failed (\(failure.domain), \(failure.code)).")
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        readSession()
    }

    func readSession() {
        guard !completed, !checking else { return }
        checking = true
        store.httpCookieStore.getAllCookies { [self] cookies in
            checking = false
            let now = Date()
            let host = gateway.host!.lowercased()
            let gatewayCookies = cookies.filter { cookie in
                [host, "." + host].contains(cookie.domain.lowercased()) && cookie.path == "/" &&
                    (cookie.expiresDate.map { $0 > now } ?? true)
            }
            guard let session = gatewayCookies.first(where: { $0.name == "MRHSession" }),
                  let timeout = gatewayCookies.first(where: { $0.name == "F5_ST" }),
                  [session.value, timeout.value].allSatisfy({
                      !$0.isEmpty && $0.utf8.allSatisfy { byte in
                          (0x21...0x7e).contains(byte) && byte != 0x3b
                      }
                  }) else { return }
            handOff("MRHSession=\(session.value); F5_ST=\(timeout.value)")
        }
    }

    func handOff(_ cookie: String) {
        guard !completed else { return }
        completed = true
        store.httpCookieStore.remove(self)

        let child = Process()
        let input = Pipe()
        child.executableURL = executable
        let tunScript = ocproxyPath.map { "\($0) -D \(socksPort) -k 15" } ?? "/usr/bin/true"
        var arguments = ["--protocol=f5", "--cookie-on-stdin", "--no-dtls",
                         "--useragent=Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                         "--script-tun", "--script=\(tunScript)"]
        if let proxyPort {
            arguments.append("--proxy=http://127.0.0.1:\(proxyPort.rawValue)")
        } else {
            arguments.append("--no-proxy")
        }
        child.arguments = arguments + [gateway.absoluteString]
        child.standardInput = input
        child.standardOutput = FileHandle.nullDevice
        child.terminationHandler = { process in exit(process.terminationStatus) }
        do {
            try child.run()
            try input.fileHandleForWriting.write(contentsOf: Data((cookie + "\n").utf8))
            try input.fileHandleForWriting.close()
            window.orderOut(nil)
            if ocproxyPath != nil {
                FileHandle.standardError.write(Data("Web login completed. OpenConnect + ocproxy listening on socks5://127.0.0.1:\(socksPort)\n".utf8))
            } else {
                FileHandle.standardError.write(Data("Web login completed. OpenConnect started.\n".utf8))
            }
        } catch {
            if child.isRunning { child.terminate() }
            fail("Could not start OpenConnect or deliver its login session.")
        }
    }

    func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}

let args = Array(CommandLine.arguments.dropFirst())
let proxyPort = args.count >= 3 && args[2] != "-" ? UInt16(args[2]).flatMap(NWEndpoint.Port.init(rawValue:)) : nil
let ocproxyPath = args.count >= 4 ? args[3] : nil
let socksPort = (args.count == 5 ? UInt16(args[4]) : nil) ?? 11080
let validOcproxy = ocproxyPath.map { $0.hasPrefix("/") && !$0.contains(" ") && FileManager.default.isExecutableFile(atPath: $0) } ?? true
guard (2...5).contains(args.count),
      args.count < 3 || args[2] == "-" || proxyPort != nil,
      validOcproxy,
      let gateway = URL(string: args[1]), gateway.scheme == "https", gateway.host != nil,
      gateway.user == nil, gateway.password == nil, gateway.query == nil, gateway.fragment == nil,
      args[0].hasPrefix("/"), FileManager.default.isExecutableFile(atPath: args[0]) else {
    FileHandle.standardError.write(Data("Usage: f5-web-login /path/to/openconnect https://vpn.example.edu/ [relay-port|-] [/path/to/ocproxy [socks-port]]\n".utf8))
    exit(2)
}

let app = NSApplication.shared
let login = Login(gateway: gateway, executable: URL(fileURLWithPath: args[0]), proxyPort: proxyPort, ocproxyPath: ocproxyPath, socksPort: socksPort)
app.setActivationPolicy(.regular)
app.delegate = login
app.run()

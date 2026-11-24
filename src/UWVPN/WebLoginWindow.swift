import AppKit
import Network
import WebKit

final class WebLoginController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKHTTPCookieStoreObserver {
    let gateway: UWGateway
    private let store: WKWebsiteDataStore
    private let relayPort: UInt16
    private let attemptID = UUID()
    private let onComplete: (StoredSession) -> Void
    private let onCancel: () -> Void

    private var window: NSWindow?
    private var webView: WKWebView?
    private var finished = false
    private var checking = false
    private var dirty = false

    init(gateway: UWGateway, relayPort: UInt16,
         onComplete: @escaping (StoredSession) -> Void,
         onCancel: @escaping () -> Void) {
        self.gateway = gateway
        self.relayPort = relayPort
        self.store = WKWebsiteDataStore(forIdentifier: gateway.webStoreUUID)
        self.onComplete = onComplete
        self.onCancel = onCancel
        super.init()
    }

    func show() {
        let port = NWEndpoint.Port(rawValue: relayPort)!
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(UWConfig.loopbackHost), port: port)
        var proxy = ProxyConfiguration(httpCONNECTProxy: endpoint)
        proxy.matchDomains = [gateway.gatewayHost]
        store.proxyConfigurations = [proxy]

        let expectedAttempt = attemptID
        store.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self, !self.finished, self.attemptID == expectedAttempt else { return }
            let group = DispatchGroup()
            for cookie in cookies where [self.gateway.gatewayHost, "." + self.gateway.gatewayHost].contains(cookie.domain.lowercased()) {
                group.enter()
                self.store.httpCookieStore.delete(cookie) { group.leave() }
            }
            group.notify(queue: .main) {
                guard !self.finished, self.attemptID == expectedAttempt else { return }
                self.presentWindow()
            }
        }
    }

    private func presentWindow() {
        guard !finished else { return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = UWConfig.linuxUserAgent
        view.navigationDelegate = self
        self.webView = view
        store.httpCookieStore.add(self)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "UWVPN Sign In — \(gateway.gatewayHost)"
        win.delegate = self
        win.contentView = view
        win.center()
        self.window = win

        NSApp.setActivationPolicy(.regular)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        view.load(URLRequest(url: gateway.gatewayURL))
    }

    func closeSilently() {
        finished = true
        store.httpCookieStore.remove(self)
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        window?.delegate = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
        webView = nil
        NSApp.setActivationPolicy(.accessory)
    }

    static func clearWebsiteData(for gateway: UWGateway, completion: (() -> Void)? = nil) {
        let store = WKWebsiteDataStore(forIdentifier: gateway.webStoreUUID)
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.removeData(ofTypes: types, modifiedSince: .distantPast) {
            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard !finished else { return }
        finished = true
        store.httpCookieStore.remove(self)
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        window = nil
        NSApp.setActivationPolicy(.accessory)
        onCancel()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if url.scheme == "f5-vpn" {
            decisionHandler(.cancel)
            checkCookies()
        } else {
            decisionHandler(["https", "about"].contains(url.scheme) ? .allow : .cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let host = webView.url?.host {
            window?.title = "UWVPN Sign In — \(host)"
        }
        checkCookies()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        presentRetryAlert(message: "The login web page renderer stopped unexpectedly.")
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        checkCookies()
    }

    private func handleNavigationError(_ error: Error) {
        guard !finished else { return }
        let nsErr = error as NSError
        if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled { return }
        presentRetryAlert(message: nsErr.localizedDescription)
    }

    private func presentRetryAlert(message: String) {
        guard !finished, let win = window else { return }
        let alert = NSAlert()
        alert.messageText = "Login Page Error"
        alert.informativeText = message
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: win) { [weak self] response in
            guard let self, !self.finished else { return }
            if response == .alertFirstButtonReturn {
                self.webView?.load(URLRequest(url: self.gateway.gatewayURL))
            } else {
                self.closeSilently()
                self.onCancel()
            }
        }
    }

    private func checkCookies() {
        guard !finished else { return }
        if checking {
            dirty = true
            return
        }
        checking = true
        dirty = false
        let expectedAttempt = attemptID

        store.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            self.checking = false
            guard !self.finished, self.attemptID == expectedAttempt else { return }

            let now = Date()
            let host = self.gateway.gatewayHost
            let gatewayCookies = cookies.filter { cookie in
                [host, "." + host].contains(cookie.domain.lowercased()) &&
                cookie.path == "/" &&
                (cookie.expiresDate.map { $0 > now } ?? true)
            }
            if let mrh = gatewayCookies.first(where: { $0.name == "MRHSession" }),
               let f5st = gatewayCookies.first(where: { $0.name == "F5_ST" }),
               StoredSession.isValidToken(mrh.value),
               StoredSession.isValidToken(f5st.value) {
                let candidate = StoredSession(
                    sessionID: mrh.value,
                    f5ST: f5st.value,
                    expiresAt: StoredSession.parseF5STExpiration(f5st.value),
                    savedAt: Date().timeIntervalSince1970
                )
                if candidate.isValidNow {
                    self.closeSilently()
                    self.onComplete(candidate)
                    return
                }
            }

            if self.dirty {
                self.checkCookies()
            }
        }
    }
}

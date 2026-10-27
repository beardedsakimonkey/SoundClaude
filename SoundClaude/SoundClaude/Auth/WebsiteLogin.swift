import AppKit
import SwiftUI
import WebKit

// Signs in on soundcloud.com and reads the website session token from its cookie.
@MainActor
final class WebsiteLogin: NSObject, ObservableObject, WKHTTPCookieStoreObserver,
                          WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    @Published var errorMessage: String?
    private let onToken: (String) -> Void
    private var finished = false
    private var popups: [NSWindow] = []
    private var pollTask: Task<Void, Never>?

    init(onToken: @escaping (String) -> Void) {
        self.onToken = onToken
        let configuration = WKWebViewConfiguration()
        // Only the extracted session token persists, in Keychain. Login cookies
        // never use Safari's store or the app's other browsing sessions.
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        configuration.websiteDataStore.httpCookieStore.add(self)
        webView.load(URLRequest(url: URL(string: "https://soundcloud.com/signin")!))
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.readCookies()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) { readCookies() }

    private func readCookies() {
        guard !finished else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self, !finished else { return }
            let token = cookies.first {
                $0.name == "oauth_token" && ["soundcloud.com", ".soundcloud.com"].contains($0.domain)
                    && !$0.value.isEmpty
            }?.value
            if let token {
                stop()
                onToken(token)
            }
        }
    }

    func stop() {
        finished = true
        pollTask?.cancel()
        pollTask = nil
        webView.configuration.websiteDataStore.httpCookieStore.remove(self)
        webView.stopLoading()
        for popup in popups { popup.close() }
        popups.removeAll()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { readCookies() }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        errorMessage = "The sign-in page could not load. Close this window and try again."
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Allow HTTPS identity-provider navigation, but never local files or app schemes.
        let scheme = navigationAction.request.url?.scheme
        decisionHandler(scheme == "https" || navigationAction.request.url?.absoluteString == "about:blank"
                        ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.request.url?.scheme == "https" ||
                navigationAction.request.url?.absoluteString == "about:blank" else { return nil }
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "SoundCloud sign-in"
        window.contentView = popup
        window.center()
        window.makeKeyAndOrderFront(nil)
        popups.append(window)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        popups.first { $0.contentView === webView }?.close()
        popups.removeAll { $0.contentView === webView }
    }
}

struct WebsiteLoginView: NSViewRepresentable {
    let login: WebsiteLogin
    func makeNSView(context: Context) -> WKWebView { login.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

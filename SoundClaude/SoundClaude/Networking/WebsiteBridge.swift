import AppKit
import WebKit

// Sends api-v2 writes as fetch() calls from a hidden soundcloud.com page. DataDome rejects
// writes made with URLSession, even with its cookie and the page's user agent, but passes
// requests made from the page where its script runs.
@MainActor
final class WebsiteBridge: NSObject, WKNavigationDelegate, WKScriptMessageHandler, NSWindowDelegate {
    private static let pageURL = URL(string: "https://soundcloud.com/discover")!
    private static let script = """
        const response = await fetch(url, {method, headers, body, redirect: 'error'});
        return {status: response.status, type: response.headers.get('Content-Type') ?? '', body: await response.text()};
        """
    // DataDome's script fires this once its captcha is solved.
    private static let passedScript = """
        addEventListener('dd_response_passed', () => webkit.messageHandlers.datadome.postMessage(true));
        """

    private var page: Task<WKWebView, Error>?
    private var window: NSWindow?
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var verifications: [CheckedContinuation<Bool, Never>] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw SoundCloudError.unexpectedURL }
        let webView = try await loadedPage()
        // Send only what soundcloud.com sends. DataDome blocks writes that carry the client's
        // `Accept: application/json; charset=utf-8`, and the page supplies the rest itself.
        var headers = ["Authorization": request.value(forHTTPHeaderField: "Authorization") ?? ""]
        if request.httpBody != nil {
            // The website sends JSON without a charset, and forms with jQuery's default type.
            let type = request.value(forHTTPHeaderField: "Content-Type") ?? ""
            headers["Content-Type"] = type.hasPrefix("application/json") ? "application/json" : type
        }
        let arguments: [String: Any] = [
            "url": url.absoluteString,
            "method": request.httpMethod ?? "GET",
            "headers": headers,
            "body": request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? NSNull(),
        ]
        var (data, response) = try await fetch(url, arguments, in: webView)
        // Some writes, such as comments, need a captcha. DataDome draws it over the page.
        if response.statusCode == 403, String(decoding: data, as: UTF8.self).contains("captcha-delivery.com"),
           await verify() {
            (data, response) = try await fetch(url, arguments, in: webView)
        }
        return (data, response)
    }

    private func fetch(
        _ url: URL, _ arguments: [String: Any], in webView: WKWebView
    ) async throws -> (Data, HTTPURLResponse) {
        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript(Self.script, arguments: arguments, contentWorld: .page)
        } catch {
            // The page may have crashed or navigated away; load a fresh one next time.
            reset()
            throw SoundCloudError.network
        }
        guard let result = result as? [String: Any], let status = result["status"] as? Int,
              let response = HTTPURLResponse(
                  url: url, statusCode: status, httpVersion: nil,
                  headerFields: ["Content-Type": result["type"] as? String ?? ""]
              ) else {
            throw SoundCloudError.invalidResponse
        }
        return (Data((result["body"] as? String ?? "").utf8), response)
    }

    /// Shows the page until its captcha passes (true) or the window closes (false).
    private func verify() async -> Bool {
        guard let window else { return false }
        if !window.isVisible {
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        return await withCheckedContinuation { verifications.append($0) }
    }

    private func finishVerification(passed: Bool) {
        window?.orderOut(nil)
        let waiting = verifications
        verifications = []
        for continuation in waiting { continuation.resume(returning: passed) }
    }

    private func loadedPage() async throws -> WKWebView {
        if let page { return try await page.value }
        let task = Task { try await load() }
        page = task
        do {
            return try await task.value
        } catch {
            reset()
            throw error
        }
    }

    private func load() async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.userContentController.add(self, contentWorld: .page, name: "datadome")
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.passedScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page
        ))
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 720), configuration: configuration)
        webView.navigationDelegate = self
        // Hidden unless a captcha needs solving.
        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: true)
        window.title = "SoundCloud verification"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = webView
        self.window = window

        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
            webView.load(URLRequest(url: Self.pageURL))
        }
        // DataDome's script sets its cookie shortly after the page loads.
        for _ in 0..<50 {
            let cookies = await configuration.websiteDataStore.httpCookieStore.allCookies()
            if cookies.contains(where: { $0.name == "datadome" }) { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        return webView
    }

    private func reset() {
        page = nil
        finishVerification(passed: false)
        (window?.contentView as? WKWebView)?.configuration.userContentController
            .removeScriptMessageHandler(forName: "datadome", contentWorld: .page)
        window?.contentView = nil
        window = nil
        finishLoad(throwing: SoundCloudError.network)
    }

    private func finishLoad(throwing error: Error? = nil) {
        guard let continuation = loadContinuation else { return }
        loadContinuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        finishVerification(passed: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Keep the page for later writes; closing only cancels the captcha.
        finishVerification(passed: false)
        return false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishLoad() }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoad(throwing: SoundCloudError.network)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        finishLoad(throwing: SoundCloudError.network)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { reset() }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Keep the page on soundcloud.com; frames may load other HTTPS content such as captchas.
        let url = navigationAction.request.url
        let allowed = navigationAction.targetFrame?.isMainFrame == true
            ? url?.scheme == "https" && url?.host == Self.pageURL.host
            : url?.scheme == "https" || url?.absoluteString == "about:blank"
        decisionHandler(allowed ? .allow : .cancel)
    }
}

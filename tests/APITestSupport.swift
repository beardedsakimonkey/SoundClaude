import Foundation

// api-v2 requests carry the website client ID, and user-scoped calls look up the signed-in
// user first. Test handlers see URLs without the client ID and never see /me.
enum APITestSupport {
    static let configuration = SoundCloudConfiguration(clientID: "test-client")
    static let userURN = "soundcloud:users:42"
    static let meJSON = #"{"id":42,"urn":"soundcloud:users:42","username":"Me","permalink_url":"https://soundcloud.com/me"}"#

    /// Returns the request as handlers see it, or the canned /me response.
    static func prepare(_ request: URLRequest) -> (request: URLRequest, me: (Int, String)?) {
        guard let url = request.url, url.host == "api-v2.soundcloud.com",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return (request, nil)
        }
        let items = components.queryItems ?? []
        precondition(items.filter { $0.name == "client_id" } == [URLQueryItem(name: "client_id", value: "test-client")])
        precondition(request.value(forHTTPHeaderField: "Origin") == "https://soundcloud.com")
        let remaining = items.filter { $0.name != "client_id" }
        components.queryItems = remaining.isEmpty ? nil : remaining
        var stripped = request
        stripped.url = components.url
        if components.path == "/me", request.httpMethod == "GET" {
            return (stripped, (200, meJSON))
        }
        return (stripped, nil)
    }
}

/// Answers every request with the current handler's status and JSON body.
final class APIStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> (Int, String))?

    static func respond(_ handler: @escaping (URLRequest) -> (Int, String)) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (request, me) = APITestSupport.prepare(self.request)
        Self.lock.lock()
        let handler = Self.handler!
        Self.lock.unlock()
        let (status, body) = me ?? handler(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

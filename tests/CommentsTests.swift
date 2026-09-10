import Foundation

@main
struct CommentsTests {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CommentsURLProtocol.self]
        let client = SoundCloudClient(
            configuration: SoundCloudConfiguration(clientID: "test", clientSecret: "test"),
            sessionConfiguration: configuration
        )
        let decoder = JSONDecoder()
        func comment(timestamp: String, date: String = "2007/09/11 15:40:24 +0000") -> String {
            """
            {"urn":"soundcloud:comments:1234","body":"Great track!\\nSecond line.",
             "created_at":"\(date)","timestamp":\(timestamp),
             "user":{"urn":"soundcloud:users:1","username":"Listener",
                     "permalink_url":"https://soundcloud.com/listener"}}
            """
        }
        for timestamp in ["4960", "\"4960\"", "4960.5", "\"4960.5\""] {
            let decoded = try decoder.decode(SoundCloudComment.self, from: Data(comment(timestamp: timestamp).utf8))
            precondition(decoded.id == "soundcloud:comments:1234")
            precondition(decoded.body == "Great track!\nSecond line.")
            precondition(decoded.user?.username == "Listener")
            precondition(decoded.timestampMilliseconds == 4960)
            precondition(decoded.createdAt != nil)
        }
        for timestamp in ["null", "-1", "\"\"", "\"NaN\"", "1e100"] {
            let decoded = try decoder.decode(SoundCloudComment.self, from: Data(comment(timestamp: timestamp).utf8))
            precondition(decoded.timestampMilliseconds == nil)
        }
        for date in ["2026-09-10T12:34:56Z", "2026-09-10T12:34:56.123Z"] {
            let decoded = try decoder.decode(SoundCloudComment.self, from: Data(comment(timestamp: "0", date: date).utf8))
            precondition(decoded.createdAt != nil)
            precondition(decoded.timestampMilliseconds == 0)
        }
        // Deleted or partial users must not hide their comments.
        for user in ["null", "{}"] {
            let decoded = try decoder.decode(SoundCloudComment.self, from: Data("""
                {"urn":"soundcloud:comments:2","body":"Still visible","user":\(user)}
                """.utf8))
            precondition(decoded.user == nil && decoded.createdAt == nil && decoded.timestampMilliseconds == nil)
        }

        let nextURL = URL(string: "https://api.soundcloud.com/tracks/soundcloud:tracks:1/comments?cursor=next")!
        CommentsURLProtocol.respond { request in
            precondition(request.httpMethod == "GET")
            precondition(request.url?.path == "/tracks/soundcloud:tracks:1/comments")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "OAuth test-token")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            precondition(query.contains(URLQueryItem(name: "limit", value: "50")))
            precondition(query.contains(URLQueryItem(name: "linked_partitioning", value: "true")))
            precondition(query.contains(URLQueryItem(name: "secret_token", value: "s-private")))
            return (200, """
                {"collection":[\(comment(timestamp: "4960"))],"next_href":"\(nextURL.absoluteString)"}
                """)
        }
        let page = try await client.trackComments(urn: "soundcloud:tracks:1", secretToken: "s-private", accessToken: "test-token")
        precondition(page.comments.count == 1 && page.nextURL == nextURL)
        CommentsURLProtocol.respond { request in
            precondition(request.url == nextURL)
            return (200, "{\"collection\":[],\"next_href\":null}")
        }
        let lastPage = try await client.trackComments(urn: "soundcloud:tracks:1", accessToken: "test-token", pageURL: nextURL)
        precondition(lastPage.comments.isEmpty && lastPage.nextURL == nil)

        for status in [401, 404, 429] {
            CommentsURLProtocol.respond { _ in (status, "{}") }
            do {
                _ = try await client.trackComments(urn: "soundcloud:tracks:1", accessToken: "test-token")
                fatalError("HTTP \(status) was accepted")
            } catch SoundCloudError.unauthorized { precondition(status == 401)
            } catch SoundCloudError.rateLimited { precondition(status == 429)
            } catch SoundCloudError.api { precondition(status == 404) }
        }
        for body in ["{}", "{\"collection\":[{}]}"] {
            CommentsURLProtocol.respond { _ in (200, body) }
            do {
                _ = try await client.trackComments(urn: "soundcloud:tracks:1", accessToken: "test-token")
                fatalError("Malformed comments were accepted")
            } catch is DecodingError {}
        }
        CommentsURLProtocol.respond { _ in fatalError("Untrusted URL was requested") }
        do {
            _ = try await client.trackComments(urn: "soundcloud:tracks:1", accessToken: "test-token",
                pageURL: URL(string: "https://example.com/comments")!)
            fatalError("Untrusted page URL was accepted")
        } catch SoundCloudError.unexpectedURL {}
        for href in ["https://example.com/comments", "http://api.soundcloud.com/comments"] {
            CommentsURLProtocol.respond { _ in (200, "{\"collection\":[],\"next_href\":\"\(href)\"}") }
            do {
                _ = try await client.trackComments(urn: "soundcloud:tracks:1", accessToken: "test-token")
                fatalError("Untrusted next URL was accepted")
            } catch SoundCloudError.unexpectedURL {}
        }
        CommentsURLProtocol.respond { request in
            (200, "{\"collection\":[],\"next_href\":\"\(request.url!.absoluteString)\"}")
        }
        do {
            _ = try await client.trackComments(urn: "soundcloud:tracks:1", accessToken: "test-token")
            fatalError("Repeated page URL was accepted")
        } catch SoundCloudError.invalidData {}
        print("Comment decoding and API checks passed")
    }
}

private final class CommentsURLProtocol: URLProtocol {
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
        Self.lock.lock()
        let handler = Self.handler!
        Self.lock.unlock()
        let (status, body) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

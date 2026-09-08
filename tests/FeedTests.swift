import Foundation

@main
struct FeedTests {
    static func main() async throws {
        let track = """
            {"urn":"soundcloud:tracks:1","title":"Track","access":"playable",
             "created_at":"2020/01/01 00:00:00 +0000",
             "permalink_url":"https://soundcloud.com/artist/track",
             "user":{"urn":"soundcloud:users:1","username":"Artist",
             "permalink_url":"https://soundcloud.com/artist"}}
            """
        func activity(_ type: String, date: String = "2026-09-08T12:00:00Z", origin: String? = nil) -> String {
            """
            {"type":"\(type)","created_at":"\(date)",
             "reposter":"soundcloud:users:2","origin":\(origin ?? track)}
            """
        }
        let decoder = JSONDecoder()
        for date in ["2026-09-08T12:00:00Z", "2026-09-08T12:00:00.000Z", "2026/09/08 12:00:00 +0000"] {
            let decoded = try decoder.decode(RawFeedActivity.self, from: Data(activity("track", date: date).utf8))
            precondition(decoded.createdAt == ISO8601DateFormatter().date(from: "2026-09-08T12:00:00Z"))
            precondition(decoded.track?.urn == "soundcloud:tracks:1")
        }
        for type in ["playlist", "playlist:repost", "unknown"] {
            let decoded = try decoder.decode(RawFeedActivity.self, from: Data(activity(type, origin: "{}").utf8))
            precondition(decoded.track == nil)
        }
        for json in ["{}", "{\"collection\":[123]}", activity("track", date: "invalid")] {
            do {
                if json.contains("created_at") {
                    _ = try decoder.decode(RawFeedActivity.self, from: Data(json.utf8))
                } else {
                    _ = try decoder.decode(RawFeedPage.self, from: Data(json.utf8))
                }
                fatalError("Invalid feed data was accepted")
            } catch is DecodingError {}
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedURLProtocol.self]
        let client = SoundCloudClient(
            configuration: SoundCloudConfiguration(clientID: "test", clientSecret: "test"),
            sessionConfiguration: configuration
        )
        let nextURL = "https://api.soundcloud.com/me/feed?cursor=next"
        let blocked = track.replacingOccurrences(of: "playable", with: "blocked")
        let preview = track.replacingOccurrences(of: "playable", with: "preview")
        FeedURLProtocol.respond { request in
            precondition(request.value(forHTTPHeaderField: "Authorization") == "OAuth test-token")
            if request.url?.path == "/users/soundcloud:users:2" {
                return (200, """
                    {"urn":"soundcloud:users:2","username":"Reposter",
                     "avatar_url":"https://i1.sndcdn.com/reposter.jpg",
                     "permalink_url":"https://soundcloud.com/reposter"}
                    """)
            }
            precondition(request.url?.path == "/me/feed")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            precondition(query.contains(URLQueryItem(name: "access", value: "playable,preview")))
            return (200, """
                {"collection":[\(activity("track")),\(activity("playlist", origin: "{}")),
                 \(activity("track:repost")),\(activity("track:repost", date: "2026-09-07T12:00:00Z")),
                 \(activity("track", origin: blocked)),\(activity("track", origin: preview))],
                 "next_href":"\(nextURL)"}
                """)
        }
        let page = try await client.feed(accessToken: "test-token")
        precondition(page.items.count == 4)
        precondition(page.items[0].user.username == "Artist" && !page.items[0].isRepost)
        precondition(page.items[1].user.username == "Reposter" && page.items[1].isRepost)
        precondition(page.items[1].user.avatarURL?.absoluteString == "https://i1.sndcdn.com/reposter.jpg")
        precondition(page.items[1].track.artist.username == "Artist")
        precondition(Set(page.items.prefix(3).map(\.id)).count == 3)
        precondition(page.items.last?.track.access == .preview)
        precondition(page.nextURL?.absoluteString == nextURL)
        precondition(FeedURLProtocol.paths.filter { $0 == "/users/soundcloud:users:2" }.count == 1)

        FeedURLProtocol.respond { request in
            precondition(request.url?.absoluteString == nextURL)
            return (200, """
                {"collection":[\(activity("playlist:repost", origin: "{}"))],
                 "next_href":"https://api.soundcloud.com/me/feed?cursor=last"}
                """)
        }
        let emptyPage = try await client.feed(accessToken: "test-token", pageURL: page.nextURL)
        precondition(emptyPage.items.isEmpty && emptyPage.nextURL != nil)
        var queue = TrackQueue(source: .feed, tracks: page.items.map(\.track), nextPageURL: page.nextURL)
        try queue.append(SoundCloudTrackPage(tracks: [], nextURL: emptyPage.nextURL))
        precondition(queue.needsNextPage(after: queue.tracks.last?.urn))
        let restored = try decoder.decode(TrackQueue.self, from: JSONEncoder().encode(queue))
        precondition(restored.source == .feed && restored.nextPageURL == emptyPage.nextURL)

        FeedURLProtocol.respond { _ in (200, "{\"collection\":[],\"next_href\":null}") }
        let last = try await client.feed(accessToken: "test-token", pageURL: emptyPage.nextURL)
        precondition(last.items.isEmpty && last.nextURL == nil)
        FeedURLProtocol.respond { _ in
            (200, "{\"collection\":[],\"next_href\":\"https://example.com/feed\"}")
        }
        do {
            _ = try await client.feed(accessToken: "test-token")
            fatalError("Untrusted pagination URL was accepted")
        } catch SoundCloudError.unexpectedURL {}
        FeedURLProtocol.respond { request in
            (200, "{\"collection\":[],\"next_href\":\"\(request.url!.absoluteString)\"}")
        }
        do {
            _ = try await client.feed(accessToken: "test-token")
            fatalError("Repeated pagination URL was accepted")
        } catch SoundCloudError.invalidData {}
        FeedURLProtocol.respond { _ in (401, "{}") }
        do {
            _ = try await client.feed(accessToken: "test-token")
            fatalError("Unauthorized response was accepted")
        } catch SoundCloudError.unauthorized {}
        print("Feed decoding, attribution, pagination, and queue checks passed")
    }
}

private final class FeedURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> (Int, String))?
    private static var requestedPaths: [String] = []

    static var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requestedPaths
    }

    static func respond(_ handler: @escaping (URLRequest) -> (Int, String)) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
        requestedPaths = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler!
        Self.requestedPaths.append(request.url!.path)
        Self.lock.unlock()
        let (status, body) = handler(request)
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

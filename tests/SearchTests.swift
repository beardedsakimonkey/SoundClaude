import Foundation

@main
struct SearchTests {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SearchURLProtocol.self]
        let client = SoundCloudClient(
            configuration: SoundCloudConfiguration(clientID: "test", clientSecret: "test"),
            sessionConfiguration: configuration
        )
        let query = "ambient & jazz + café/夜?"
        let user = """
        {"urn":"soundcloud:users:1","username":"Artist",
         "permalink_url":"https://soundcloud.com/artist","followers_count":12}
        """
        func track(_ id: Int, access: String = "playable") -> String {
            """
            {"urn":"soundcloud:tracks:\(id)","title":"Track \(id)",
             "permalink_url":"https://soundcloud.com/artist/track-\(id)",
             "duration":120000,"access":"\(access)","user":\(user)}
            """
        }
        let playlist = """
        {"urn":"soundcloud:playlists:1","title":"Mix","track_count":3,
         "permalink_url":"https://soundcloud.com/artist/sets/mix","user":\(user)}
        """

        for endpoint in ["tracks", "playlists", "users"] {
            let nextURL = URL(string: "https://api.soundcloud.com/\(endpoint)?cursor=next&q=ambient")!
            let collection: String
            switch endpoint {
            case "tracks": collection = "[\(track(1)),\(track(2, access: "blocked")),\(track(3, access: "preview"))]"
            case "playlists": collection = "[\(playlist)]"
            default: collection = "[\(user)]"
            }
            SearchURLProtocol.respond { request in
                precondition(request.httpMethod == "GET")
                precondition(request.url?.path == "/\(endpoint)")
                precondition(request.value(forHTTPHeaderField: "Authorization") == "OAuth test-token")
                let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                let parameters = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
                precondition(parameters["q"] == query, "Search text must survive URL encoding")
                precondition(parameters["linked_partitioning"] == "true")
                precondition(parameters["limit"] == "25")
                if endpoint == "tracks" { precondition(parameters["access"] == "playable,preview") }
                if endpoint == "playlists" { precondition(parameters["show_tracks"] == "false") }
                return (200, "{\"collection\":\(collection),\"next_href\":\"\(nextURL)\"}")
            }
            switch endpoint {
            case "tracks":
                let page = try await client.searchTracks(query: query, accessToken: "test-token")
                precondition(page.tracks.map(\.urn) == ["soundcloud:tracks:1", "soundcloud:tracks:3"])
                precondition(page.nextURL == nextURL)
                var queue = TrackQueue(source: .search(query), tracks: page.tracks, nextPageURL: page.nextURL)
                precondition(queue.needsNextPage(after: page.tracks.last?.urn))
                let restored = try JSONDecoder().decode(TrackQueue.self, from: JSONEncoder().encode(queue))
                precondition(restored.source == .search(query) && restored.nextPageURL == nextURL)
                try queue.append(SoundCloudTrackPage(tracks: page.tracks, nextURL: nil))
                precondition(queue.tracks.count == 2 && queue.nextPageURL == nil)
            case "playlists":
                let page = try await client.searchPlaylists(query: query, accessToken: "test-token")
                precondition(page.playlists.first?.title == "Mix" && page.nextURL == nextURL)
            default:
                let page = try await client.searchUsers(query: query, accessToken: "test-token")
                precondition(page.users.first?.followersCount == 12 && page.nextURL == nextURL)
            }

            func fetch(_ url: URL? = nil) async throws -> URL? {
                switch endpoint {
                case "tracks": return try await client.searchTracks(query: query, accessToken: "test-token", pageURL: url).nextURL
                case "playlists": return try await client.searchPlaylists(query: query, accessToken: "test-token", pageURL: url).nextURL
                default: return try await client.searchUsers(query: query, accessToken: "test-token", pageURL: url).nextURL
                }
            }
            SearchURLProtocol.respond { request in
                precondition(request.url == nextURL, "Continuation must be used without rewriting it")
                return (200, "{\"collection\":[],\"next_href\":null}")
            }
            let end = try await fetch(nextURL)
            precondition(end == nil)

            SearchURLProtocol.respond { _ in (429, "{}") }
            do {
                _ = try await fetch()
                fatalError("Rate limit was accepted")
            } catch SoundCloudError.rateLimited {}

            SearchURLProtocol.respond { _ in (401, "{}") }
            do {
                _ = try await fetch()
                fatalError("Unauthorized request was accepted")
            } catch SoundCloudError.unauthorized {}

            SearchURLProtocol.respond { _ in (200, "{}") }
            do {
                _ = try await fetch()
                fatalError("Malformed response was accepted as empty search results")
            } catch is DecodingError {}

            SearchURLProtocol.respond { request in
                (200, "{\"collection\":[],\"next_href\":\"\(request.url!)\"}")
            }
            do {
                _ = try await fetch(nextURL)
                fatalError("Repeated continuation was accepted")
            } catch SoundCloudError.invalidData {}

            SearchURLProtocol.respond { _ in
                (200, "{\"collection\":[],\"next_href\":\"https://example.com/page\"}")
            }
            do {
                _ = try await fetch()
                fatalError("External continuation was accepted")
            } catch SoundCloudError.unexpectedURL {}

            SearchURLProtocol.respond { _ in fatalError("Token must not be sent to another host") }
            do {
                _ = try await fetch(URL(string: "https://example.com/page")!)
                fatalError("External page URL was accepted")
            } catch SoundCloudError.unexpectedURL {}
        }
        print("Search API, pagination, and queue checks passed")
    }
}

private final class SearchURLProtocol: URLProtocol {
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

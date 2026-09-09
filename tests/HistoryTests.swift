import Foundation

@main
struct HistoryTests {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HistoryURLProtocol.self]
        let client = SoundCloudClient(
            configuration: SoundCloudConfiguration(clientID: "test", clientSecret: "test"),
            sessionConfiguration: configuration
        )
        func track(_ id: Int, access: String = "playable") -> String {
            """
            {"urn":"soundcloud:tracks:\(id)","title":"Track \(id)",
             "permalink_url":"https://soundcloud.com/artist/track-\(id)",
             "duration":120000,"access":"\(access)",
             "user":{"username":"Artist","permalink_url":"https://soundcloud.com/artist"}}
            """
        }
        let collection = "[\(track(3)),\(track(2, access: "blocked")),\(track(1, access: "preview"))]"
        // The spec allows both a plain array and a collection response.
        for body in [collection, "{\"collection\":\(collection),\"next_href\":null}"] {
            HistoryURLProtocol.respond { request in
                precondition(request.httpMethod == "GET")
                precondition(request.url?.host == "api.soundcloud.com")
                precondition(request.url?.path == "/me/recently-played/tracks")
                precondition(request.value(forHTTPHeaderField: "Authorization") == "OAuth test-token")
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                precondition(query == [URLQueryItem(name: "access", value: "playable,preview")])
                return (200, body)
            }
            let tracks = try await client.recentlyPlayedTracks(accessToken: "test-token")
            precondition(tracks.map(\.urn) == ["soundcloud:tracks:3", "soundcloud:tracks:1"])
            precondition(tracks.last?.access == .preview)

            let queue = TrackQueue(source: .history, tracks: tracks)
            precondition(!queue.needsNextPage(after: tracks.last?.urn))
            precondition(queue.relativeTrack(to: tracks.first?.urn, offset: 1) == tracks.last)
            precondition(queue.relativeTrack(to: tracks.last?.urn, offset: -1) == tracks.first)
            let restored = try JSONDecoder().decode(TrackQueue.self, from: JSONEncoder().encode(queue))
            precondition(restored.source == .history && restored.tracks == tracks)
            precondition(restored.nextPageURL == nil)
        }

        HistoryURLProtocol.respond { _ in (200, "[]") }
        let empty = try await client.recentlyPlayedTracks(accessToken: "test-token")
        precondition(empty.isEmpty)
        HistoryURLProtocol.respond { _ in (401, "{}") }
        do {
            _ = try await client.recentlyPlayedTracks(accessToken: "test-token")
            fatalError("Unauthorized response was accepted")
        } catch SoundCloudError.unauthorized {}
        HistoryURLProtocol.respond { _ in (429, "{}") }
        do {
            _ = try await client.recentlyPlayedTracks(accessToken: "test-token")
            fatalError("Rate limit was accepted as empty history")
        } catch SoundCloudError.rateLimited {}
        HistoryURLProtocol.respond { _ in (200, "{}") }
        do {
            _ = try await client.recentlyPlayedTracks(accessToken: "test-token")
            fatalError("Malformed response was accepted as empty history")
        } catch is DecodingError {}
        print("History API and queue checks passed")
    }
}

private final class HistoryURLProtocol: URLProtocol {
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

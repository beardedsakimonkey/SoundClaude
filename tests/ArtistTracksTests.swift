import Foundation

@main
struct ArtistTracksTests {
    @MainActor
    static func main() async throws {
        try await sortedPages()
        try await rejectsPageCycles()
        try await limitsEmptyPages()
        await skipsDuplicatePages()
        await retriesFailedPages()
        await rejectsStateCycles()
        await limitsDuplicatePages()
        await sharesRequestsAcrossCancellation()
        await ignoresCancelledLoads()
        print("Artist track pagination tests passed")
    }

    private static func client() -> SoundCloudClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtistTracksURLProtocol.self]
        return SoundCloudClient(
            configuration: APITestSupport.configuration, sessionConfiguration: configuration
        )
    }

    private static func pageURL(_ cursor: Int, path: String = "tracks") -> URL {
        URL(string: "https://api-v2.soundcloud.com/users/1/\(path)?cursor=\(cursor)")!
    }

    private static func track(_ id: Int) -> SoundCloudTrack {
        SoundCloudTrack(
            urn: "soundcloud:tracks:\(id)", title: "Track \(id)",
            artist: SoundCloudUser(
                urn: "soundcloud:users:1", username: "Artist", avatarURL: nil,
                permalinkURL: URL(string: "https://soundcloud.com/artist")!
            ),
            artworkURL: nil, waveformURL: nil,
            permalinkURL: URL(string: "https://soundcloud.com/artist/\(id)")!,
            durationMilliseconds: 1000, access: .playable, secretToken: nil
        )
    }

    private static func page(_ ids: [Int], next: Int? = nil) -> SoundCloudTrackPage {
        SoundCloudTrackPage(tracks: ids.map(track), nextURL: next.map { pageURL($0) })
    }

    private static func json(_ ids: [Int], next: URL? = nil) -> String {
        let tracks = ids.map { id in
            """
            {"id":\(id),"title":"Track \(id)","policy":"ALLOW",
             "permalink_url":"https://soundcloud.com/artist/\(id)",
             "user":{"id":1,"username":"Artist","permalink_url":"https://soundcloud.com/artist"}}
            """
        }.joined(separator: ",")
        let nextValue = next.map { "\"\($0.absoluteString)\"" } ?? "null"
        return "{\"collection\":[\(tracks)],\"next_href\":\(nextValue)}"
    }

    private static func sortedPages() async throws {
        for sortOrder in ArtistTrackSortOrder.allCases {
            let path = sortOrder == .top ? "toptracks" : "tracks"
            let client = client()
            ArtistTracksURLProtocol.respond { request in
                precondition(request.httpMethod == "GET")
                precondition(request.value(forHTTPHeaderField: "Authorization") == "OAuth test-token")
                precondition(request.url?.path == "/users/1/\(path)")
                switch request.url?.query {
                case "limit=25&linked_partitioning=1":
                    // A filtered page and an empty page precede the first visible track.
                    return (200, """
                        {"collection":[{"id":99}],"next_href":"\(pageURL(1, path: path))"}
                        """)
                case "cursor=1": return (200, json([], next: pageURL(2, path: path)))
                case "cursor=2": return (200, json([1], next: pageURL(3, path: path)))
                case "cursor=3": return (200, json([], next: pageURL(4, path: path)))
                case "cursor=4": return (200, json([2]))
                default: preconditionFailure("Unexpected request: \(request.url!)")
                }
            }
            let first = try await client.artistTracks(
                urn: "soundcloud:users:1", accessToken: "test-token", sortOrder: sortOrder
            )
            precondition(first.tracks.map(\.urn) == [track(1).urn])
            precondition(first.nextURL == pageURL(3, path: path))
            // Playback uses the cursor with the default sort. A top-track cursor
            // must keep its endpoint, and skip empty later pages too.
            let last = try await client.artistTracks(
                urn: "soundcloud:users:1", accessToken: "test-token", pageURL: first.nextURL
            )
            precondition(last.tracks.map(\.urn) == [track(2).urn] && last.nextURL == nil)
        }
        ArtistTracksURLProtocol.respond { _ in (200, json([])) }
        let empty = try await client().artistTracks(urn: "soundcloud:users:1", accessToken: "test-token")
        precondition(empty.tracks.isEmpty && empty.nextURL == nil)
    }

    private static func rejectsPageCycles() async throws {
        for finalTracks in [[], [1]] {
            ArtistTracksURLProtocol.respond { request in
                let next = request.url == pageURL(1) ? pageURL(2) : pageURL(1)
                return (200, json(request.url == pageURL(2) ? finalTracks : [], next: next))
            }
            do {
                _ = try await client().artistTracks(
                    urn: "soundcloud:users:1", accessToken: "test-token", pageURL: pageURL(1)
                )
                preconditionFailure("A pagination cycle was accepted")
            } catch SoundCloudError.invalidData {}
        }
        ArtistTracksURLProtocol.respond { _ in (200, json([], next: URL(string: "https://example.com/page")!)) }
        do {
            _ = try await client().artistTracks(urn: "soundcloud:users:1", accessToken: "test-token")
            preconditionFailure("An untrusted cursor was accepted")
        } catch SoundCloudError.unexpectedURL {}
    }

    private static func limitsEmptyPages() async throws {
        var requests = 0
        ArtistTracksURLProtocol.respond { _ in
            requests += 1
            return (200, json([], next: pageURL(requests)))
        }
        do {
            _ = try await client().artistTracks(urn: "soundcloud:users:1", accessToken: "test-token")
            preconditionFailure("Empty pages did not stop")
        } catch SoundCloudError.api {
            precondition(requests == 20)
        }
    }

    @MainActor
    private static func skipsDuplicatePages() async {
        let state = ArtistTrackPageState()
        state.seed(with: page([1, 1], next: 1))
        precondition(state.tracks.map(\.urn) == [track(1).urn])
        var requests: [URL?] = []
        await state.loadNextPage { url in
            requests.append(url)
            switch url {
            case pageURL(1): return page([1], next: 2)
            case pageURL(2): return page([], next: 3)
            case pageURL(3): return page([1, 2, 2])
            default: preconditionFailure("Unexpected cursor")
            }
        }
        precondition(requests == [pageURL(1), pageURL(2), pageURL(3)])
        precondition(state.tracks.map(\.urn) == [track(1).urn, track(2).urn])
        precondition(state.hasLoaded && !state.isLoading && state.errorMessage == nil)
        precondition(state.nextPageURL == nil && !state.showsLoadingIndicator)
        await state.loadNextPage { _ in preconditionFailure("Loaded past the last page") }

        let empty = ArtistTrackPageState()
        precondition(empty.needsFirstTracks && empty.showsLoadingIndicator)
        await empty.loadNextPage { _ in page([]) }
        precondition(!empty.mayHaveTracks && !empty.needsFirstTracks && !empty.showsLoadingIndicator)
    }

    @MainActor
    private static func retriesFailedPages() async {
        for seeded in [false, true] {
            let state = ArtistTrackPageState()
            if seeded { state.seed(with: page([1], next: 1)) }
            let cursor = state.nextPageURL
            await state.loadNextPage { url in
                precondition(url == cursor)
                throw SoundCloudError.network
            }
            precondition(state.errorMessage != nil && !state.isLoading && !state.showsLoadingIndicator)
            precondition(state.nextPageURL == cursor && state.hasLoaded == seeded)
            await state.loadNextPage { url in
                precondition(url == cursor)
                return page([2])
            }
            precondition(state.tracks.map(\.urn) == (seeded ? [track(1).urn, track(2).urn] : [track(2).urn]))
            precondition(state.errorMessage == nil && !state.isLoading)
        }
    }

    @MainActor
    private static func rejectsStateCycles() async {
        let state = ArtistTrackPageState()
        state.seed(with: page([1], next: 1))
        await state.loadNextPage { _ in page([2], next: 2) }
        await state.loadNextPage { _ in page([3], next: 1) }
        precondition(state.errorMessage == SoundCloudError.invalidData.localizedDescription)
        precondition(state.nextPageURL == pageURL(2))
        precondition(state.tracks.map(\.urn) == [track(1).urn, track(2).urn])
    }

    @MainActor
    private static func limitsDuplicatePages() async {
        let state = ArtistTrackPageState()
        state.seed(with: page([1], next: 1))
        var requests = 0
        await state.loadNextPage { _ in
            requests += 1
            return page([1], next: requests + 1)
        }
        precondition(requests == 20 && state.errorMessage != nil && !state.isLoading)
        // Retry continues from the advanced cursor instead of repeating those pages.
        await state.loadNextPage { url in
            precondition(url == pageURL(21))
            return page([2])
        }
        precondition(state.tracks.map(\.urn) == [track(1).urn, track(2).urn])
        precondition(state.errorMessage == nil)
    }

    @MainActor
    private static func sharesRequestsAcrossCancellation() async {
        let recent = ArtistTrackPageState()
        let top = ArtistTrackPageState()
        let gate = PageGate()
        let first = Task { await recent.loadNextPage { _ in await gate.fetch() } }
        await gate.waitForFetch()
        precondition(recent.isLoading && recent.showsLoadingIndicator)
        first.cancel()
        var joined: Task<Void, Never>?
        await withCheckedContinuation { started in
            joined = Task {
                started.resume()
                await recent.loadNextPage { _ in preconditionFailure("A shared request was duplicated") }
            }
        }
        // Switching sort can load independently while the cancelled footer's request finishes.
        await top.loadNextPage { _ in page([9]) }
        precondition(top.tracks.map(\.urn) == [track(9).urn] && recent.tracks.isEmpty)
        gate.release(page([1]))
        await first.value
        await joined?.value
        precondition(recent.tracks.map(\.urn) == [track(1).urn])
        precondition(!recent.isLoading && recent.errorMessage == nil)
    }

    @MainActor
    private static func ignoresCancelledLoads() async {
        let state = ArtistTrackPageState()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await state.loadNextPage { _ in preconditionFailure("A cancelled caller started a request") }
        }
        await task.value
        precondition(!state.hasLoaded && !state.isLoading && state.errorMessage == nil)
    }
}

@MainActor
private final class PageGate {
    private var completion: CheckedContinuation<SoundCloudTrackPage, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func fetch() async -> SoundCloudTrackPage {
        await withCheckedContinuation {
            completion = $0
            started?.resume()
            started = nil
        }
    }

    func waitForFetch() async {
        if completion != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func release(_ page: SoundCloudTrackPage) {
        completion!.resume(returning: page)
        completion = nil
    }
}

private final class ArtistTracksURLProtocol: URLProtocol {
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
        let (request, me) = APITestSupport.prepare(self.request)
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

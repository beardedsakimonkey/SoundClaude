import Foundation

@main
struct PlaylistTests {
    static func main() async throws {
        let decoder = JSONDecoder()
        let playlist = """
            {"urn":"soundcloud:playlists:42","title":"My playlist",
             "permalink_url":"https://soundcloud.com/owner/sets/my-playlist",
             "artwork_url":"","description":null,"track_count":0,
             "duration":0,"sharing":"private",
             "user":{"username":"Owner","permalink_url":"https://soundcloud.com/owner"}}
            """
        let nextURL = "https://api.soundcloud.com/me/playlists?cursor=next"
        for (json, count, next) in [
            ("[\(playlist)]", 1, nil),
            ("[]", 0, nil),
            ("{\"collection\":[\(playlist)],\"next_href\":\"\(nextURL)\"}", 1, nextURL),
            ("{\"collection\":[],\"next_href\":null}", 0, nil),
            ("{\"collection\":[]}", 0, nil),
        ] {
            let page = try decoder.decode(RawPlaylistPage.self, from: Data(json.utf8))
            precondition(page.collection.compactMap { $0.normalized() }.count == count)
            precondition(page.nextURL?.absoluteString == next)
        }
        for artwork in ["\"\"", "null", "\"https://i1.sndcdn.com/art-large.jpg\""] {
            let json = playlist.replacingOccurrences(of: "\"artwork_url\":\"\"", with: "\"artwork_url\":\(artwork)")
            let normalized = try decoder.decode(RawPlaylist.self, from: Data(json.utf8)).normalized()!
            precondition(normalized.isPrivate)
            precondition(normalized.trackCount == 0)
            precondition(normalized.description == nil)
            precondition(normalized.owner.username == "Owner")
            precondition((normalized.artworkURL != nil) == artwork.contains("https:"))
        }
        for json in ["{}", "[123]", "{\"collection\":[123]}", "{\"collection\":{}}"] {
            do {
                _ = try decoder.decode(RawPlaylistPage.self, from: Data(json.utf8))
                fatalError("Malformed playlist page was accepted")
            } catch is DecodingError {}
        }
        let partial = try decoder.decode(RawPlaylist.self, from: Data("{\"title\":\"Missing identity\"}".utf8))
        precondition(partial.normalized() == nil)

        for timestamp in ["null", "\"2017/04/10 14:48:03 +0000\"", "\"2026-09-11T12:30:00Z\""] {
            let json = playlist.replacingOccurrences(
                of: "\"duration\":0", with: "\"duration\":0,\"last_modified\":\(timestamp)"
            )
            let normalized = try decoder.decode(RawPlaylist.self, from: Data(json.utf8)).normalized()!
            let expected = try decoder.decode(String?.self, from: Data(timestamp.utf8))
            precondition(normalized.lastModified == expected)
            let cached = try decoder.decode(SoundCloudPlaylist.self, from: JSONEncoder().encode(normalized))
            precondition(cached.lastModified == expected)
        }
        let undated = try decoder.decode(RawPlaylist.self, from: Data(playlist.utf8)).normalized()!
        precondition(undated.lastModified == nil)
        let legacyCache = try JSONEncoder().encode(undated)
        let cachedUndated = try decoder.decode(SoundCloudPlaylist.self, from: legacyCache)
        precondition(cachedUndated.lastModified == nil)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaylistURLProtocol.self]
        let client = SoundCloudClient(
            configuration: SoundCloudConfiguration(clientID: "test", clientSecret: "test"),
            sessionConfiguration: configuration
        )
        PlaylistURLProtocol.respond { request in
            precondition(request.url?.path == "/me/playlists")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "OAuth test-token")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            precondition(query.contains(URLQueryItem(name: "show_tracks", value: "false")))
            precondition(query.contains(URLQueryItem(name: "linked_partitioning", value: "true")))
            return (200, "{\"collection\":[\(playlist)],\"next_href\":\"\(nextURL)\"}")
        }
        let page = try await client.playlists(accessToken: "test-token")
        precondition(page.playlists.count == 1 && page.nextURL?.absoluteString == nextURL)

        PlaylistURLProtocol.respond { request in
            precondition(request.url?.absoluteString == nextURL)
            return (200, "[]")
        }
        let lastPage = try await client.playlists(accessToken: "test-token", pageURL: page.nextURL)
        precondition(lastPage.playlists.isEmpty && lastPage.nextURL == nil)

        PlaylistURLProtocol.respond { request in
            precondition(request.url?.path == "/me/likes/playlists")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "OAuth test-token")
            return (200, "{\"collection\":[\(playlist)],\"next_href\":\"\(nextURL)\"}")
        }
        let likedPage = try await client.likedPlaylists(accessToken: "test-token")
        precondition(likedPage.playlists == page.playlists && likedPage.nextURL == page.nextURL)
        PlaylistURLProtocol.respond { request in
            precondition(request.url?.absoluteString == nextURL)
            return (200, "{\"collection\":[]}")
        }
        _ = try await client.likedPlaylists(accessToken: "test-token", pageURL: likedPage.nextURL)
        for isLiked in [true, false] {
            PlaylistURLProtocol.respond { request in
                precondition(request.url?.path == "/likes/playlists/soundcloud:playlists:42")
                precondition(request.httpMethod == (isLiked ? "POST" : "DELETE"))
                precondition(request.value(forHTTPHeaderField: "Authorization") == "OAuth test-token")
                return (200, "")
            }
            try await client.setPlaylistLiked(urn: "soundcloud:playlists:42", isLiked: isLiked,
                                              accessToken: "test-token")
        }

        for isPrivate in [true, false] {
            PlaylistURLProtocol.respond { request in
                precondition(request.url?.path == "/playlists")
                precondition(request.httpMethod == "POST")
                precondition(request.value(forHTTPHeaderField: "Authorization") == "OAuth test-token")
                precondition(request.value(forHTTPHeaderField: "Content-Type") == "application/json; charset=utf-8")
                var body = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 1024)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        precondition(count >= 0)
                        if count == 0 { break }
                        body.append(contentsOf: buffer.prefix(count))
                    }
                }
                let payload = try! JSONSerialization.jsonObject(with: body) as! [String: [String: Any]]
                precondition(payload["playlist"]?["title"] as? String == "Mix 🎶 & friends")
                precondition(payload["playlist"]?["description"] as? String == "A new mix")
                precondition(payload["playlist"]?["sharing"] as? String == (isPrivate ? "private" : "public"))
                precondition((payload["playlist"]?["tracks"] as? [Any])?.isEmpty == true)
                return (201, playlist)
            }
            let created = try await client.createPlaylist(
                title: "Mix 🎶 & friends", description: "A new mix", isPrivate: isPrivate, accessToken: "test-token"
            )
            precondition(created.urn == "soundcloud:playlists:42")
        }
        PlaylistURLProtocol.respond { _ in (401, "{}") }
        do {
            _ = try await client.createPlaylist(title: "Mix", description: "", isPrivate: true, accessToken: "test-token")
            fatalError("Unauthorized creation was accepted")
        } catch SoundCloudError.unauthorized {}

        let artistURN = "soundcloud:users:7"
        let artistNextURL = "https://api.soundcloud.com/users/\(artistURN)/playlists?cursor=next"
        PlaylistURLProtocol.respond { request in
            precondition(request.url?.path == "/users/\(artistURN)/playlists")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "OAuth test-token")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            precondition(query.contains(URLQueryItem(name: "show_tracks", value: "false")))
            precondition(query.contains(URLQueryItem(name: "linked_partitioning", value: "true")))
            return (200, "{\"collection\":[\(playlist)],\"next_href\":\"\(artistNextURL)\"}")
        }
        let artistPage = try await client.artistPlaylists(urn: artistURN, accessToken: "test-token")
        precondition(artistPage.playlists == page.playlists)
        precondition(artistPage.nextURL?.absoluteString == artistNextURL)
        PlaylistURLProtocol.respond { request in
            precondition(request.url?.absoluteString == artistNextURL)
            return (200, "{\"collection\":[],\"next_href\":null}")
        }
        let lastArtistPage = try await client.artistPlaylists(
            urn: artistURN, accessToken: "test-token", pageURL: artistPage.nextURL
        )
        precondition(lastArtistPage.playlists.isEmpty && lastArtistPage.nextURL == nil)

        PlaylistURLProtocol.respond { request in
            precondition(request.url?.path == "/playlists/soundcloud:playlists:42")
            return (200, playlist)
        }
        let details = try await client.playlist(urn: "soundcloud:playlists:42", accessToken: "test-token")
        precondition(details == page.playlists.first)

        let track = """
            {"urn":"soundcloud:tracks:1","title":"First",
             "permalink_url":"https://soundcloud.com/owner/track","access":"playable",
             "user":{"username":"Owner","permalink_url":"https://soundcloud.com/owner"}}
            """
        let tracksURL = "https://api.soundcloud.com/playlists/soundcloud:playlists:42/tracks?cursor=next"
        PlaylistURLProtocol.respond { request in
            precondition(request.url?.path == "/playlists/soundcloud:playlists:42/tracks")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            precondition(query.contains(URLQueryItem(name: "access", value: "playable,preview")))
            precondition(query.contains(URLQueryItem(name: "linked_partitioning", value: "true")))
            let preview = track.replacingOccurrences(of: "tracks:1", with: "tracks:2")
                .replacingOccurrences(of: "playable", with: "preview")
            let blocked = track.replacingOccurrences(of: "playable", with: "blocked")
            return (200, "{\"collection\":[\(track),\(preview),\(blocked)],\"next_href\":\"\(tracksURL)\"}")
        }
        let tracks = try await client.playlistTracks(urn: details.urn, accessToken: "test-token")
        precondition(tracks.tracks.map(\.urn) == ["soundcloud:tracks:1", "soundcloud:tracks:2"])
        precondition(tracks.tracks.last?.access == .preview)
        PlaylistURLProtocol.respond { request in
            precondition(request.url?.absoluteString == tracksURL)
            return (200, "[]")
        }
        let lastTracks = try await client.playlistTracks(
            urn: details.urn, accessToken: "test-token", pageURL: tracks.nextURL
        )
        precondition(lastTracks.tracks.isEmpty && lastTracks.nextURL == nil)

        PlaylistURLProtocol.respond { _ in
            (200, "{\"collection\":[],\"next_href\":\"https://example.com/playlists\"}")
        }
        do {
            _ = try await client.playlists(accessToken: "test-token")
            fatalError("Untrusted pagination URL was accepted")
        } catch SoundCloudError.unexpectedURL {}
        PlaylistURLProtocol.respond { request in
            (200, "{\"collection\":[],\"next_href\":\"\(request.url!.absoluteString)\"}")
        }
        do {
            _ = try await client.playlists(accessToken: "test-token")
            fatalError("Repeated pagination URL was accepted")
        } catch SoundCloudError.invalidData {}
        PlaylistURLProtocol.respond { _ in (401, "{}") }
        do {
            _ = try await client.playlist(urn: details.urn, accessToken: "test-token")
            fatalError("Unauthorized response was accepted")
        } catch SoundCloudError.unauthorized {}
        PlaylistURLProtocol.respond { request in
            precondition(request.url?.path == "/playlists/soundcloud:playlists:42")
            precondition(request.httpMethod == "DELETE")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "OAuth test-token")
            return (200, "")
        }
        try await client.deletePlaylist(urn: "soundcloud:playlists:42", accessToken: "test-token")
        PlaylistURLProtocol.respond { _ in (401, "{}") }
        do {
            try await client.deletePlaylist(urn: "soundcloud:playlists:42", accessToken: "test-token")
            fatalError("Unauthorized deletion was accepted")
        } catch SoundCloudError.unauthorized {}
        print("Playlist decoding and API checks passed")
    }
}

private final class PlaylistURLProtocol: URLProtocol {
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

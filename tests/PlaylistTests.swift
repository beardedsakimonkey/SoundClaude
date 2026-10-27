import Foundation

@main
struct PlaylistTests {
    static func main() async throws {
        let decoder = JSONDecoder()
        let playlist = """
            {"id":42,"title":"My playlist",
             "permalink_url":"https://soundcloud.com/owner/sets/my-playlist",
             "artwork_url":"","description":null,"track_count":0,
             "duration":0,"sharing":"private",
             "user":{"username":"Owner","permalink_url":"https://soundcloud.com/owner"}}
            """
        let tagFixtures: [(String?, [String])] = [
            (nil, []),
            ("", []),
            (#"ambient "deep house" 日本語 geo:lat=43.555"#, ["ambient", "deep house", "日本語"]),
        ]
        for (tagList, expected) in tagFixtures {
            var json = try JSONSerialization.jsonObject(with: Data(playlist.utf8)) as! [String: Any]
            json["tag_list"] = tagList ?? (NSNull() as Any)
            let data = try JSONSerialization.data(withJSONObject: json)
            let normalized = try decoder.decode(RawPlaylist.self, from: data).normalized()!
            precondition(normalized.tags == expected)
            let cached = try decoder.decode(SoundCloudPlaylist.self, from: JSONEncoder().encode(normalized))
            precondition(cached.tags == expected)
        }
        let nextURL = "https://api-v2.soundcloud.com/users/42/playlists_without_albums?cursor=next"
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
        precondition(cachedUndated.tags.isEmpty)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaylistURLProtocol.self]
        let client = SoundCloudClient(
            configuration: APITestSupport.configuration,
            sessionConfiguration: configuration
        )
        func body(of request: URLRequest) -> Data {
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
            return body
        }
        func playlistPayload(_ request: URLRequest) -> [String: Any] {
            precondition(request.value(forHTTPHeaderField: "Content-Type") == "application/json; charset=utf-8")
            let json = try! JSONSerialization.jsonObject(with: body(of: request)) as! [String: [String: Any]]
            return json["playlist"]!
        }

        PlaylistURLProtocol.respond { request in
            precondition(request.url?.path == "/users/42/playlists_without_albums")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "OAuth test-token")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            precondition(query.contains(URLQueryItem(name: "limit", value: "200")))
            precondition(query.contains(URLQueryItem(name: "linked_partitioning", value: "1")))
            return (200, "{\"collection\":[\(playlist)],\"next_href\":\"\(nextURL)\"}")
        }
        let page = try await client.playlists(accessToken: "test-token")
        precondition(page.playlists.count == 1 && page.nextURL?.absoluteString == nextURL)
        precondition(page.playlists[0].urn == "soundcloud:playlists:42")

        PlaylistURLProtocol.respond { request in
            precondition(request.url?.absoluteString == nextURL)
            return (200, "[]")
        }
        let lastPage = try await client.playlists(accessToken: "test-token", pageURL: page.nextURL)
        precondition(lastPage.playlists.isEmpty && lastPage.nextURL == nil)

        // Playlist likes wrap each playlist in a like entry.
        PlaylistURLProtocol.respond { request in
            precondition(request.url?.path == "/users/42/playlist_likes")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "OAuth test-token")
            return (200, """
                {"collection":[{"created_at":"2026-09-01T00:00:00Z","kind":"like","playlist":\(playlist)},
                 {"created_at":"2026-09-01T00:00:00Z","kind":"like","playlist":null}],
                 "next_href":"\(nextURL)"}
                """)
        }
        let likedPage = try await client.likedPlaylists(accessToken: "test-token")
        precondition(likedPage.playlists == page.playlists && likedPage.nextURL == page.nextURL)
        PlaylistURLProtocol.respond { request in
            precondition(request.url?.absoluteString == nextURL)
            return (200, "{\"collection\":[]}")
        }
        _ = try await client.likedPlaylists(accessToken: "test-token", pageURL: likedPage.nextURL)
        let likedArtistURN = "soundcloud:users:1"
        let artistLikesNextURL = URL(string: "https://api-v2.soundcloud.com/users/1/playlist_likes?cursor=next")!
        PlaylistURLProtocol.respond { request in
            precondition(request.httpMethod == "GET")
            precondition(request.url?.path == "/users/1/playlist_likes")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "OAuth test-token")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            precondition(query.contains(URLQueryItem(name: "limit", value: "25")))
            precondition(query.contains(URLQueryItem(name: "linked_partitioning", value: "1")))
            return (200, """
                {"collection":[{"kind":"like","playlist":\(playlist)}],"next_href":"\(artistLikesNextURL.absoluteString)"}
                """)
        }
        let artistLikes = try await client.artistPlaylistLikes(urn: likedArtistURN, accessToken: "test-token")
        precondition(artistLikes.playlists == page.playlists)
        precondition(artistLikes.nextURL == artistLikesNextURL)
        PlaylistURLProtocol.respond { request in
            precondition(request.url == artistLikesNextURL)
            return (200, #"{"collection":[],"next_href":null}"#)
        }
        let artistLikesLastPage = try await client.artistPlaylistLikes(
            urn: likedArtistURN, accessToken: "test-token", pageURL: artistLikes.nextURL
        )
        precondition(artistLikesLastPage.playlists.isEmpty && artistLikesLastPage.nextURL == nil)

        for isLiked in [true, false] {
            PlaylistURLProtocol.respond { request in
                precondition(request.url?.path == "/users/42/playlist_likes/42")
                precondition(request.httpMethod == (isLiked ? "PUT" : "DELETE"))
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
                let payload = playlistPayload(request)
                precondition(payload["title"] as? String == "Mix 🎶 & friends")
                precondition(payload["description"] as? String == "A new mix\r\nSecond line")
                precondition(payload["sharing"] as? String == (isPrivate ? "private" : "public"))
                precondition((payload["tracks"] as? [Int])?.isEmpty == true)
                return (201, playlist)
            }
            let created = try await client.createPlaylist(
                title: "Mix 🎶 & friends", description: "A new mix\r\nSecond line", isPrivate: isPrivate, accessToken: "test-token"
            )
            precondition(created.urn == "soundcloud:playlists:42")
        }
        // Artwork upload is not ported; refuse before creating a playlist without it.
        PlaylistURLProtocol.respond { _ in fatalError("Playlist with artwork was sent") }
        do {
            _ = try await client.createPlaylist(
                title: "Mix", description: "", isPrivate: true,
                artwork: PlaylistArtwork(data: Data([0, 255]), format: .png), accessToken: "test-token"
            )
            fatalError("Artwork upload was accepted")
        } catch SoundCloudError.api {}
        PlaylistURLProtocol.respond { _ in (401, "{}") }
        do {
            _ = try await client.createPlaylist(title: "Mix", description: "", isPrivate: true, accessToken: "test-token")
            fatalError("Unauthorized creation was accepted")
        } catch SoundCloudError.unauthorized {}

        for isPrivate in [true, false] {
            PlaylistURLProtocol.respond { request in
                precondition(request.url?.path == "/playlists/42")
                precondition(request.httpMethod == "PUT")
                precondition(request.value(forHTTPHeaderField: "Authorization") == "OAuth test-token")
                let payload = playlistPayload(request)
                precondition(payload["title"] as? String == "Edited 🎶")
                precondition(payload["description"] as? String == "")
                precondition(payload["sharing"] as? String == (isPrivate ? "private" : "public"))
                precondition(payload["tracks"] == nil)
                return (200, playlist)
            }
            let updated = try await client.updatePlaylist(
                urn: "soundcloud:playlists:42", title: "Edited 🎶", description: "",
                isPrivate: isPrivate, accessToken: "test-token"
            )
            precondition(updated.urn == "soundcloud:playlists:42")
        }
        PlaylistURLProtocol.respond { _ in (401, "{}") }
        do {
            _ = try await client.updatePlaylist(
                urn: "soundcloud:playlists:42", title: "Edited", description: "",
                isPrivate: true, accessToken: "test-token"
            )
            fatalError("Unauthorized update was accepted")
        } catch SoundCloudError.unauthorized {}

        let artistURN = "soundcloud:users:7"
        let artistNextURL = "https://api-v2.soundcloud.com/users/7/playlists_without_albums?cursor=next"
        PlaylistURLProtocol.respond { request in
            precondition(request.url?.path == "/users/7/playlists_without_albums")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "OAuth test-token")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            precondition(query.contains(URLQueryItem(name: "linked_partitioning", value: "1")))
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
            precondition(request.url?.path == "/playlists/42")
            return (200, playlist)
        }
        let details = try await client.playlist(urn: "soundcloud:playlists:42", accessToken: "test-token")
        precondition(details == page.playlists.first)

        func track(_ id: Int, policy: String = "ALLOW") -> String {
            """
            {"id":\(id),"urn":"soundcloud:tracks:\(id)","title":"Track \(id)",
             "permalink_url":"https://soundcloud.com/owner/track-\(id)","policy":"\(policy)",
             "user":{"username":"Owner","permalink_url":"https://soundcloud.com/owner"}}
            """
        }
        // Playlists list their first tracks in full and later ones as ID-only stubs.
        func playlistTracks(_ ids: [Int]) -> String {
            let tracks = ids.enumerated().map { index, id in
                index == 0 ? track(id) : #"{"id":\#(id),"kind":"track","policy":"BLOCK"}"#
            }
            return "{\"tracks\":[\(tracks.joined(separator: ","))]}"
        }

        // Adding replaces the whole track list, keeping blocked tracks and their order.
        var updateRequests = 0
        PlaylistURLProtocol.respond { request in
            updateRequests += 1
            precondition(request.url?.path == "/playlists/42")
            if request.httpMethod == "PUT" {
                precondition(updateRequests == 2)
                precondition(playlistPayload(request)["tracks"] as? [Int] == [1, 2, 3])
                return (200, playlist)
            }
            return (200, playlistTracks([1, 2]))
        }
        try await client.addTrackToPlaylist(
            trackURN: "soundcloud:tracks:3", playlistURN: details.urn, accessToken: "test-token"
        )
        precondition(updateRequests == 2)
        PlaylistURLProtocol.respond { request in
            precondition(request.httpMethod == "GET")
            return (200, playlistTracks([1]))
        }
        try await client.addTrackToPlaylist(
            trackURN: "soundcloud:tracks:1", playlistURN: details.urn, accessToken: "test-token"
        )
        PlaylistURLProtocol.respond { request in
            precondition(request.httpMethod == "GET")
            return (200, "{\"tracks\":[{}]}")
        }
        do {
            try await client.addTrackToPlaylist(
                trackURN: "soundcloud:tracks:3", playlistURN: details.urn, accessToken: "test-token"
            )
            fatalError("Incomplete track identities must not overwrite a playlist")
        } catch SoundCloudError.invalidData {}

        for remaining in [[2, 3], []] {
            var requests = 0
            PlaylistURLProtocol.respond { request in
                requests += 1
                precondition(request.value(forHTTPHeaderField: "Authorization") == "OAuth test-token")
                precondition(request.url?.path == "/playlists/42")
                if request.httpMethod == "PUT" {
                    precondition(requests == 2)
                    precondition(playlistPayload(request)["tracks"] as? [Int] == remaining)
                    return (200, playlist)
                }
                return (200, playlistTracks([1] + remaining))
            }
            try await client.removeTrackFromPlaylist(
                trackURN: "soundcloud:tracks:1", playlistURN: details.urn, accessToken: "test-token"
            )
            precondition(requests == 2)
        }
        PlaylistURLProtocol.respond { request in
            precondition(request.httpMethod == "GET")
            return (200, playlistTracks([1]))
        }
        try await client.removeTrackFromPlaylist(
            trackURN: "soundcloud:tracks:99", playlistURN: details.urn, accessToken: "test-token"
        )
        PlaylistURLProtocol.respond { request in
            precondition(request.httpMethod == "GET")
            return (200, "{\"tracks\":[{}]}")
        }
        do {
            try await client.removeTrackFromPlaylist(
                trackURN: "soundcloud:tracks:1", playlistURN: details.urn, accessToken: "test-token"
            )
            fatalError("Incomplete identities must not overwrite a playlist during removal")
        } catch SoundCloudError.invalidData {}
        PlaylistURLProtocol.respond { request in
            request.httpMethod == "PUT" ? (403, "{}") : (200, playlistTracks([1]))
        }
        do {
            try await client.removeTrackFromPlaylist(
                trackURN: "soundcloud:tracks:1", playlistURN: details.urn, accessToken: "test-token"
            )
            fatalError("Failed removal was accepted")
        } catch SoundCloudError.api {}

        let stationURN = "soundcloud:system-playlists:artist-stations:42"
        for field in ["", ",\"station_urn\":null", ",\"station_urn\":\"\(stationURN)\""] {
            let json = "{\"username\":\"Owner\",\"permalink_url\":\"https://soundcloud.com/owner\"\(field)}"
            let user = try decoder.decode(RawUser.self, from: Data(json.utf8)).normalized()!
            precondition(user.stationURN == (field.contains(stationURN) ? stationURN : nil))
            let cached = try decoder.decode(SoundCloudUser.self, from: JSONEncoder().encode(user))
            precondition(cached.stationURN == user.stationURN)
            let direct = try decoder.decode(SoundCloudUser.self, from: Data(json.utf8))
            precondition(direct.stationURN == user.stationURN)
        }
        // Stations list ID-only stubs, which load in one batch and keep their order.
        PlaylistURLProtocol.respond { request in
            precondition(request.httpMethod == "GET")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "OAuth test-token")
            if request.url?.path == "/tracks" {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                precondition(query == [URLQueryItem(name: "ids", value: "3,2")])
                return (200, "[\(track(2, policy: "SNIP")),\(track(3, policy: "BLOCK"))]")
            }
            precondition(request.url?.path == "/system-playlists/\(stationURN)")
            return (200, #"{"tracks":[\#(track(1)),{"id":3},{"id":2},{}]}"#)
        }
        let stationTracks = try await client.stationTracks(urn: stationURN, accessToken: "test-token")
        precondition(stationTracks.map(\.urn) == ["soundcloud:tracks:1", "soundcloud:tracks:2"])
        precondition(stationTracks.last?.access == .preview)
        PlaylistURLProtocol.respond { _ in
            (200, """
            {"title":"Artist station","description":"Similar tracks",
             "permalink_url":"https://soundcloud.com/discover/sets/artist-stations:42",
             "last_updated":"2026-09-17T12:00:00Z","tracks":[\(track(1))]}
            """)
        }
        let station = try await client.station(urn: stationURN, accessToken: "test-token")
        precondition(station.title == "Artist station")
        precondition(station.description == "Similar tracks")
        precondition(station.permalinkURL?.path == "/discover/sets/artist-stations:42")
        precondition(station.lastUpdated == "2026-09-17T12:00:00Z")
        precondition(station.trackCount == 1 && station.tracks.map(\.urn) == ["soundcloud:tracks:1"])
        PlaylistURLProtocol.respond { _ in (200, "{\"tracks\":[]}") }
        let emptyStation = try await client.stationTracks(urn: stationURN, accessToken: "test-token")
        precondition(emptyStation.isEmpty)
        PlaylistURLProtocol.respond { _ in (404, "{}") }
        do {
            _ = try await client.stationTracks(urn: stationURN, accessToken: "test-token")
            fatalError("Missing station was accepted")
        } catch SoundCloudError.api {}

        // Playlist tracks arrive with the playlist; stubs load in batches of 50.
        let manyIDs = Array(1...120)
        var batches: [[String]] = []
        PlaylistURLProtocol.respond { request in
            if request.url?.path == "/tracks" {
                let ids = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                    .queryItems!.first { $0.name == "ids" }!.value!.split(separator: ",").map(String.init)
                batches.append(ids)
                return (200, "[\(ids.map { track(Int($0)!, policy: $0 == "2" ? "SNIP" : $0 == "3" ? "BLOCK" : "ALLOW") }.joined(separator: ","))]")
            }
            precondition(request.url?.path == "/playlists/42")
            return (200, playlistTracks(manyIDs))
        }
        let tracks = try await client.playlistTracks(urn: details.urn, accessToken: "test-token")
        precondition(batches.map(\.count) == [50, 50, 19])
        precondition(tracks.tracks.map(\.urn) == manyIDs.filter { $0 != 3 }.map { "soundcloud:tracks:\($0)" })
        precondition(tracks.tracks[1].access == .preview && tracks.nextURL == nil)
        PlaylistURLProtocol.respond { _ in fatalError("Playlist tracks have no later pages") }
        let lastTracks = try await client.playlistTracks(
            urn: details.urn, accessToken: "test-token", pageURL: URL(string: nextURL)
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
            precondition(request.url?.path == "/playlists/42")
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

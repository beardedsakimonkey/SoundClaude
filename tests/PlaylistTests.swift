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
        let likedArtistURN = "soundcloud:users:1"
        let artistLikesNextURL = URL(string: "https://api.soundcloud.com/users/\(likedArtistURN)/likes/playlists?cursor=next")!
        PlaylistURLProtocol.respond { request in
            precondition(request.httpMethod == "GET")
            precondition(request.url?.path == "/users/\(likedArtistURN)/likes/playlists")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "OAuth test-token")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            precondition(query.contains(URLQueryItem(name: "limit", value: "25")))
            precondition(query.contains(URLQueryItem(name: "linked_partitioning", value: "true")))
            precondition(!query.contains { $0.name == "access" || $0.name == "show_tracks" })
            return (200, """
                {"collection":[\(playlist)],"next_href":"\(artistLikesNextURL.absoluteString)"}
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
                precondition(request.url?.path == "/likes/playlists/soundcloud:playlists:42")
                precondition(request.httpMethod == (isLiked ? "POST" : "DELETE"))
                precondition(request.value(forHTTPHeaderField: "Authorization") == "OAuth test-token")
                return (200, "")
            }
            try await client.setPlaylistLiked(urn: "soundcloud:playlists:42", isLiked: isLiked,
                                              accessToken: "test-token")
        }

        for isPrivate in [true, false] {
            for format in [nil, PlaylistArtwork.Format.gif, .jpeg, .png] {
                let artwork = format.map { PlaylistArtwork(data: Data([0, 255, 13, 10, 128]), format: $0) }
                PlaylistURLProtocol.respond { request in
                    precondition(request.url?.path == "/playlists")
                    precondition(request.httpMethod == "POST")
                    precondition(request.value(forHTTPHeaderField: "Authorization") == "OAuth test-token")
                    let contentType = request.value(forHTTPHeaderField: "Content-Type")!
                    precondition(contentType.hasPrefix("multipart/form-data; boundary="))
                    let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
                    precondition(!boundary.isEmpty)
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
                    var expected = Data()
                    func append(_ value: String) { expected.append(contentsOf: value.utf8) }
                    for (name, value) in [("title", "Mix 🎶 & friends"), ("description", "A new mix\r\nSecond line"),
                                          ("sharing", isPrivate ? "private" : "public")] {
                        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"playlist[\(name)]\"\r\n\r\n\(value)\r\n")
                    }
                    if let artwork {
                        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"playlist[artwork_data]\"; filename=\"artwork.\(artwork.format.rawValue)\"\r\n")
                        append("Content-Type: \(artwork.format.mimeType)\r\n\r\n")
                        expected.append(artwork.data)
                        append("\r\n")
                    }
                    append("--\(boundary)--\r\n")
                    precondition(body == expected)
                    return (201, playlist)
                }
                let created = try await client.createPlaylist(
                    title: "Mix 🎶 & friends", description: "A new mix\r\nSecond line", isPrivate: isPrivate, artwork: artwork, accessToken: "test-token"
                )
                precondition(created.urn == "soundcloud:playlists:42")
            }
        }
        PlaylistURLProtocol.respond { _ in (401, "{}") }
        do {
            _ = try await client.createPlaylist(title: "Mix", description: "", isPrivate: true, accessToken: "test-token")
            fatalError("Unauthorized creation was accepted")
        } catch SoundCloudError.unauthorized {}

        for isPrivate in [true, false] {
            PlaylistURLProtocol.respond { request in
                precondition(request.url?.path == "/playlists/soundcloud:playlists:42")
                precondition(request.httpMethod == "PUT")
                precondition(request.value(forHTTPHeaderField: "Authorization") == "OAuth test-token")
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
                precondition(payload["playlist"]?["title"] as? String == "Edited 🎶")
                precondition(payload["playlist"]?["description"] as? String == "")
                precondition(payload["playlist"]?["sharing"] as? String == (isPrivate ? "private" : "public"))
                precondition(payload["playlist"]?["tracks"] == nil)
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
        let updateNext = "https://api.soundcloud.com/playlists/soundcloud:playlists:42/tracks?cursor=update"
        var updateRequests = 0
        PlaylistURLProtocol.respond { request in
            updateRequests += 1
            if request.httpMethod == "PUT" {
                precondition(updateRequests == 3)
                precondition(request.url?.path == "/playlists/soundcloud:playlists:42")
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
                let payload = try! JSONSerialization.jsonObject(with: body) as! [String: [String: [[String: String]]]]
                precondition(payload["playlist"]?["tracks"]?.compactMap { $0["urn"] } == [
                    "soundcloud:tracks:1", "soundcloud:tracks:2", "soundcloud:tracks:3"
                ])
                return (200, playlist)
            }
            if updateRequests == 1 {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                precondition(query.contains(URLQueryItem(name: "access", value: "playable,preview,blocked")))
                return (200, "{\"collection\":[\(track)],\"next_href\":\"\(updateNext)\"}")
            }
            precondition(request.url?.absoluteString == updateNext)
            return (200, "[{\"urn\":\"soundcloud:tracks:2\",\"access\":\"blocked\"}]")
        }
        try await client.addTrackToPlaylist(
            trackURN: "soundcloud:tracks:3", playlistURN: details.urn, accessToken: "test-token"
        )
        precondition(updateRequests == 3)
        PlaylistURLProtocol.respond { request in
            precondition(request.httpMethod == "GET")
            return (200, "[\(track)]")
        }
        try await client.addTrackToPlaylist(
            trackURN: "soundcloud:tracks:1", playlistURN: details.urn, accessToken: "test-token"
        )
        PlaylistURLProtocol.respond { request in
            precondition(request.httpMethod == "GET")
            return (200, "[{}]")
        }
        do {
            try await client.addTrackToPlaylist(
                trackURN: "soundcloud:tracks:3", playlistURN: details.urn, accessToken: "test-token"
            )
            fatalError("Incomplete track identities must not overwrite a playlist")
        } catch SoundCloudError.invalidData {}

        // Removal reads every page and preserves blocked tracks and their order.
        for remaining in [["soundcloud:tracks:2", "soundcloud:tracks:3"], []] {
            var requests = 0
            PlaylistURLProtocol.respond { request in
                requests += 1
                precondition(request.value(forHTTPHeaderField: "Authorization") == "OAuth test-token")
                if request.httpMethod == "PUT" {
                    precondition(requests == 3)
                    precondition(request.url?.path == "/playlists/soundcloud:playlists:42")
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
                    let payload = try! JSONSerialization.jsonObject(with: body) as! [String: [String: [[String: String]]]]
                    precondition(payload["playlist"]?["tracks"]?.compactMap { $0["urn"] } == remaining)
                    return (200, playlist)
                }
                if requests == 1 {
                    let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                    precondition(query.contains(URLQueryItem(name: "access", value: "playable,preview,blocked")))
                    return (200, "{\"collection\":[\(track)],\"next_href\":\"\(updateNext)\"}")
                }
                precondition(request.url?.absoluteString == updateNext)
                let tracks = remaining.map { ["urn": $0, "access": "blocked"] }
                return (200, String(data: try! JSONSerialization.data(withJSONObject: tracks), encoding: .utf8)!)
            }
            try await client.removeTrackFromPlaylist(
                trackURN: "soundcloud:tracks:1", playlistURN: details.urn, accessToken: "test-token"
            )
            precondition(requests == 3)
        }
        PlaylistURLProtocol.respond { request in
            precondition(request.httpMethod == "GET")
            return (200, "[\(track)]")
        }
        try await client.removeTrackFromPlaylist(
            trackURN: "soundcloud:tracks:missing", playlistURN: details.urn, accessToken: "test-token"
        )
        PlaylistURLProtocol.respond { request in
            precondition(request.httpMethod == "GET")
            return (200, "[{}]")
        }
        do {
            try await client.removeTrackFromPlaylist(
                trackURN: "soundcloud:tracks:1", playlistURN: details.urn, accessToken: "test-token"
            )
            fatalError("Incomplete identities must not overwrite a playlist during removal")
        } catch SoundCloudError.invalidData {}
        PlaylistURLProtocol.respond { request in
            request.httpMethod == "PUT" ? (403, "{}") : (200, "[\(track)]")
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
        PlaylistURLProtocol.respond { request in
            precondition(request.httpMethod == "GET")
            precondition(request.url?.path == "/system-playlists/\(stationURN)")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "OAuth test-token")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            precondition(query.contains(URLQueryItem(name: "access", value: "playable,preview")))
            let preview = track.replacingOccurrences(of: "tracks:1", with: "tracks:2")
                .replacingOccurrences(of: "playable", with: "preview")
            let blocked = track.replacingOccurrences(of: "playable", with: "blocked")
            return (200, "{\"tracks\":[\(track),\(preview),\(blocked),{}]}")
        }
        let stationTracks = try await client.stationTracks(urn: stationURN, accessToken: "test-token")
        precondition(stationTracks.map(\.urn) == ["soundcloud:tracks:1", "soundcloud:tracks:2"])
        PlaylistURLProtocol.respond { _ in
            (200, """
            {"title":"Artist station","description":"Similar tracks",
             "permalink_url":"https://soundcloud.com/discover/sets/artist-stations:42",
             "last_updated":"2026-09-17T12:00:00Z","track_count":1,"tracks":[\(track)]}
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

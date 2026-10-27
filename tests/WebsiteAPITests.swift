import Foundation

@main
struct WebsiteAPITests {
    static func main() async throws {
        let decoder = JSONDecoder()
        let user = #"{"urn":"soundcloud:users:3","username":"Artist","permalink_url":"https://soundcloud.com/artist","country_code":"DE","likes_count":12}"#

        // api-v2 error bodies come in several shapes.
        for (json, message) in [(#"{"message":"A"}"#, "A"), (#"{"error":"B"}"#, "B"),
                                (#"{"errors":[{"error_message":"C"}]}"#, "C"), (#"{"errors":[]}"#, nil)] {
            let body = try decoder.decode(APIErrorBody.self, from: Data(json.utf8))
            precondition(body.message == message)
        }

        // api-v2 tracks use policy, likes_count, and secret_token.
        for (policy, access) in [("ALLOW", SoundCloudTrack.Access.playable), ("MONETIZE", .playable),
                                 ("SNIP", .preview), ("BLOCK", nil), ("UNKNOWN", nil)] {
            let json = """
                {"id":2,"title":"Track","permalink_url":"https://soundcloud.com/artist/track",
                 "policy":"\(policy)","likes_count":7,"secret_token":"s-secret","user":\(user)}
                """
            let track = try decoder.decode(RawTrack.self, from: Data(json.utf8)).normalized()
            precondition(track?.access == access)
            if let track {
                precondition(track.urn == "soundcloud:tracks:2" && track.likesCount == 7)
                precondition(track.secretToken == "s-secret")
                precondition(track.artist.publicFavoritesCount == 12)
            }
        }
        let details = try decoder.decode(RawUser.self, from: Data(user.utf8)).normalizedArtistDetails()
        precondition(details?.country == Locale.current.localizedString(forRegionCode: "DE"))

        // Wrapped likes and reposts keep only the requested content type.
        let page = try decoder.decode(RawTrackPage.self, from: Data("""
            {"collection":[
              {"kind":"like","track":{"id":1,"title":"Liked","permalink_url":"https://soundcloud.com/a/1","policy":"ALLOW","user":\(user)}},
              {"kind":"like","track":null},
              {"kind":"like","playlist":{"id":9}},
              {"type":"playlist-repost","playlist":{"id":9}},
              {"id":5,"kind":"track","title":"Bare","permalink_url":"https://soundcloud.com/a/5","policy":"ALLOW","user":\(user)}
            ],"next_href":null}
            """.utf8))
        precondition(page.collection.compactMap { $0.normalized() }.map(\.urn)
            == ["soundcloud:tracks:1", "soundcloud:tracks:5"])

        // Streams prefer full AAC at the highest fixed bitrate and skip encrypted protocols.
        let streams = try decoder.decode(StreamResponse.self, from: Data("""
            {"track_authorization":"auth","media":{"transcodings":[
              {"url":"https://api-v2.soundcloud.com/media/preview","preset":"mp3_0_0","snipped":true,"format":{"protocol":"progressive","mime_type":"audio/mpeg"}},
              {"url":"https://api-v2.soundcloud.com/media/drm","preset":"aac_160k","format":{"protocol":"ctr-encrypted-hls","mime_type":"audio/mp4"}},
              {"url":"https://api-v2.soundcloud.com/media/abr","preset":"abr_sq","format":{"protocol":"hls","mime_type":"audio/mpegurl"}},
              {"url":"https://api-v2.soundcloud.com/media/lq","preset":"aac_96k","format":{"protocol":"hls","mime_type":"audio/mp4; codecs=\\"mp4a.40.2\\""}},
              {"url":"https://api-v2.soundcloud.com/media/sq","preset":"aac_160k","format":{"protocol":"hls","mime_type":"audio/mp4; codecs=\\"mp4a.40.2\\""}}
            ]}}
            """.utf8))
        precondition(streams.candidates.map(\.transcoding.url.lastPathComponent) == ["sq", "abr", "lq", "preview"])
        precondition(streams.candidates.last?.source.isPreview == true)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebsiteURLProtocol.self]
        let client = SoundCloudClient(configuration: APITestSupport.configuration, sessionConfiguration: configuration)
        let track = SoundCloudTrack(
            urn: "soundcloud:tracks:2", title: "Track",
            artist: SoundCloudUser(urn: nil, username: "Artist", avatarURL: nil, permalinkURL: URL(string: "https://soundcloud.com/artist")!),
            artworkURL: nil, waveformURL: nil, permalinkURL: URL(string: "https://soundcloud.com/artist/track")!,
            durationMilliseconds: 1000, access: .playable, secretToken: "s-secret"
        )
        func trackJSON(authorization: String) -> String {
            """
            {"id":2,"track_authorization":"\(authorization)","media":{"transcodings":[
              {"url":"https://api-v2.soundcloud.com/media/sq","preset":"aac_160k","format":{"protocol":"hls","mime_type":"audio/mp4"}},
              {"url":"https://api-v2.soundcloud.com/media/preview","snipped":true,"format":{"protocol":"progressive","mime_type":"audio/mpeg"}}
            ]}}
            """
        }

        // Each resolution fetches a fresh authorization, then falls back past failing streams.
        var resolutions = 0
        WebsiteURLProtocol.respond { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            switch request.url!.path {
            case "/tracks/2":
                precondition(query == [URLQueryItem(name: "secret_token", value: "s-secret")])
                resolutions += 1
                return (200, trackJSON(authorization: "auth-\(resolutions)"))
            case "/media/sq":
                precondition(query == [URLQueryItem(name: "track_authorization", value: "auth-\(resolutions)")])
                return resolutions == 1
                    ? (200, #"{"url":"https://playback.media-streaming.soundcloud.cloud/a/playlist.m3u8"}"#)
                    : (200, #"{"url":"https://example.com/untrusted.m3u8"}"#)
            case "/media/preview":
                return (200, #"{"url":"https://cf-media.sndcdn.com/preview.mp3"}"#)
            default:
                fatalError("Unexpected path \(request.url!.path)")
            }
        }
        let full = try await client.resolvePlayback(track: track, accessToken: "test-token")
        precondition(full.kind == .hls && full.codec == .aac && full.bitrateKilobitsPerSecond == 160 && !full.isPreview)
        precondition(full.url.host == "playback.media-streaming.soundcloud.cloud")
        let preview = try await client.resolvePlayback(track: track, accessToken: "test-token")
        precondition(preview.isPreview && preview.kind == .mp3 && preview.url.host == "cf-media.sndcdn.com")

        WebsiteURLProtocol.respond { _ in (200, #"{"id":2,"media":{"transcodings":[{"url":"https://api-v2.soundcloud.com/drm","format":{"protocol":"ctr-encrypted-hls","mime_type":"audio/mp4"}}]}}"#) }
        do {
            _ = try await client.resolvePlayback(track: track, accessToken: "test-token")
            fatalError("Encrypted stream was accepted")
        } catch SoundCloudError.playbackUnavailable {}
        WebsiteURLProtocol.respond { request in
            request.url!.path == "/tracks/2" ? (200, trackJSON(authorization: "a")) : (401, "{}")
        }
        do {
            _ = try await client.resolvePlayback(track: track, accessToken: "test-token")
            fatalError("Expired session fell back to a preview")
        } catch SoundCloudError.unauthorized {}

        // Without a pinned client ID, the client finds soundcloud.com's and replaces it once rejected.
        UserDefaults.standard.removeObject(forKey: "SoundCloudWebsiteClientID")
        defer { UserDefaults.standard.removeObject(forKey: "SoundCloudWebsiteClientID") }
        let discovering = SoundCloudClient(configuration: SoundCloudConfiguration(), sessionConfiguration: configuration)
        var currentID = "a1111111111111111111111111111111"
        var discoveries = 0
        WebsiteURLProtocol.respond { request in
            let url = request.url!
            if url.host == "soundcloud.com" {
                precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
                discoveries += 1
                return (200, #"<script crossorigin src="https://a-v2.sndcdn.com/assets/0-a.js"></script><script crossorigin src="https://a-v2.sndcdn.com/assets/49-b.js"></script>"#)
            }
            if url.host == "a-v2.sndcdn.com" {
                precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
                return url.lastPathComponent == "49-b.js" ? (200, #"x={client_id:"\#(currentID)"}"#) : (200, "")
            }
            precondition(url.host == "api-v2.soundcloud.com")
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            guard query.contains(URLQueryItem(name: "client_id", value: currentID)) else { return (401, "{}") }
            return (200, APITestSupport.meJSON)
        }
        _ = try await discovering.currentUser(accessToken: "test-token")
        precondition(discoveries == 1)
        precondition(UserDefaults.standard.string(forKey: "SoundCloudWebsiteClientID") == currentID)
        _ = try await discovering.currentUser(accessToken: "test-token")
        precondition(discoveries == 1)
        currentID = "b2222222222222222222222222222222"
        _ = try await discovering.currentUser(accessToken: "test-token")
        precondition(discoveries == 2)
        precondition(UserDefaults.standard.string(forKey: "SoundCloudWebsiteClientID") == currentID)
        // An unchanged ID means the session itself expired.
        WebsiteURLProtocol.respond { request in
            request.url!.host == "api-v2.soundcloud.com" ? (401, "{}")
                : request.url!.host == "soundcloud.com"
                    ? (200, #"<script src="https://a-v2.sndcdn.com/assets/49-b.js"></script>"#)
                    : (200, #"client_id:"\#(currentID)""#)
        }
        do {
            _ = try await discovering.currentUser(accessToken: "test-token")
            fatalError("Expired session was accepted")
        } catch SoundCloudError.unauthorized {}
        WebsiteURLProtocol.respond { request in
            precondition(request.url!.host == "soundcloud.com", "Only discovery may run without a client ID")
            return (200, "<html></html>")
        }
        UserDefaults.standard.removeObject(forKey: "SoundCloudWebsiteClientID")
        do {
            _ = try await SoundCloudClient(configuration: SoundCloudConfiguration(), sessionConfiguration: configuration)
                .currentUser(accessToken: "test-token")
            fatalError("Missing client ID was accepted")
        } catch SoundCloudError.configuration {}
        print("Website API decoding, stream resolution, and client ID discovery checks passed")
    }
}

private final class WebsiteURLProtocol: URLProtocol {
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
        // Pinned-ID requests are checked and stripped; discovery requests pass through unchanged.
        let pinned = request.url?.query?.contains("client_id=test-client") == true
        let (request, me) = pinned ? APITestSupport.prepare(self.request) : (self.request, nil)
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

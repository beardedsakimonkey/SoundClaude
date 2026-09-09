import Foundation

struct SoundCloudConfiguration: Sendable {
    static let redirectURI = URL(
        string: "http://127.0.0.1:32148/callback"
    )!

    let clientID: String
    let clientSecret: String
    let apiBaseURL = URL(string: "https://api.soundcloud.com/")!
    let authorizationURL = URL(
        string: "https://secure.soundcloud.com/authorize"
    )!
    let tokenURL = URL(
        string: "https://secure.soundcloud.com/oauth/token"
    )!
    let signOutURL = URL(
        string: "https://secure.soundcloud.com/sign-out"
    )!

    static func bundled() throws -> SoundCloudConfiguration {
        let clientID = Bundle.main.object(
            forInfoDictionaryKey: "SoundCloudClientID"
        ) as? String ?? ""
        let clientSecret = Bundle.main.object(
            forInfoDictionaryKey: "SoundCloudClientSecret"
        ) as? String ?? ""
        guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SoundCloudError.configuration
        }
        return SoundCloudConfiguration(
            clientID: clientID,
            clientSecret: clientSecret
        )
    }
}

enum SoundCloudError: LocalizedError {
    case configuration
    case invalidResponse
    case invalidData
    case unauthorized
    case rateLimited
    case api(String)
    case playbackUnavailable
    case unexpectedURL
    case network

    var errorDescription: String? {
        switch self {
        case .configuration:
            return "Add SoundCloud credentials to Config/Local.xcconfig."
        case .invalidResponse, .invalidData:
            return "SoundCloud returned invalid data."
        case .unauthorized:
            return "The SoundCloud session has expired."
        case .rateLimited:
            return "SoundCloud is rate limiting requests. Wait and try again."
        case let .api(message):
            return message
        case .playbackUnavailable:
            return "This track is not available for off-platform playback."
        case .unexpectedURL:
            return "SoundCloud returned an unexpected URL."
        case .network:
            return "SoundCloud could not be reached. Check the network connection."
        }
    }
}

private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

actor SoundCloudClient {
    private static let likedTracksPageSize = 25

    private let configuration: SoundCloudConfiguration
    private let session: URLSession
    private let noRedirectSession: URLSession
    private let decoder = JSONDecoder()

    init(
        configuration: SoundCloudConfiguration,
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) {
        self.configuration = configuration

        sessionConfiguration.timeoutIntervalForRequest = 30
        sessionConfiguration.timeoutIntervalForResource = 60
        session = URLSession(configuration: sessionConfiguration)

        let redirectConfiguration = URLSessionConfiguration.ephemeral
        redirectConfiguration.timeoutIntervalForRequest = 30
        redirectConfiguration.timeoutIntervalForResource = 60
        noRedirectSession = URLSession(
            configuration: redirectConfiguration,
            delegate: RedirectBlocker(),
            delegateQueue: nil
        )
    }

    func authorizationURL(state: String, challenge: String) throws -> URL {
        var components = URLComponents(
            url: configuration.authorizationURL,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(
                name: "redirect_uri",
                value: SoundCloudConfiguration.redirectURI.absoluteString
            ),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components?.url else {
            throw SoundCloudError.unexpectedURL
        }
        return url
    }

    func exchangeCode(_ code: String, verifier: String) async throws
        -> OAuthTokenResponse {
        try await tokenRequest([
            "grant_type": "authorization_code",
            "client_id": configuration.clientID,
            "client_secret": configuration.clientSecret,
            "redirect_uri": SoundCloudConfiguration.redirectURI.absoluteString,
            "code_verifier": verifier,
            "code": code,
        ], isRefresh: false)
    }

    func refreshToken(_ refreshToken: String) async throws
        -> OAuthTokenResponse {
        try await tokenRequest([
            "grant_type": "refresh_token",
            "client_id": configuration.clientID,
            "client_secret": configuration.clientSecret,
            "refresh_token": refreshToken,
        ], isRefresh: true)
    }

    func currentUser(accessToken: String) async throws -> SoundCloudUser {
        let url = configuration.apiBaseURL.appending(path: "me")
        let (data, response) = try await authenticatedRequest(
            url: url,
            accessToken: accessToken
        )
        try validate(response: response, data: data)
        guard let user = try decoder.decode(RawUser.self, from: data).normalized() else {
            throw SoundCloudError.invalidData
        }
        return user
    }

    func feed(accessToken: String, pageURL: URL? = nil) async throws -> SoundCloudFeedPage {
        let url = pageURL ?? configuration.apiBaseURL.appending(path: "me/feed")
            .appending(queryItems: [
                URLQueryItem(name: "limit", value: "10"),
                URLQueryItem(name: "access", value: "playable,preview"),
            ])
        try validateAPIURL(url)
        let (data, response) = try await authenticatedRequest(url: url, accessToken: accessToken)
        try validate(response: response, data: data)
        let page = try decoder.decode(RawFeedPage.self, from: data)
        if let nextURL = page.nextURL {
            try validateAPIURL(nextURL)
            guard nextURL != url else { throw SoundCloudError.invalidData }
        }

        var users: [String: SoundCloudUser] = [:]
        var items: [SoundCloudFeedItem] = []
        for activity in page.collection {
            try Task.checkCancellation()
            guard let content = activity.content, let createdAt = activity.createdAt else { continue }
            let user: SoundCloudUser
            if activity.isRepost {
                guard let urn = activity.reposterURN else { throw SoundCloudError.invalidData }
                if let cached = users[urn] {
                    user = cached
                } else {
                    let userURL = configuration.apiBaseURL.appending(path: "users").appending(path: urn)
                    let (userData, userResponse) = try await authenticatedRequest(
                        url: userURL, accessToken: accessToken
                    )
                    try validate(response: userResponse, data: userData)
                    guard let resolved = try decoder.decode(RawUser.self, from: userData).normalized()
                    else { throw SoundCloudError.invalidData }
                    users[urn] = resolved
                    user = resolved
                }
            } else {
                user = content.owner
            }
            items.append(SoundCloudFeedItem(
                content: content, user: user, isRepost: activity.isRepost, createdAt: createdAt
            ))
        }
        return SoundCloudFeedPage(items: items, nextURL: page.nextURL)
    }

    func recentlyPlayedTracks(accessToken: String) async throws -> [SoundCloudTrack] {
        // History is limited to the last 25 distinct tracks and has no pagination.
        let url = configuration.apiBaseURL.appending(path: "me/recently-played/tracks")
            .appending(queryItems: [
                URLQueryItem(name: "access", value: "playable,preview"),
            ])
        let page = try await trackPage(at: url, accessToken: accessToken)
        return page.tracks
    }

    func likedTracks(
        accessToken: String,
        pageURL: URL? = nil,
        pageSize: Int? = nil
    ) async throws -> SoundCloudTrackPage {
        let url: URL
        if let pageURL {
            try validateAPIURL(pageURL)
            if let pageSize {
                var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)
                var queryItems = components?.queryItems ?? []
                queryItems.removeAll { $0.name == "limit" }
                queryItems.append(URLQueryItem(name: "limit", value: String(pageSize)))
                components?.queryItems = queryItems
                guard let nextURL = components?.url else {
                    throw SoundCloudError.unexpectedURL
                }
                url = nextURL
            } else {
                url = pageURL
            }
        } else {
            var components = URLComponents(
                url: configuration.apiBaseURL
                    .appending(path: "me")
                    .appending(path: "likes")
                    .appending(path: "tracks"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(
                    name: "limit",
                    value: String(pageSize ?? Self.likedTracksPageSize)
                ),
                URLQueryItem(name: "linked_partitioning", value: "true"),
                URLQueryItem(name: "access", value: "playable,preview"),
            ]
            guard let initialURL = components?.url else {
                throw SoundCloudError.unexpectedURL
            }
            url = initialURL
        }

        try validateAPIURL(url)
        let (data, response) = try await authenticatedRequest(
            url: url,
            accessToken: accessToken
        )
        try validate(response: response, data: data)
        let page = try decoder.decode(RawTrackPage.self, from: data)
        if let nextURL = page.nextURL {
            try validateAPIURL(nextURL)
            guard nextURL != url else {
                throw SoundCloudError.invalidData
            }
        }
        return SoundCloudTrackPage(
            tracks: page.collection.compactMap { $0.normalized() },
            nextURL: page.nextURL
        )
    }

    func artist(
        _ artist: SoundCloudUser,
        accessToken: String
    ) async throws -> SoundCloudArtistDetails {
        let url: URL
        if let urn = artist.urn {
            url = configuration.apiBaseURL.appending(path: "users")
                .appending(path: urn)
        } else {
            // Older or partial user objects can still be opened by permalink.
            var components = URLComponents(
                url: configuration.apiBaseURL.appending(path: "resolve"),
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [
                URLQueryItem(name: "url", value: artist.permalinkURL.absoluteString),
            ]
            guard let resolveURL = components.url else {
                throw SoundCloudError.unexpectedURL
            }
            var request = URLRequest(url: resolveURL)
            request.setValue("OAuth \(accessToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await send(request, using: noRedirectSession)
            guard response.statusCode == 302,
                  let location = response.value(forHTTPHeaderField: "Location"),
                  let resolvedURL = URL(string: location, relativeTo: resolveURL)?.absoluteURL else {
                try validate(response: response, data: data)
                throw SoundCloudError.invalidData
            }
            try validateAPIURL(resolvedURL)
            url = resolvedURL
        }
        let (data, response) = try await authenticatedRequest(
            url: url,
            accessToken: accessToken
        )
        try validate(response: response, data: data)
        guard let details = try decoder.decode(RawUser.self, from: data)
            .normalizedArtistDetails() else {
            throw SoundCloudError.invalidData
        }
        return details
    }

    func followedArtistURNs(accessToken: String) async throws -> Set<String> {
        struct Page: Decodable {
            let collection: [RawUser]
            let next_href: URL?
        }

        var nextURL: URL? = configuration.apiBaseURL.appending(path: "me/followings")
            .appending(queryItems: [URLQueryItem(name: "limit", value: "200")])
        var visited: Set<URL> = []
        var urns: Set<String> = []
        while let url = nextURL {
            try Task.checkCancellation()
            try validateAPIURL(url)
            guard visited.insert(url).inserted else { throw SoundCloudError.invalidData }
            let (data, response) = try await authenticatedRequest(url: url, accessToken: accessToken)
            try validate(response: response, data: data)
            let page = try decoder.decode(Page.self, from: data)
            for user in page.collection {
                guard let urn = user.urn else { throw SoundCloudError.invalidData }
                urns.insert(urn)
            }
            nextURL = page.next_href
        }
        return urns
    }

    func setArtistFollowed(urn: String, isFollowed: Bool, accessToken: String) async throws {
        let url = configuration.apiBaseURL.appending(path: "me/followings")
            .appending(path: urn)
        let (data, response) = try await authenticatedRequest(
            url: url,
            accessToken: accessToken,
            method: isFollowed ? "PUT" : "DELETE"
        )
        try validate(response: response, data: data)
    }

    func artistHeaderURL(for artist: SoundCloudUser) async throws -> URL? {
        guard let url = SoundCloudProfileHeader.profileURL(artist.permalinkURL)
        else { return nil }
        // Public HTML only: do not attach the API access token.
        let request = URLRequest(url: url, timeoutInterval: 8)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { return nil }
        return SoundCloudProfileHeader.imageURL(in: html, for: artist)
    }

    func artistUsers(
        urn: String,
        list: ArtistUserList,
        accessToken: String,
        pageURL: URL? = nil
    ) async throws -> SoundCloudUserPage {
        var components = URLComponents(
            url: configuration.apiBaseURL.appending(path: "users")
                .appending(path: urn).appending(path: list.rawValue),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "limit", value: "50")]
        guard let url = pageURL ?? components.url else {
            throw SoundCloudError.unexpectedURL
        }
        try validateAPIURL(url)
        let (data, response) = try await authenticatedRequest(url: url, accessToken: accessToken)
        try validate(response: response, data: data)
        let page = try decoder.decode(RawUserPage.self, from: data)
        if let nextURL = page.nextURL { try validateAPIURL(nextURL) }
        return SoundCloudUserPage(
            users: page.collection.compactMap { $0.normalized() },
            nextURL: page.nextURL
        )
    }

    func searchTracks(
        query: String? = nil, genres: String? = nil,
        accessToken: String, pageURL: URL? = nil
    ) async throws -> SoundCloudTrackPage {
        let url = pageURL ?? searchURL(path: "tracks", query: query).appending(queryItems: [
            URLQueryItem(name: "genres", value: genres),
            URLQueryItem(name: "access", value: "playable,preview"),
        ].filter { $0.value != nil })
        return try await trackPage(at: url, accessToken: accessToken)
    }

    func searchPlaylists(
        query: String, accessToken: String, pageURL: URL? = nil
    ) async throws -> SoundCloudPlaylistPage {
        let url = pageURL ?? searchURL(path: "playlists", query: query).appending(queryItems: [
            URLQueryItem(name: "show_tracks", value: "false"),
        ])
        return try await playlistPage(at: url, accessToken: accessToken)
    }

    func searchUsers(
        query: String, accessToken: String, pageURL: URL? = nil
    ) async throws -> SoundCloudUserPage {
        let url = pageURL ?? searchURL(path: "users", query: query)
        try validateAPIURL(url)
        let (data, response) = try await authenticatedRequest(url: url, accessToken: accessToken)
        try validate(response: response, data: data)
        let page = try decoder.decode(RawUserPage.self, from: data)
        if let nextURL = page.nextURL {
            try validateAPIURL(nextURL)
            guard nextURL != url else { throw SoundCloudError.invalidData }
        }
        return SoundCloudUserPage(
            users: page.collection.compactMap { $0.normalized() }, nextURL: page.nextURL
        )
    }

    private func searchURL(path: String, query: String?) -> URL {
        configuration.apiBaseURL.appending(path: path).appending(queryItems: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "25"),
            URLQueryItem(name: "linked_partitioning", value: "true"),
        ].filter { $0.value != nil })
    }

    func artistTracks(
        urn: String,
        accessToken: String,
        pageURL: URL? = nil
    ) async throws -> SoundCloudTrackPage {
        var components = URLComponents(
            url: configuration.apiBaseURL.appending(path: "users")
                .appending(path: urn).appending(path: "tracks"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "limit", value: "25"),
            URLQueryItem(name: "linked_partitioning", value: "true"),
            URLQueryItem(name: "access", value: "playable,preview"),
        ]
        guard let url = pageURL ?? components.url else {
            throw SoundCloudError.unexpectedURL
        }
        return try await trackPage(at: url, accessToken: accessToken)
    }

    func artistReposts(
        urn: String,
        accessToken: String,
        pageURL: URL? = nil
    ) async throws -> SoundCloudTrackPage {
        var components = URLComponents(
            url: configuration.apiBaseURL.appending(path: "users")
                .appending(path: urn).appending(path: "reposts")
                .appending(path: "tracks"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "limit", value: "25"),
            URLQueryItem(name: "linked_partitioning", value: "true"),
            URLQueryItem(name: "access", value: "playable,preview"),
        ]
        guard let url = pageURL ?? components.url else {
            throw SoundCloudError.unexpectedURL
        }
        return try await trackPage(at: url, accessToken: accessToken)
    }

    func artistLikes(
        urn: String,
        accessToken: String,
        pageURL: URL? = nil
    ) async throws -> SoundCloudTrackPage {
        var components = URLComponents(
            url: configuration.apiBaseURL.appending(path: "users")
                .appending(path: urn).appending(path: "likes")
                .appending(path: "tracks"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "limit", value: "25"),
            URLQueryItem(name: "linked_partitioning", value: "true"),
            URLQueryItem(name: "access", value: "playable,preview"),
        ]
        guard let url = pageURL ?? components.url else {
            throw SoundCloudError.unexpectedURL
        }
        return try await trackPage(at: url, accessToken: accessToken)
    }

    func artistPlaylists(
        urn: String,
        accessToken: String,
        pageURL: URL? = nil
    ) async throws -> SoundCloudPlaylistPage {
        let url = pageURL ?? configuration.apiBaseURL.appending(path: "users")
            .appending(path: urn).appending(path: "playlists")
            .appending(queryItems: [
                URLQueryItem(name: "limit", value: "25"),
                URLQueryItem(name: "linked_partitioning", value: "true"),
                URLQueryItem(name: "show_tracks", value: "false"),
            ])
        return try await playlistPage(at: url, accessToken: accessToken)
    }

    func relatedTracks(
        urn: String,
        accessToken: String,
        pageURL: URL? = nil
    ) async throws -> SoundCloudTrackPage {
        var components = URLComponents(
            url: configuration.apiBaseURL.appending(path: "tracks")
                .appending(path: urn).appending(path: "related"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "linked_partitioning", value: "true"),
            URLQueryItem(name: "access", value: "playable,preview"),
        ]
        guard let url = pageURL ?? components.url else {
            throw SoundCloudError.unexpectedURL
        }
        return try await trackPage(at: url, accessToken: accessToken)
    }

    func playlists(accessToken: String, pageURL: URL? = nil) async throws
        -> SoundCloudPlaylistPage {
        var components = URLComponents(
            url: configuration.apiBaseURL.appending(path: "me/playlists"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "limit", value: "200"),
            URLQueryItem(name: "linked_partitioning", value: "true"),
            URLQueryItem(name: "show_tracks", value: "false"),
        ]
        guard let url = pageURL ?? components.url else {
            throw SoundCloudError.unexpectedURL
        }
        return try await playlistPage(at: url, accessToken: accessToken)
    }

    private func playlistPage(at url: URL, accessToken: String) async throws -> SoundCloudPlaylistPage {
        try validateAPIURL(url)
        let (data, response) = try await authenticatedRequest(url: url, accessToken: accessToken)
        try validate(response: response, data: data)
        let page = try decoder.decode(RawPlaylistPage.self, from: data)
        if let nextURL = page.nextURL {
            try validateAPIURL(nextURL)
            guard nextURL != url else { throw SoundCloudError.invalidData }
        }
        return SoundCloudPlaylistPage(
            playlists: page.collection.compactMap { $0.normalized() },
            nextURL: page.nextURL
        )
    }

    func playlist(urn: String, accessToken: String) async throws -> SoundCloudPlaylist {
        let url = configuration.apiBaseURL.appending(path: "playlists")
            .appending(path: urn)
            .appending(queryItems: [URLQueryItem(name: "show_tracks", value: "false")])
        let (data, response) = try await authenticatedRequest(url: url, accessToken: accessToken)
        try validate(response: response, data: data)
        guard let playlist = try decoder.decode(RawPlaylist.self, from: data).normalized() else {
            throw SoundCloudError.invalidData
        }
        return playlist
    }

    func playlistTracks(
        urn: String,
        accessToken: String,
        pageURL: URL? = nil
    ) async throws -> SoundCloudTrackPage {
        let url = pageURL ?? configuration.apiBaseURL.appending(path: "playlists")
            .appending(path: urn).appending(path: "tracks")
            .appending(queryItems: [
                URLQueryItem(name: "linked_partitioning", value: "true"),
                URLQueryItem(name: "access", value: "playable,preview"),
            ])
        return try await trackPage(at: url, accessToken: accessToken)
    }

    private func trackPage(at url: URL, accessToken: String) async throws -> SoundCloudTrackPage {
        try validateAPIURL(url)
        let (data, response) = try await authenticatedRequest(url: url, accessToken: accessToken)
        try validate(response: response, data: data)
        let page = try decoder.decode(RawTrackPage.self, from: data)
        if let nextURL = page.nextURL {
            try validateAPIURL(nextURL)
            guard nextURL != url else { throw SoundCloudError.invalidData }
        }
        return SoundCloudTrackPage(
            tracks: page.collection.compactMap { $0.normalized() },
            nextURL: page.nextURL
        )
    }

    func setTrackLiked(
        urn: String,
        isLiked: Bool,
        accessToken: String
    ) async throws {
        let url = configuration.apiBaseURL
            .appending(path: "likes")
            .appending(path: "tracks")
            .appending(path: urn)
        let (data, response) = try await authenticatedRequest(
            url: url,
            accessToken: accessToken,
            method: isLiked ? "POST" : "DELETE"
        )
        try validate(response: response, data: data)
    }

    func track(
        urn: String,
        secretToken: String?,
        accessToken: String
    ) async throws -> SoundCloudTrackDetails {
        var components = URLComponents(
            url: configuration.apiBaseURL
                .appending(path: "tracks")
                .appending(path: urn),
            resolvingAgainstBaseURL: false
        )
        if let secretToken {
            components?.queryItems = [
                URLQueryItem(name: "secret_token", value: secretToken),
            ]
        }
        guard let url = components?.url else {
            throw SoundCloudError.unexpectedURL
        }
        let (data, response) = try await authenticatedRequest(
            url: url,
            accessToken: accessToken
        )
        try validate(response: response, data: data)
        guard let details = try decoder
            .decode(RawTrack.self, from: data)
            .normalizedDetails() else {
            throw SoundCloudError.invalidData
        }
        return details
    }

    func resolvePlayback(
        track: SoundCloudTrack,
        accessToken: String
    ) async throws -> PlaybackSource {
        var components = URLComponents(
            url: configuration.apiBaseURL
                .appending(path: "tracks")
                .appending(path: track.urn)
                .appending(path: "streams"),
            resolvingAgainstBaseURL: false
        )
        if let secretToken = track.secretToken {
            components?.queryItems = [
                URLQueryItem(name: "secret_token", value: secretToken),
            ]
        }
        guard let url = components?.url else {
            throw SoundCloudError.unexpectedURL
        }
        let (data, response) = try await authenticatedRequest(
            url: url,
            accessToken: accessToken
        )
        try validate(response: response, data: data)
        let streams = try decoder.decode(StreamResponse.self, from: data)
        let candidates: [(URL?, PlaybackSource.Kind, PlaybackSource.Codec, Int, Bool)] = [
            (streams.hlsAAC160URL, .hls, .aac, 160, false),
            (streams.hlsMP3128URL, .hls, .mp3, 128, false),
            (streams.previewMP3128URL, .mp3, .mp3, 128, true),
        ]

        for (streamURL, kind, codec, bitrate, isPreview) in candidates {
            guard let streamURL else { continue }
            do {
                let finalURL = try await streamRedirect(
                    streamURL,
                    accessToken: accessToken
                )
                return PlaybackSource(
                    url: finalURL,
                    kind: kind,
                    codec: codec,
                    bitrateKilobitsPerSecond: bitrate,
                    isPreview: isPreview
                )
            } catch SoundCloudError.unauthorized {
                throw SoundCloudError.unauthorized
            } catch SoundCloudError.rateLimited {
                throw SoundCloudError.rateLimited
            } catch SoundCloudError.network {
                throw SoundCloudError.network
            } catch {
                continue
            }
        }
        throw SoundCloudError.playbackUnavailable
    }

    func artworkData(from artworkURL: URL) async throws -> Data {
        try validateArtworkURL(artworkURL)
        var request = URLRequest(url: artworkURL)
        request.setValue("image/jpeg, image/png", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request, using: session)
        try validate(response: response, data: data)
        // Original uploads can be PNGs even when their thumbnails are JPEGs.
        guard let mimeType = response.mimeType?.lowercased(),
              ["image/jpeg", "image/png"].contains(mimeType),
              !data.isEmpty,
              data.count <= 10 * 1_024 * 1_024 else {
            throw SoundCloudError.invalidData
        }
        return data
    }

    func waveform(from waveformURL: URL) async throws -> SoundCloudWaveform {
        let jsonURL = try waveformJSONURL(from: waveformURL)
        var request = URLRequest(url: jsonURL)
        request.setValue(
            "application/json; charset=utf-8",
            forHTTPHeaderField: "Accept"
        )
        let (data, response) = try await send(request, using: session)
        try validate(response: response, data: data)
        guard response.mimeType?.lowercased() == "application/json",
              !data.isEmpty,
              data.count <= 1 * 1_024 * 1_024 else {
            throw SoundCloudError.invalidData
        }

        let waveform = try decoder.decode(SoundCloudWaveform.self, from: data)
        guard waveform.width > 0,
              waveform.height > 0,
              !waveform.samples.isEmpty,
              waveform.samples.count <= 10_000,
              waveform.samples.allSatisfy({ $0 >= 0 }) else {
            throw SoundCloudError.invalidData
        }
        return waveform
    }

    func signOut(accessToken: String) async throws {
        var request = URLRequest(url: configuration.signOutURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["access_token": accessToken]
        )
        let (data, response) = try await send(request, using: session)
        if response.statusCode == 401 { return }
        try validate(response: response, data: data)
    }

    private func tokenRequest(
        _ fields: [String: String],
        isRefresh: Bool
    ) async throws -> OAuthTokenResponse {
        var form = URLComponents()
        form.queryItems = fields.sorted(by: { $0.key < $1.key }).map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        var request = URLRequest(url: configuration.tokenURL)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            "application/json; charset=utf-8",
            forHTTPHeaderField: "Accept"
        )
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await send(request, using: session)
        if isRefresh,
           [400, 401, 403].contains(response.statusCode) {
            throw SoundCloudError.unauthorized
        }
        try validate(response: response, data: data)
        return try decoder.decode(OAuthTokenResponse.self, from: data)
    }

    private func authenticatedRequest(
        url: URL,
        accessToken: String,
        method: String = "GET"
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(
            "application/json; charset=utf-8",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            "OAuth \(accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        return try await send(request, using: session)
    }

    private func streamRedirect(
        _ streamURL: URL,
        accessToken: String
    ) async throws -> URL {
        try validateAPIURL(streamURL)
        var request = URLRequest(url: streamURL)
        request.httpMethod = "HEAD"
        request.setValue(
            "OAuth \(accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        let (data, response) = try await send(
            request,
            using: noRedirectSession
        )
        if response.statusCode == 401 { throw SoundCloudError.unauthorized }
        if response.statusCode == 429 { throw SoundCloudError.rateLimited }
        guard (300..<400).contains(response.statusCode),
              let location = response.value(forHTTPHeaderField: "Location"),
              let redirectURL = URL(string: location, relativeTo: streamURL)?.absoluteURL else {
            try validate(response: response, data: data)
            throw SoundCloudError.playbackUnavailable
        }
        try validatePlaybackURL(redirectURL)
        return redirectURL
    }

    private func send(
        _ request: URLRequest,
        using session: URLSession
    ) async throws -> (Data, HTTPURLResponse) {
        for attempt in 0..<3 {
            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw SoundCloudError.invalidResponse
                }
                if httpResponse.statusCode != 429 || attempt == 2 {
                    return (data, httpResponse)
                }
            } catch let error as SoundCloudError {
                throw error
            } catch {
                throw SoundCloudError.network
            }
            let delay = UInt64(250 * (1 << attempt))
            try await Task.sleep(for: .milliseconds(delay))
        }
        throw SoundCloudError.rateLimited
    }

    private func validate(
        response: HTTPURLResponse,
        data: Data
    ) throws {
        guard !(200..<300).contains(response.statusCode) else { return }
        if response.statusCode == 401 { throw SoundCloudError.unauthorized }
        if response.statusCode == 429 { throw SoundCloudError.rateLimited }
        let message = try? decoder.decode(APIErrorBody.self, from: data).message
        throw SoundCloudError.api(
            message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? message!
                : "SoundCloud returned HTTP \(response.statusCode)."
        )
    }

    private func validateAPIURL(_ url: URL) throws {
        guard url.scheme == "https", url.host == "api.soundcloud.com" else {
            throw SoundCloudError.unexpectedURL
        }
    }

    private func validatePlaybackURL(_ url: URL) throws {
        guard url.scheme == "https", let host = url.host else {
            throw SoundCloudError.unexpectedURL
        }
        let isAllowed = host == "sndcdn.com"
            || host.hasSuffix(".sndcdn.com")
            || host == "playback.media-streaming.soundcloud.cloud"
        guard isAllowed else { throw SoundCloudError.unexpectedURL }
    }

    private func validateArtworkURL(_ url: URL) throws {
        guard url.scheme == "https", let host = url.host?.lowercased() else {
            throw SoundCloudError.unexpectedURL
        }
        let isAllowed = host == "sndcdn.com" || host.hasSuffix(".sndcdn.com")
        guard isAllowed else { throw SoundCloudError.unexpectedURL }
    }

    private func waveformJSONURL(from url: URL) throws -> URL {
        guard url.scheme == "https",
              url.host?.lowercased() == "wave.sndcdn.com",
              var components = URLComponents(
                  url: url,
                  resolvingAgainstBaseURL: false
              ) else {
            throw SoundCloudError.unexpectedURL
        }

        let path = components.path as NSString
        let extensionName = path.pathExtension.lowercased()
        guard extensionName == "png" || extensionName == "json" else {
            throw SoundCloudError.unexpectedURL
        }
        components.path = path.deletingPathExtension + ".json"
        guard let jsonURL = components.url else {
            throw SoundCloudError.unexpectedURL
        }
        return jsonURL
    }
}

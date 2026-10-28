import Foundation

// SoundCloud's website API (api-v2). It is undocumented, so ./api.yaml does not describe it.
// Requests carry the website's public client ID and the signed-in user's website token.
struct SoundCloudConfiguration: Sendable {
    /// Pins the website client ID. When nil, the client discovers it from soundcloud.com.
    var clientID: String? = nil
    let apiBaseURL = URL(string: "https://api-v2.soundcloud.com/")!
    let websiteURL = URL(string: "https://soundcloud.com/")!
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
            return "SoundClaude could not find SoundCloud’s website client ID. Try again later."
        case .invalidResponse, .invalidData:
            return "SoundCloud returned invalid data"
        case .unauthorized:
            return "The SoundCloud session has expired."
        case .rateLimited:
            return "SoundCloud is rate limiting requests. Wait and try again."
        case let .api(message):
            return message
        case .playbackUnavailable:
            return "This track has no supported stream. It may require SoundCloud’s own player."
        case .unexpectedURL:
            return "SoundCloud returned an unexpected URL"
        case .network:
            return "SoundCloud could not be reached. Check the network connection."
        }
    }
}

// Website tokens must not follow redirects to other hosts.
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

/// Sends an api-v2 request from a soundcloud.com page rather than URLSession.
typealias SoundCloudWebsiteTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

actor SoundCloudClient {
    private static let likedTracksPageSize = 25
    private static let clientIDDefaultsKey = "SoundCloudWebsiteClientID"
    private static let trackBatchSize = 50

    private let configuration: SoundCloudConfiguration
    private let session: URLSession
    private let websiteTransport: SoundCloudWebsiteTransport?
    private let decoder = JSONDecoder()
    private var clientID: String?
    private var clientIDTask: Task<String, Error>?
    private var currentUserID: (accessToken: String, id: String)?

    init(
        configuration: SoundCloudConfiguration,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        websiteTransport: SoundCloudWebsiteTransport? = nil
    ) {
        self.configuration = configuration
        self.websiteTransport = websiteTransport
        clientID = configuration.clientID
            ?? UserDefaults.standard.string(forKey: Self.clientIDDefaultsKey)

        sessionConfiguration.timeoutIntervalForRequest = 30
        sessionConfiguration.timeoutIntervalForResource = 60
        sessionConfiguration.httpCookieStorage = nil
        session = URLSession(
            configuration: sessionConfiguration,
            delegate: RedirectBlocker(),
            delegateQueue: nil
        )
    }

    func currentUser(accessToken: String) async throws -> SoundCloudUser {
        let user = try await get(RawUser.self, endpoint("me"), accessToken: accessToken)
        guard let normalized = user.normalized(), let urn = normalized.urn else {
            throw SoundCloudError.invalidData
        }
        currentUserID = (accessToken, try Self.id(urn))
        return normalized
    }

    func feed(accessToken: String, pageURL: URL? = nil) async throws -> SoundCloudFeedPage {
        let url = pageURL ?? endpoint("stream", query: ["limit": "10"])
        let page = try await get(RawFeedPage.self, url, accessToken: accessToken)
        try validateNextURL(page.nextURL, after: url)
        let items = page.collection.compactMap { activity -> SoundCloudFeedItem? in
            guard let content = activity.content, let createdAt = activity.createdAt,
                  let user = activity.isRepost ? activity.user : content.owner else { return nil }
            return SoundCloudFeedItem(
                content: content, user: user, isRepost: activity.isRepost, createdAt: createdAt
            )
        }
        return SoundCloudFeedPage(items: items, nextURL: page.nextURL)
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
            let userID = try await myID(accessToken: accessToken)
            url = endpoint("users/\(userID)/track_likes", query: [
                "limit": String(pageSize ?? Self.likedTracksPageSize),
            ])
        }
        return try await trackPage(at: url, accessToken: accessToken)
    }

    func artist(
        _ artist: SoundCloudUser,
        accessToken: String
    ) async throws -> SoundCloudArtistDetails {
        if let urn = artist.urn {
            return try await self.artist(urn: urn, accessToken: accessToken)
        }
        // Older or partial user objects can still be opened by permalink.
        let url = endpoint("resolve", query: ["url": artist.permalinkURL.absoluteString])
        guard let details = try await get(RawUser.self, url, accessToken: accessToken)
            .normalizedArtistDetails() else {
            throw SoundCloudError.invalidData
        }
        return details
    }

    func artist(urn: String, accessToken: String) async throws -> SoundCloudArtistDetails {
        let url = endpoint("users/\(try Self.id(urn))")
        guard let details = try await get(RawUser.self, url, accessToken: accessToken)
            .normalizedArtistDetails() else {
            throw SoundCloudError.invalidData
        }
        return details
    }

    func artistWebProfiles(urn: String, accessToken: String) async throws -> [SoundCloudWebProfile] {
        let url = endpoint("users/\(urn)/web-profiles")
        var seen: Set<URL> = []
        return try await get([RawWebProfile].self, url, accessToken: accessToken)
            .compactMap { $0.normalized() }
            .filter { seen.insert($0.url).inserted }
    }

    func relatedArtists(urn: String, accessToken: String) async throws -> [SoundCloudUser] {
        let url = endpoint("users/\(try Self.id(urn))/relatedartists", query: ["limit": "12"])
        let page = try await get(RawUserPage.self, url, accessToken: accessToken)
        var seen: Set<URL> = []
        return Array(page.collection.compactMap { $0.normalized() }
            .filter { $0.urn != urn && seen.insert($0.permalinkURL).inserted }
            .prefix(12))
    }

    func followedArtistURNs(accessToken: String) async throws -> Set<String> {
        let userID = try await myID(accessToken: accessToken)
        var nextURL: URL? = endpoint("users/\(userID)/followings", query: ["limit": "200"])
        var visited: Set<URL> = []
        var urns: Set<String> = []
        while let url = nextURL {
            try Task.checkCancellation()
            guard visited.insert(url).inserted else { throw SoundCloudError.invalidData }
            let page = try await get(RawUserPage.self, url, accessToken: accessToken)
            for user in page.collection {
                guard let urn = user.urn else { throw SoundCloudError.invalidData }
                urns.insert(urn)
            }
            nextURL = page.nextURL
        }
        return urns
    }

    func setArtistFollowed(urn: String, isFollowed: Bool, accessToken: String) async throws {
        try await send(
            isFollowed ? "POST" : "DELETE",
            endpoint("me/followings/\(try Self.id(urn))"),
            accessToken: accessToken
        )
    }

    func artistHeaderURL(for artist: SoundCloudUser) async throws -> URL? {
        guard let url = SoundCloudProfileHeader.profileURL(artist.permalinkURL)
        else { throw SoundCloudError.unexpectedURL }
        // Public HTML only: do not attach the website token.
        let request = URLRequest(url: url, timeoutInterval: 8)
        let (data, response) = try await perform(request)
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { throw SoundCloudError.invalidData }
        return SoundCloudProfileHeader.imageURL(in: html, for: artist)
    }

    func artistUsers(
        urn: String,
        list: ArtistUserList,
        accessToken: String,
        pageURL: URL? = nil
    ) async throws -> SoundCloudUserPage {
        let url = try pageURL ?? endpoint(
            "users/\(try Self.id(urn))/\(list.rawValue)", query: ["limit": "50"]
        )
        return try await userPage(at: url, accessToken: accessToken)
    }

    func searchTracks(
        query: String? = nil, genres: String? = nil, tags: String? = nil,
        accessToken: String, pageURL: URL? = nil
    ) async throws -> SoundCloudTrackPage {
        // The genre/tag filter only matches lowercase values; "House" returns nothing.
        let url = pageURL ?? searchURL(path: "tracks", query: query ?? "*", extra: [
            "filter.genre_or_tag": (genres ?? tags)?.lowercased(),
        ])
        return try await trackPage(at: url, accessToken: accessToken)
    }

    func searchPlaylists(
        query: String, accessToken: String, pageURL: URL? = nil
    ) async throws -> SoundCloudPlaylistPage {
        let url = pageURL ?? searchURL(path: "playlists_without_albums", query: query)
        return try await playlistPage(at: url, accessToken: accessToken)
    }

    func searchUsers(
        query: String, accessToken: String, pageURL: URL? = nil
    ) async throws -> SoundCloudUserPage {
        let url = pageURL ?? searchURL(path: "users", query: query)
        return try await userPage(at: url, accessToken: accessToken)
    }

    private func searchURL(path: String, query: String, extra: [String: String?] = [:]) -> URL {
        endpoint("search/\(path)", query: ["q": query, "limit": "25"].merging(extra) { $1 })
    }

    func artistTracks(
        urn: String,
        accessToken: String,
        pageURL: URL? = nil
    ) async throws -> SoundCloudTrackPage {
        let url = try pageURL ?? endpoint("users/\(try Self.id(urn))/tracks", query: ["limit": "25"])
        return try await trackPage(at: url, accessToken: accessToken)
    }

    /// Reposts mix tracks and playlists; this page keeps only the tracks.
    func artistReposts(
        urn: String,
        accessToken: String,
        pageURL: URL? = nil
    ) async throws -> SoundCloudTrackPage {
        let url = try pageURL ?? endpoint(
            "stream/users/\(try Self.id(urn))/reposts", query: ["limit": "25"]
        )
        return try await trackPage(at: url, accessToken: accessToken)
    }

    /// Reposts mix tracks and playlists; this page keeps only the playlists.
    func artistPlaylistReposts(
        urn: String,
        accessToken: String,
        pageURL: URL? = nil
    ) async throws -> SoundCloudPlaylistPage {
        let url = try pageURL ?? endpoint(
            "stream/users/\(try Self.id(urn))/reposts", query: ["limit": "25"]
        )
        return try await playlistPage(at: url, accessToken: accessToken)
    }

    func artistPlaylistLikes(
        urn: String,
        accessToken: String,
        pageURL: URL? = nil
    ) async throws -> SoundCloudPlaylistPage {
        let url = try pageURL ?? endpoint(
            "users/\(try Self.id(urn))/playlist_likes", query: ["limit": "25"]
        )
        return try await playlistPage(at: url, accessToken: accessToken)
    }

    func artistLikes(
        urn: String,
        accessToken: String,
        pageURL: URL? = nil
    ) async throws -> SoundCloudTrackPage {
        let url = try pageURL ?? endpoint(
            "users/\(try Self.id(urn))/track_likes", query: ["limit": "25"]
        )
        return try await trackPage(at: url, accessToken: accessToken)
    }

    func artistPlaylists(
        urn: String,
        accessToken: String,
        pageURL: URL? = nil
    ) async throws -> SoundCloudPlaylistPage {
        let url = try pageURL ?? endpoint(
            "users/\(try Self.id(urn))/playlists_without_albums", query: ["limit": "25"]
        )
        return try await playlistPage(at: url, accessToken: accessToken)
    }

    func relatedTracks(
        urn: String,
        accessToken: String,
        pageURL: URL? = nil
    ) async throws -> SoundCloudTrackPage {
        let url = try pageURL ?? endpoint("tracks/\(try Self.id(urn))/related", query: ["limit": "10"])
        return try await trackPage(at: url, accessToken: accessToken)
    }

    func playlists(accessToken: String, pageURL: URL? = nil) async throws
        -> SoundCloudPlaylistPage {
        let userID = try await myID(accessToken: accessToken)
        let url = pageURL ?? endpoint(
            "users/\(userID)/playlists_without_albums", query: ["limit": "200"]
        )
        return try await playlistPage(at: url, accessToken: accessToken)
    }

    // Artwork upload is not ported.
    func createPlaylist(
        title: String, description: String, isPrivate: Bool,
        artwork: PlaylistArtwork? = nil, accessToken: String
    ) async throws -> SoundCloudPlaylist {
        guard artwork == nil else {
            throw SoundCloudError.api("Playlist artwork upload is not supported yet. Create the playlist without artwork.")
        }
        let data = try await send("POST", endpoint("playlists"), accessToken: accessToken, json: [
            "playlist": ["title": title, "description": description,
                         "sharing": isPrivate ? "private" : "public", "tracks": [Int]()],
        ])
        guard let playlist = try decoder.decode(RawPlaylist.self, from: data).normalized() else {
            throw SoundCloudError.invalidData
        }
        return playlist
    }

    func updatePlaylist(
        urn: String, title: String, description: String, isPrivate: Bool, accessToken: String
    ) async throws -> SoundCloudPlaylist {
        // Omit tracks so metadata edits preserve every track and its order.
        let data = try await send(
            "PUT", endpoint("playlists/\(try Self.id(urn))"), accessToken: accessToken,
            json: ["playlist": ["title": title, "description": description,
                                "sharing": isPrivate ? "private" : "public"]]
        )
        // The reply can omit the owner and permalink; load the full playlist when it does.
        var playlist = try? decoder.decode(RawPlaylist.self, from: data).normalized()
        if playlist == nil {
            playlist = try await self.playlist(urn: urn, accessToken: accessToken)
        }
        guard let playlist, playlist.urn == urn else { throw SoundCloudError.invalidData }
        return playlist
    }

    func addTrackToPlaylist(trackURN: String, playlistURN: String, accessToken: String) async throws {
        try await updatePlaylistTrack(trackURN: trackURN, playlistURN: playlistURN,
                                      removing: false, accessToken: accessToken)
    }

    func removeTrackFromPlaylist(trackURN: String, playlistURN: String, accessToken: String) async throws {
        try await updatePlaylistTrack(trackURN: trackURN, playlistURN: playlistURN,
                                      removing: true, accessToken: accessToken)
    }

    // Mirrors the website, which replaces the whole track list.
    private func updatePlaylistTrack(
        trackURN: String, playlistURN: String, removing: Bool, accessToken: String
    ) async throws {
        let playlistURL = endpoint("playlists/\(try Self.id(playlistURN))")
        let trackID = Int(try Self.id(trackURN))!
        var trackIDs = try await get(RawPlaylistTracks.self, playlistURL, accessToken: accessToken)
            .tracks.map { track in
                guard let id = track.id else { throw SoundCloudError.invalidData }
                return id
            }
        if removing {
            guard trackIDs.contains(trackID) else { return }
            trackIDs.removeAll { $0 == trackID }
        } else {
            guard !trackIDs.contains(trackID) else { return }
            trackIDs.append(trackID)
        }
        try await send("PUT", playlistURL, accessToken: accessToken,
                       json: ["playlist": ["tracks": trackIDs]])
    }

    func deletePlaylist(urn: String, accessToken: String) async throws {
        try await send("DELETE", endpoint("playlists/\(try Self.id(urn))"), accessToken: accessToken)
    }

    func stationTracks(urn: String, accessToken: String) async throws -> [SoundCloudTrack] {
        try await station(urn: urn, accessToken: accessToken).tracks
    }

    func station(
        urn: String, accessToken: String,
        onProgress: (@Sendable (SoundCloudStation) async -> Void)? = nil
    ) async throws -> SoundCloudStation {
        let metadata = try await stationMetadata(urn: urn, accessToken: accessToken)
        return try await hydrateStation(metadata, accessToken: accessToken, onProgress: onProgress)
    }

    // Fetch only the station response. Leave ID-only tracks for hover or navigation.
    func stationMetadata(urn: String, accessToken: String) async throws -> RawSystemPlaylist {
        try await get(
            RawSystemPlaylist.self, endpoint("system-playlists/\(urn)"), accessToken: accessToken
        )
    }

    func hydrateStation(
        _ station: RawSystemPlaylist, accessToken: String,
        onProgress: (@Sendable (SoundCloudStation) async -> Void)? = nil
    ) async throws -> SoundCloudStation {
        return station.normalized(
            tracks: try await hydrated(station.tracks, accessToken: accessToken) { tracks in
                await onProgress?(station.normalized(tracks: tracks))
            }
        )
    }

    func playlist(urn: String, accessToken: String) async throws -> SoundCloudPlaylist {
        let url = endpoint("playlists/\(try Self.id(urn))")
        guard let playlist = try await get(RawPlaylist.self, url, accessToken: accessToken)
            .normalized() else {
            throw SoundCloudError.invalidData
        }
        return playlist
    }

    /// api-v2 returns a playlist's tracks with the playlist, so this always returns one page.
    func playlistTracks(
        urn: String,
        accessToken: String,
        pageURL: URL? = nil
    ) async throws -> SoundCloudTrackPage {
        guard pageURL == nil else { return SoundCloudTrackPage(tracks: [], nextURL: nil) }
        let playlist = try await get(
            RawPlaylistTracks.self, endpoint("playlists/\(try Self.id(urn))"),
            accessToken: accessToken
        )
        return SoundCloudTrackPage(
            tracks: try await hydrated(playlist.tracks, accessToken: accessToken), nextURL: nil
        )
    }

    func likedPlaylists(accessToken: String, pageURL: URL? = nil) async throws -> SoundCloudPlaylistPage {
        let userID = try await myID(accessToken: accessToken)
        let url = pageURL ?? endpoint("users/\(userID)/playlist_likes", query: ["limit": "200"])
        return try await playlistPage(at: url, accessToken: accessToken)
    }

    /// Station likes appear among the library's playlist entries.
    func likedStations(accessToken: String, pageURL: URL? = nil) async throws -> SoundCloudStationLikePage {
        struct Page: Decodable {
            struct Entry: Decodable {
                let type: String
                let system_playlist: SoundCloudStationLikePage.Station?
            }
            let collection: [Entry]
            let next_href: URL?
        }
        let url = pageURL ?? endpoint("me/library/all", query: ["limit": "200"])
        let page = try await get(Page.self, url, accessToken: accessToken)
        try validateNextURL(page.next_href, after: url)
        return SoundCloudStationLikePage(
            collection: page.collection.compactMap {
                $0.type == "system-playlist-like" ? $0.system_playlist : nil
            },
            nextURL: page.next_href
        )
    }

    func setPlaylistLiked(urn: String, isLiked: Bool, accessToken: String) async throws {
        let userID = try await myID(accessToken: accessToken)
        try await send(
            isLiked ? "PUT" : "DELETE",
            endpoint("users/\(userID)/playlist_likes/\(try Self.id(urn))"),
            accessToken: accessToken
        )
    }

    func repostedTracks(accessToken: String, pageURL: URL? = nil) async throws -> SoundCloudTrackPage {
        let userID = try await myID(accessToken: accessToken)
        let url = pageURL ?? endpoint("stream/users/\(userID)/reposts", query: ["limit": "200"])
        return try await trackPage(at: url, accessToken: accessToken)
    }

    func setTrackReposted(urn: String, isReposted: Bool, accessToken: String) async throws {
        try await send(
            isReposted ? "PUT" : "DELETE",
            endpoint("me/track_reposts/\(try Self.id(urn))"),
            accessToken: accessToken
        )
    }

    func setTrackLiked(
        urn: String,
        isLiked: Bool,
        accessToken: String
    ) async throws {
        let userID = try await myID(accessToken: accessToken)
        try await send(
            isLiked ? "PUT" : "DELETE",
            endpoint("users/\(userID)/track_likes/\(try Self.id(urn))"),
            accessToken: accessToken
        )
    }

    // The website posts comments as form fields, not JSON.
    func addTrackComment(
        urn: String,
        body: String,
        timestampMilliseconds: Int? = nil,
        accessToken: String
    ) async throws -> SoundCloudComment {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SoundCloudError.api("Enter a comment before posting.")
        }
        var fields = [("body", body)]
        if let timestampMilliseconds {
            fields.append(("timestamp", String(timestampMilliseconds)))
        }
        let data = try await send(
            "POST", endpoint("tracks/\(try Self.id(urn))/comments"),
            accessToken: accessToken, form: fields
        )
        return try decoder.decode(SoundCloudComment.self, from: data)
    }

    func trackComments(
        urn: String,
        secretToken: String? = nil,
        accessToken: String,
        pageURL: URL? = nil,
        limit: Int = 50
    ) async throws -> SoundCloudCommentPage {
        let url = try pageURL ?? endpoint("tracks/\(try Self.id(urn))/comments", query: [
            "threaded": "0",
            "filter_replies": "0",
            "limit": String(limit),
            "secret_token": secretToken,
        ])
        let page = try await get(SoundCloudCommentPage.self, url, accessToken: accessToken)
        try validateNextURL(page.nextURL, after: url)
        return page
    }

    func track(
        urn: String,
        secretToken: String?,
        accessToken: String
    ) async throws -> SoundCloudTrackDetails {
        let url = endpoint("tracks/\(try Self.id(urn))", query: ["secret_token": secretToken])
        guard let details = try await get(RawTrack.self, url, accessToken: accessToken)
            .normalizedDetails() else {
            throw SoundCloudError.invalidData
        }
        return details
    }

    func resolvePlayback(
        track: SoundCloudTrack,
        accessToken: String
    ) async throws -> PlaybackSource {
        // Track authorizations expire, so always fetch them with a fresh track.
        let trackURL = endpoint(
            "tracks/\(try Self.id(track.urn))", query: ["secret_token": track.secretToken]
        )
        let streams = try await get(StreamResponse.self, trackURL, accessToken: accessToken)
        struct Stream: Decodable { let url: URL }

        for (transcoding, source) in streams.candidates {
            do {
                try validateAPIURL(transcoding.url)
                var url = transcoding.url
                if let authorization = streams.trackAuthorization {
                    url = url.appending(queryItems: [
                        URLQueryItem(name: "track_authorization", value: authorization),
                    ])
                }
                let stream = try await get(Stream.self, url, accessToken: accessToken)
                try validatePlaybackURL(stream.url)
                return PlaybackSource(
                    url: stream.url,
                    kind: source.kind,
                    codec: source.codec,
                    bitrateKilobitsPerSecond: source.bitrateKilobitsPerSecond,
                    isPreview: source.isPreview
                )
            } catch SoundCloudError.unauthorized {
                throw SoundCloudError.unauthorized
            } catch SoundCloudError.rateLimited {
                throw SoundCloudError.rateLimited
            } catch SoundCloudError.network {
                throw SoundCloudError.network
            } catch is CancellationError {
                throw CancellationError()
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
        let (data, response) = try await send(request)
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
        let (data, response) = try await send(request)
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

    // MARK: - Website client ID

    /// Finds the client ID that soundcloud.com's own scripts use.
    func discoverClientID() async throws -> String {
        var request = URLRequest(url: configuration.websiteURL)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let html = try await text(request)
        let scripts = Self.matches(
            #"<script[^>]+src="(https://[a-zA-Z0-9-]+\.sndcdn\.com/[^"]+\.js)""#, in: html
        )
        // The ID is defined in one of the last bundles.
        for script in scripts.reversed() {
            try Task.checkCancellation()
            guard let url = URL(string: script) else { continue }
            do {
                if let id = Self.matches(
                    #"client_id\s*[:=]\s*"([a-zA-Z0-9]{32})""#, in: try await text(URLRequest(url: url))
                ).first {
                    return id
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        throw SoundCloudError.configuration
    }

    private func currentClientID() async throws -> String {
        if let clientID { return clientID }
        return try await refreshClientID()
    }

    private func refreshClientID() async throws -> String {
        if let clientIDTask { return try await clientIDTask.value }
        let task = Task { try await discoverClientID() }
        clientIDTask = task
        defer { clientIDTask = nil }
        let id = try await task.value
        clientID = id
        UserDefaults.standard.set(id, forKey: Self.clientIDDefaultsKey)
        return id
    }

    private func text(_ request: URLRequest) async throws -> String {
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else { throw SoundCloudError.invalidResponse }
        return String(decoding: data, as: UTF8.self)
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let string = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: string.length)).map {
            string.substring(with: $0.range(at: 1))
        }
    }

    // MARK: - Requests

    /// Encodes fields like jQuery's $.param, which the website uses for form posts.
    private static func formEncoded(_ fields: [(String, String)]) -> String {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
        )
        func encode(_ text: String) -> String {
            text.addingPercentEncoding(withAllowedCharacters: unreserved)!
                .replacingOccurrences(of: "%20", with: "+")
        }
        return fields.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }

    /// api-v2 paths take numeric IDs, while app models keep URNs.
    private static func id(_ urn: String) throws -> String {
        let id = urn.split(separator: ":").last.map(String.init) ?? ""
        guard !id.isEmpty, id.allSatisfy(\.isASCII), id.allSatisfy(\.isNumber) else {
            throw SoundCloudError.unexpectedURL
        }
        return id
    }

    private func myID(accessToken: String) async throws -> String {
        if let currentUserID, currentUserID.accessToken == accessToken {
            return currentUserID.id
        }
        _ = try await currentUser(accessToken: accessToken)
        return currentUserID!.id
    }

    private func endpoint(_ path: String, query: [String: String?] = [:]) -> URL {
        var items = query.compactMap { name, value in
            value.map { URLQueryItem(name: name, value: $0) }
        }.sorted { $0.name < $1.name }
        // Paged endpoints take a limit; linked partitioning makes them return next_href.
        if query["limit"] != nil {
            items.append(URLQueryItem(name: "linked_partitioning", value: "1"))
        }
        return configuration.apiBaseURL.appending(path: path).appending(queryItems: items)
    }

    private func get<T: Decodable>(_ type: T.Type, _ url: URL, accessToken: String) async throws -> T {
        let (data, response) = try await authenticatedRequest(url: url, accessToken: accessToken)
        try validate(response: response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    @discardableResult
    private func send(
        _ method: String, _ url: URL, accessToken: String,
        json: [String: Any]? = nil, form: [(String, String)]? = nil
    ) async throws -> Data {
        var body: (data: Data, type: String)?
        if let json {
            body = (try JSONSerialization.data(withJSONObject: json), "application/json; charset=utf-8")
        } else if let form {
            body = (Data(Self.formEncoded(form).utf8), "application/x-www-form-urlencoded; charset=UTF-8")
        }
        let (data, response) = try await authenticatedRequest(
            url: url, accessToken: accessToken, method: method, body: body
        )
        try validate(response: response, data: data)
        return data
    }

    private func trackPage(at url: URL, accessToken: String) async throws -> SoundCloudTrackPage {
        let page = try await get(RawTrackPage.self, url, accessToken: accessToken)
        try validateNextURL(page.nextURL, after: url)
        return SoundCloudTrackPage(
            tracks: page.collection.compactMap { $0.normalized() },
            nextURL: page.nextURL
        )
    }

    private func playlistPage(at url: URL, accessToken: String) async throws -> SoundCloudPlaylistPage {
        let page = try await get(RawPlaylistPage.self, url, accessToken: accessToken)
        try validateNextURL(page.nextURL, after: url)
        return SoundCloudPlaylistPage(
            playlists: page.collection.compactMap { $0.normalized() },
            nextURL: page.nextURL
        )
    }

    private func userPage(at url: URL, accessToken: String) async throws -> SoundCloudUserPage {
        let page = try await get(RawUserPage.self, url, accessToken: accessToken)
        try validateNextURL(page.nextURL, after: url)
        return SoundCloudUserPage(
            users: page.collection.compactMap { $0.normalized() }, nextURL: page.nextURL
        )
    }

    /// Playlists and stations list later tracks as ID-only stubs.
    private func hydrated(
        _ tracks: [RawTrack], accessToken: String,
        onProgress: (@Sendable ([SoundCloudTrack]) async -> Void)? = nil
    ) async throws -> [SoundCloudTrack] {
        let missing = tracks.filter { $0.title == nil }.compactMap(\.id)
        var loaded: [Int: RawTrack] = [:]
        func normalized() -> [SoundCloudTrack] {
            tracks.compactMap { track in
                (track.title == nil ? track.id.flatMap { loaded[$0] } : track)?.normalized()
            }
        }
        await onProgress?(normalized())
        for start in stride(from: 0, to: missing.count, by: Self.trackBatchSize) {
            try Task.checkCancellation()
            let batch = missing[start..<min(start + Self.trackBatchSize, missing.count)]
            let url = endpoint("tracks", query: ["ids": batch.map(String.init).joined(separator: ",")])
            for track in try await get([RawTrack].self, url, accessToken: accessToken) {
                if let id = track.id { loaded[id] = track }
            }
            try Task.checkCancellation()
            await onProgress?(normalized())
        }
        return normalized()
    }

    private func authenticatedRequest(
        url: URL,
        accessToken: String,
        method: String = "GET",
        body: (data: Data, type: String)? = nil,
        isRetry: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        try validateAPIURL(url)
        let clientID = try await currentClientID()
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw SoundCloudError.unexpectedURL
        }
        var queryItems = (components.queryItems ?? []).filter { $0.name != "client_id" }
        queryItems.append(URLQueryItem(name: "client_id", value: clientID))
        components.queryItems = queryItems
        guard let requestURL = components.url else { throw SoundCloudError.unexpectedURL }

        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        if let body {
            request.httpBody = body.data
            request.setValue(body.type, forHTTPHeaderField: "Content-Type")
        }
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Accept")
        request.setValue("OAuth \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("https://soundcloud.com", forHTTPHeaderField: "Origin")
        request.setValue("https://soundcloud.com/", forHTTPHeaderField: "Referer")
        // DataDome blocks api-v2 writes that don't come from a soundcloud.com page.
        let (data, response) = if method != "GET", let websiteTransport {
            try await websiteTransport(request)
        } else {
            try await send(request)
        }

        // SoundCloud rotates the website client ID; retry once with a fresh one.
        if [401, 403].contains(response.statusCode), !isRetry, configuration.clientID == nil,
           try await refreshClientID() != clientID {
            return try await authenticatedRequest(
                url: url, accessToken: accessToken, method: method, body: body, isRetry: true
            )
        }
        return (data, response)
    }

    private func perform(_ request: URLRequest, attempt: Int = 1) async throws -> (Data, URLResponse) {
        #if DEBUG
        let start = ProcessInfo.processInfo.systemUptime
        let started = Date()
        let id = await NetworkActivityStore.shared.begin(request, attempt: attempt, started: started, uptime: start)
        do {
            let (data, response) = try await session.data(for: request)
            await NetworkActivityStore.shared.finish(
                id, response: response, bytes: data.count,
                duration: ProcessInfo.processInfo.systemUptime - start, error: nil
            )
            return (data, response)
        } catch {
            // Localized error strings can include signed URLs. Retain only the numeric code.
            let code = (error as NSError).code
            await NetworkActivityStore.shared.finish(
                id, response: nil, bytes: 0,
                duration: ProcessInfo.processInfo.systemUptime - start,
                error: "Error \(code)"
            )
            throw error
        }
        #else
        return try await session.data(for: request)
        #endif
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        for attempt in 0..<3 {
            do {
                let (data, response) = try await perform(request, attempt: attempt + 1)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw SoundCloudError.invalidResponse
                }
                if httpResponse.statusCode != 429 || attempt == 2 {
                    return (data, httpResponse)
                }
            } catch let error as SoundCloudError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
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
                : "SoundCloud returned HTTP \(response.statusCode) (\(HTTPURLResponse.localizedString(forStatusCode: response.statusCode).capitalized))"
        )
    }

    private func validateNextURL(_ nextURL: URL?, after url: URL) throws {
        guard let nextURL else { return }
        try validateAPIURL(nextURL)
        guard nextURL != url else { throw SoundCloudError.invalidData }
    }

    private func validateAPIURL(_ url: URL) throws {
        guard url.scheme == "https", url.host == configuration.apiBaseURL.host,
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else {
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

/// A playlist's track list, where later entries are ID-only stubs.
private struct RawPlaylistTracks: Decodable {
    let tracks: [RawTrack]
}

import Foundation

struct SoundCloudUser: Codable, Sendable, Hashable {
    let urn: String?
    let username: String
    let avatarURL: URL?
    let permalinkURL: URL
    var followersCount: Int? = nil
    var fullName: String? = nil
    var trackCount: Int? = nil
    var repostsCount: Int? = nil
    var playlistCount: Int? = nil
    var publicFavoritesCount: Int? = nil
    var stationURN: String? = nil

    enum CodingKeys: String, CodingKey {
        case urn
        case username
        case avatarURL = "avatar_url"
        case permalinkURL = "permalink_url"
        case fullName = "full_name"
        case followersCount = "followers_count"
        case trackCount = "track_count"
        case repostsCount = "reposts_count"
        case playlistCount = "playlist_count"
        case publicFavoritesCount = "public_favorites_count"
        case stationURN = "station_urn"
    }
}

enum ArtistUserList: String, Codable, Sendable, Hashable, CaseIterable {
    case followers
    case following = "followings"

    var title: String {
        switch self {
        case .followers: "Followers"
        case .following: "Following"
        }
    }
}

struct SoundCloudUserPage: Sendable {
    let users: [SoundCloudUser]
    let nextURL: URL?
}

struct RawUserPage: Decodable {
    let collection: [RawUser]
    let nextURL: URL?

    enum CodingKeys: String, CodingKey {
        case collection
        case nextURL = "next_href"
    }
}

struct SoundCloudWebProfile: Sendable, Identifiable {
    let url: URL
    let title: String
    let service: String

    var id: URL { url }

    var iconAsset: String? {
        switch service {
        case "facebook", "youtube", "spotify", "twitter", "bandcamp", "instagram", "tumblr": "Profile-\(service)"
        default: nil
        }
    }
}

struct RawWebProfile: Decodable {
    let url: String?
    let title: String?
    let service: String?
    var network: String? = nil

    func normalized() -> SoundCloudWebProfile? {
        guard let rawURL = url?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: rawURL),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        let service = (service ?? network)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let serviceName = switch service {
        case "youtube": "YouTube"
        case "facebook": "Facebook"
        case "spotify": "Spotify"
        case "instagram": "Instagram"
        case "twitter": "Twitter"
        case "tiktok": "TikTok"
        case "bandcamp": "Bandcamp"
        case "", "personal", "website": host
        default: service.capitalized
        }
        return SoundCloudWebProfile(url: url, title: title.isEmpty ? serviceName : title, service: service)
    }
}

struct SoundCloudArtistDetails: Sendable {
    let user: SoundCloudUser
    let description: String?
    let city: String?
    let country: String?
    let followersCount: Int?
    let followingsCount: Int?
    let trackCount: Int?
}

struct SoundCloudTrack: Codable, Identifiable, Sendable, Hashable {
    let urn: String
    let title: String
    let artist: SoundCloudUser
    let artworkURL: URL?
    let waveformURL: URL?
    let permalinkURL: URL
    let durationMilliseconds: Int
    let access: Access
    let secretToken: String?
    var likesCount: Int? = nil
    var repostsCount: Int? = nil
    var commentCount: Int? = nil
    var genre: String? = nil
    var createdAt: String? = nil
    var stationURN: String? = nil

    var id: String { urn }
    var uploader: String { artist.username }
    var displayArtworkURL: URL? { artworkURL ?? artist.avatarURL }

    enum Access: String, Codable, Sendable {
        case playable
        case preview
        case blocked

        /// Maps api-v2 track policies. MONETIZE tracks play in full with ads on the website.
        init?(policy: String) {
            switch policy {
            case "ALLOW", "MONETIZE": self = .playable
            case "SNIP": self = .preview
            case "BLOCK": self = .blocked
            default: return nil
            }
        }
    }
}

extension Array where Element == SoundCloudTrack {
    func filtered(by searchText: String) -> [SoundCloudTrack] {
        // Normalize styled Unicode letters to their plain equivalents for matching.
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCompatibilityMapping
        guard !query.isEmpty else { return self }
        return filter {
            $0.title.precomposedStringWithCompatibilityMapping.localizedStandardContains(query)
                || $0.artist.username.precomposedStringWithCompatibilityMapping.localizedStandardContains(query)
        }
    }
}

struct SoundCloudTrackPage: Sendable {
    let tracks: [SoundCloudTrack]
    let nextURL: URL?
}

enum SoundCloudFeedContent: Codable, Sendable {
    case track(SoundCloudTrack)
    case playlist(SoundCloudPlaylist)

    var urn: String {
        switch self {
        case let .track(track): track.urn
        case let .playlist(playlist): playlist.urn
        }
    }

    /// Repost endpoints expose content creation time, not the time it was reposted.
    static func sortedByCreationDate(_ contents: [Self]) -> [Self] {
        let iso = ISO8601DateFormatter()
        let legacy = DateFormatter()
        legacy.locale = Locale(identifier: "en_US_POSIX")
        legacy.timeZone = TimeZone(secondsFromGMT: 0)
        legacy.dateFormat = "yyyy/MM/dd HH:mm:ss Z"

        func date(for content: Self) -> Date {
            let timestamp: String?
            switch content {
            case let .track(track): timestamp = track.createdAt
            case let .playlist(playlist): timestamp = playlist.createdAt
            }
            guard let timestamp else { return .distantPast }
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: timestamp) { return date }
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: timestamp) ?? legacy.date(from: timestamp) ?? .distantPast
        }

        return contents.map { (content: $0, date: date(for: $0)) }
            .sorted {
                if $0.date != $1.date { return $0.date > $1.date }
                return $0.content.urn < $1.content.urn
            }
            .map(\.content)
    }

    var owner: SoundCloudUser {
        switch self {
        case let .track(track): track.artist
        case let .playlist(playlist): playlist.owner
        }
    }

    var track: SoundCloudTrack? {
        guard case let .track(track) = self else { return nil }
        return track
    }
}

struct SoundCloudFeedItem: Codable, Identifiable, Sendable {
    let content: SoundCloudFeedContent
    let user: SoundCloudUser
    let isRepost: Bool
    let createdAt: Date

    // Content can appear more than once when different users repost it.
    var id: String {
        "\(content.urn)|\(user.urn ?? user.permalinkURL.absoluteString)|\(isRepost)|\(createdAt.timeIntervalSince1970)"
    }
}

struct SoundCloudFeedPage: Sendable {
    let items: [SoundCloudFeedItem]
    let nextURL: URL?
}

struct RawFeedPage: Decodable {
    let collection: [RawFeedActivity]
    let nextURL: URL?

    enum CodingKeys: String, CodingKey {
        case collection
        case nextURL = "next_href"
    }
}

// api-v2 /stream activities include the reposting user inline.
struct RawFeedActivity: Decodable {
    let content: SoundCloudFeedContent?
    let isRepost: Bool
    let user: SoundCloudUser?
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case type, track, playlist, user
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        isRepost = type == "track-repost" || type == "playlist-repost"
        switch type {
        case "track", "track-repost":
            content = try container.decodeIfPresent(RawTrack.self, forKey: .track)?
                .normalized().map(SoundCloudFeedContent.track)
        case "playlist", "playlist-repost":
            content = try container.decodeIfPresent(RawPlaylist.self, forKey: .playlist)?
                .normalized().map(SoundCloudFeedContent.playlist)
        default:
            content = nil
            user = nil
            createdAt = nil
            return
        }
        user = try container.decodeIfPresent(RawUser.self, forKey: .user)?.normalized()
        let timestamp = try container.decode(String.self, forKey: .createdAt)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = iso.date(from: timestamp)
        if date == nil {
            iso.formatOptions = [.withInternetDateTime]
            date = iso.date(from: timestamp)
        }
        if date == nil {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy/MM/dd HH:mm:ss Z"
            date = formatter.date(from: timestamp)
        }
        guard let date else {
            throw DecodingError.dataCorruptedError(
                forKey: .createdAt, in: container, debugDescription: "Invalid feed timestamp"
            )
        }
        createdAt = date
    }
}

struct SoundCloudPlaylist: Codable, Identifiable, Sendable, Hashable {
    let urn: String
    let title: String
    let owner: SoundCloudUser
    let artworkURL: URL?
    let permalinkURL: URL
    let description: String?
    let trackCount: Int?
    let durationMilliseconds: Int?
    let isPrivate: Bool
    var lastModified: String? = nil
    var createdAt: String? = nil

    var tagList: String? = nil

    var tags: [String] { SoundCloudTags.parse(tagList) }

    var isSystemPlaylist: Bool { urn.hasPrefix("soundcloud:system-playlists:") }

    static func systemPlaylist(urn: String, title: String, contents: SoundCloudStation? = nil) -> Self {
        let url = URL(string: "https://soundcloud.com")!
        return Self(
            urn: urn, title: contents?.title ?? title,
            owner: SoundCloudUser(urn: nil, username: "SoundCloud", avatarURL: nil, permalinkURL: url),
            artworkURL: nil,
            permalinkURL: contents?.permalinkURL ?? url.appending(path: "discover/sets")
                .appending(path: String(urn.dropFirst("soundcloud:system-playlists:".count))),
            description: contents?.description, trackCount: contents?.trackCount,
            durationMilliseconds: nil, isPrivate: false, lastModified: contents?.lastUpdated
        )
    }

    var id: String { urn }
}

struct SoundCloudPlaylistPage: Sendable {
    let playlists: [SoundCloudPlaylist]
    let nextURL: URL?
}

struct SoundCloudTrackDetails: Sendable, Equatable {
    var tags: [String] = []
    let track: SoundCloudTrack
    let description: String?
    let genre: String?
    let createdAt: String?
    let playbackCount: Int?
    let favoritingsCount: Int?
    var commentCount: Int?
}

struct SoundCloudComment: Decodable, Identifiable, Sendable {
    let urn: String
    let body: String
    let user: SoundCloudUser?
    let createdAt: Date?
    let timestampMilliseconds: Int?

    var id: String { urn }

    enum CodingKeys: String, CodingKey {
        case urn, id, body, user, timestamp
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let urn = try container.decodeIfPresent(String.self, forKey: .urn) {
            self.urn = urn
        } else {
            urn = "soundcloud:comments:\(try container.decode(Int.self, forKey: .id))"
        }
        body = try container.decode(String.self, forKey: .body)
        user = try container.decodeIfPresent(RawUser.self, forKey: .user)?.normalized()

        // The schema uses a string, but the API example uses a number.
        let timestamp: Double?
        if let number = try? container.decode(Double.self, forKey: .timestamp) {
            timestamp = number
        } else if let string = try? container.decode(String.self, forKey: .timestamp) {
            timestamp = Double(string)
        } else {
            timestamp = nil
        }
        if let timestamp, timestamp.isFinite, timestamp >= 0 {
            timestampMilliseconds = Int(exactly: timestamp.rounded(.towardZero))
        } else {
            timestampMilliseconds = nil
        }

        if let value = try container.decodeIfPresent(String.self, forKey: .createdAt) {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var date = iso.date(from: value)
            if date == nil {
                iso.formatOptions = [.withInternetDateTime]
                date = iso.date(from: value)
            }
            if date == nil {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "yyyy/MM/dd HH:mm:ss Z"
                date = formatter.date(from: value)
            }
            createdAt = date
        } else {
            createdAt = nil
        }
    }
}

struct SoundCloudCommentPage: Decodable, Sendable {
    let comments: [SoundCloudComment]
    let nextURL: URL?

    enum CodingKeys: String, CodingKey {
        case comments = "collection"
        case nextURL = "next_href"
    }
}

struct SoundCloudWaveform: Decodable, Sendable, Equatable {
    let width: Int
    let height: Int
    let samples: [Int]
}

struct PlaybackSource: Sendable, Equatable {
    enum Kind: String, Sendable {
        case hls
        case mp3
    }

    enum Codec: String, Sendable {
        case aac
        case mp3
    }

    let url: URL
    let kind: Kind
    let codec: Codec
    let bitrateKilobitsPerSecond: Int
    let isPreview: Bool
}

struct TokenRecord: Codable, Sendable, Equatable {
    let accessToken: String
    var user: SoundCloudUser?
}

struct APIErrorBody: Decodable {
    let message: String?
}

struct RawTrackPage: Decodable {
    let collection: [RawTrack]
    let nextURL: URL?

    init(from decoder: Decoder) throws {
        if var container = try? decoder.unkeyedContainer() {
            var tracks: [RawTrack] = []
            while !container.isAtEnd {
                tracks.append(try container.decode(RawTrack.self))
            }
            collection = tracks
            nextURL = nil
        } else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            collection = try container.decode([WrappedItem<RawTrack>].self, forKey: .collection)
                .compactMap(\.item)
            nextURL = try container.decodeIfPresent(URL.self, forKey: .nextURL)
        }
    }

    enum CodingKeys: String, CodingKey {
        case collection
        case nextURL = "next_href"
    }
}

struct RawPlaylistPage: Decodable {
    let collection: [RawPlaylist]
    let nextURL: URL?

    init(from decoder: Decoder) throws {
        if var container = try? decoder.unkeyedContainer() {
            var playlists: [RawPlaylist] = []
            while !container.isAtEnd {
                playlists.append(try container.decode(RawPlaylist.self))
            }
            collection = playlists
            nextURL = nil
        } else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            collection = try container.decode([WrappedItem<RawPlaylist>].self, forKey: .collection)
                .compactMap(\.item)
            nextURL = try container.decodeIfPresent(URL.self, forKey: .nextURL)
        }
    }

    enum CodingKeys: String, CodingKey {
        case collection
        case nextURL = "next_href"
    }
}

protocol WrappableItem: Decodable {
    static var wrapperKey: String { get }
}

/// api-v2 collections hold either bare items or wrappers such as likes and reposts.
/// Wrappers for other content types decode to nil.
struct WrappedItem<Item: WrappableItem>: Decodable {
    let item: Item?

    private struct Key: CodingKey {
        let stringValue: String
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        if container.contains(Key(Item.wrapperKey)) {
            item = try container.decodeIfPresent(Item.self, forKey: Key(Item.wrapperKey))
        } else if container.contains(Key("type"))
                    || (try? container.decode(String.self, forKey: Key("kind"))) == "like" {
            item = nil
        } else {
            item = try Item(from: decoder)
        }
    }
}

// The likes endpoint returns metadata without hydrated tracks.
struct SoundCloudStationLikePage: Decodable, Sendable {
    struct Station: Codable, Sendable, Identifiable {
        let urn: String
        var title: String? = nil
        var id: String { urn }
        var displayTitle: String { title ?? "Station" }
        var isStation: Bool {
            urn.hasPrefix("soundcloud:system-playlists:track-stations:")
                || urn.hasPrefix("soundcloud:system-playlists:artist-stations:")
        }
    }
    let collection: [Station]
    let nextURL: URL?

    enum CodingKeys: String, CodingKey {
        case collection
        case nextURL = "next_href"
    }

    init(collection: [Station], nextURL: URL?) {
        self.collection = collection
        self.nextURL = nextURL
    }

    init(from decoder: Decoder) throws {
        if let stations = try? decoder.singleValueContainer().decode([Station].self) {
            collection = stations
            nextURL = nil
        } else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            collection = try container.decode([Station].self, forKey: .collection)
            nextURL = try container.decodeIfPresent(URL.self, forKey: .nextURL)
        }
    }
}

struct SoundCloudStation: Sendable {
    let title: String?
    let description: String?
    let permalinkURL: URL?
    let lastUpdated: String?
    let trackCount: Int?
    let tracks: [SoundCloudTrack]
}

struct RawSystemPlaylist: Decodable {
    let title: String?
    let description: String?
    let permalinkURL: URL?
    let lastUpdated: String?
    let trackCount: Int?
    let tracks: [RawTrack]

    enum CodingKeys: String, CodingKey {
        case title, description, tracks
        case permalinkURL = "permalink_url"
        case lastUpdated = "last_updated"
        case trackCount = "track_count"
    }

    func normalized() -> SoundCloudStation {
        normalized(tracks: tracks.compactMap { $0.normalized() })
    }

    /// api-v2 stations list track stubs; callers pass the hydrated tracks.
    func normalized(tracks: [SoundCloudTrack]) -> SoundCloudStation {
        SoundCloudStation(
            title: title, description: description, permalinkURL: permalinkURL,
            lastUpdated: lastUpdated, trackCount: trackCount ?? self.tracks.count,
            tracks: tracks
        )
    }
}

struct RawPlaylist: WrappableItem {
    static let wrapperKey = "playlist"
    let urn: String?
    let id: Int?
    let title: String?
    let user: RawUser?
    private let rawArtworkURL: String?
    let permalinkURL: URL?
    let description: String?
    let trackCount: Int?
    let duration: Int?
    let sharing: String?
    let lastModified: String?
    let createdAt: String?
    let tagList: String?

    enum CodingKeys: String, CodingKey {
        case urn, id, title, user, description, duration, sharing
        case rawArtworkURL = "artwork_url"
        case permalinkURL = "permalink_url"
        case trackCount = "track_count"
        case lastModified = "last_modified"
        case createdAt = "created_at"
        case tagList = "tag_list"
    }

    func normalized() -> SoundCloudPlaylist? {
        guard let urn = urn ?? id.map({ "soundcloud:playlists:\($0)" }),
              let title, let owner = user?.normalized(),
              let permalinkURL else { return nil }
        let artworkURL = rawArtworkURL.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        return SoundCloudPlaylist(
            urn: urn,
            title: title,
            owner: owner,
            artworkURL: artworkURL,
            permalinkURL: permalinkURL,
            description: description,
            trackCount: trackCount,
            durationMilliseconds: duration,
            isPrivate: sharing == "private",
            lastModified: lastModified,
            createdAt: createdAt,
            tagList: tagList
        )
    }
}

struct RawTrack: WrappableItem {
    static let wrapperKey = "track"
    let urn: String?
    let id: Int?
    let title: String?
    private let rawArtworkURL: String?
    var artworkURL: URL? {
        guard let rawArtworkURL, !rawArtworkURL.isEmpty else { return nil }
        return URL(string: rawArtworkURL)
    }
    private let rawWaveformURL: String?
    var waveformURL: URL? {
        guard let rawWaveformURL, !rawWaveformURL.isEmpty else { return nil }
        return URL(string: rawWaveformURL)
    }
    let permalinkURL: URL?
    let duration: Int?
    let access: SoundCloudTrack.Access?
    let policy: String?
    let secretURI: URL?
    let secretTokenValue: String?
    let user: RawUser?
    let description: String?
    let genre: String?
    let tagList: String?
    let createdAt: String?
    let playbackCount: Int?
    private let favoritingsCountValue: Int?
    private let likesCount: Int?
    var favoritingsCount: Int? { favoritingsCountValue ?? likesCount }
    let repostsCount: Int?
    let commentCount: Int?
    let stationURN: String?

    enum CodingKeys: String, CodingKey {
        case urn
        case id
        case policy
        case secretTokenValue = "secret_token"
        case likesCount = "likes_count"
        case title
        case rawArtworkURL = "artwork_url"
        case rawWaveformURL = "waveform_url"
        case permalinkURL = "permalink_url"
        case duration
        case access
        case secretURI = "secret_uri"
        case user
        case description
        case genre
        case tagList = "tag_list"
        case createdAt = "created_at"
        case playbackCount = "playback_count"
        case favoritingsCountValue = "favoritings_count"
        case repostsCount = "reposts_count"
        case commentCount = "comment_count"
        case stationURN = "station_urn"
    }

    func normalized() -> SoundCloudTrack? {
        guard let urn = urn ?? id.map({ "soundcloud:tracks:\($0)" }),
              let title,
              let permalinkURL,
              let access = access ?? policy.flatMap(SoundCloudTrack.Access.init(policy:)),
              access == .playable || access == .preview,
              let artist = user?.normalized() else {
            return nil
        }
        return SoundCloudTrack(
            urn: urn,
            title: title,
            artist: artist,
            artworkURL: artworkURL,
            waveformURL: waveformURL,
            permalinkURL: permalinkURL,
            durationMilliseconds: duration ?? 0,
            access: access,
            secretToken: Self.extractSecretToken(from: secretURI) ?? secretTokenValue,
            likesCount: favoritingsCount,
            repostsCount: repostsCount,
            commentCount: commentCount,
            genre: genre,
            createdAt: createdAt,
            stationURN: stationURN
        )
    }

    func normalizedDetails() -> SoundCloudTrackDetails? {
        guard let track = normalized() else { return nil }
        return SoundCloudTrackDetails(
            tags: SoundCloudTags.parse(tagList),
            track: track,
            description: description,
            genre: genre,
            createdAt: createdAt,
            playbackCount: playbackCount,
            favoritingsCount: favoritingsCount,
            commentCount: commentCount
        )
    }

    private static func extractSecretToken(from url: URL?) -> String? {
        guard let url else { return nil }
        if let queryToken = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )?.queryItems?.first(where: { $0.name == "secret_token" })?.value {
            return queryToken
        }
        return url.pathComponents.reversed().first { component in
            component.hasPrefix("s-")
        }
    }
}

struct RawUser: Decodable {
    let fullName: String?
    let urn: String?
    let username: String?
    let avatarURL: URL?
    let permalinkURL: URL?
    let description: String?
    let city: String?
    let country: String?
    let followersCount: Int?
    let followingsCount: Int?
    let trackCount: Int?
    let repostsCount: Int?
    let playlistCount: Int?
    let publicFavoritesCount: Int?
    let likesCount: Int?
    let countryCode: String?
    let stationURN: String?

    enum CodingKeys: String, CodingKey {
        case urn, description, city, country
        case likesCount = "likes_count"
        case countryCode = "country_code"
        case fullName = "full_name"
        case followersCount = "followers_count"
        case followingsCount = "followings_count"
        case trackCount = "track_count"
        case repostsCount = "reposts_count"
        case playlistCount = "playlist_count"
        case publicFavoritesCount = "public_favorites_count"
        case stationURN = "station_urn"
        case username
        case avatarURL = "avatar_url"
        case permalinkURL = "permalink_url"
    }

    func normalized() -> SoundCloudUser? {
        guard let username, let permalinkURL else { return nil }
        return SoundCloudUser(
            urn: urn,
            username: username,
            avatarURL: avatarURL,
            permalinkURL: permalinkURL,
            followersCount: followersCount,
            fullName: fullName,
            trackCount: trackCount,
            repostsCount: repostsCount,
            playlistCount: playlistCount,
            publicFavoritesCount: publicFavoritesCount ?? likesCount,
            stationURN: stationURN
        )
    }

    func normalizedArtistDetails() -> SoundCloudArtistDetails? {
        guard let user = normalized() else { return nil }
        return SoundCloudArtistDetails(
            user: user,
            description: description,
            city: city,
            country: country ?? countryCode.flatMap { Locale.current.localizedString(forRegionCode: $0) },
            followersCount: followersCount,
            followingsCount: followingsCount,
            trackCount: trackCount
        )
    }
}

struct StreamResponse: Decodable {
    struct Transcoding: Decodable {
        struct Format: Decodable {
            let `protocol`: String
            let mimeType: String

            enum CodingKeys: String, CodingKey {
                case `protocol`
                case mimeType = "mime_type"
            }
        }

        let url: URL
        let preset: String?
        let snipped: Bool?
        let format: Format
    }

    struct Media: Decodable {
        let transcodings: [Transcoding]
    }

    let media: Media?
    let trackAuthorization: String?

    enum CodingKeys: String, CodingKey {
        case media
        case trackAuthorization = "track_authorization"
    }

    /// Unencrypted streams, best first: full before previews, AAC before MP3, then bitrate.
    var candidates: [(transcoding: Transcoding, source: PlaybackSource)] {
        (media?.transcodings ?? []).compactMap { transcoding in
            let kind: PlaybackSource.Kind
            switch transcoding.format.protocol {
            case "hls": kind = .hls
            case "progressive": kind = .mp3
            default: return nil
            }
            let mimeType = transcoding.format.mimeType.lowercased()
            let codec: PlaybackSource.Codec = mimeType.contains("mp4") || mimeType.contains("aac")
                || mimeType.contains("mpegurl") ? .aac : .mp3
            // Presets look like "aac_160k" or "mp3_1_0"; adaptive presets omit a bitrate.
            let bitrate = (transcoding.preset ?? "").split(separator: "_").lazy
                .compactMap { $0.hasSuffix("k") ? Int($0.dropLast()) : nil }.first
                ?? (codec == .aac ? 160 : 128)
            return (transcoding, PlaybackSource(
                url: transcoding.url, kind: kind, codec: codec,
                bitrateKilobitsPerSecond: bitrate, isPreview: transcoding.snipped == true
            ))
        }
        .sorted { lhs, rhs in
            let left = lhs.source, right = rhs.source
            if left.isPreview != right.isPreview { return !left.isPreview }
            if left.codec != right.codec { return left.codec == .aac }
            if left.bitrateKilobitsPerSecond != right.bitrateKilobitsPerSecond {
                return left.bitrateKilobitsPerSecond > right.bitrateKilobitsPerSecond
            }
            // Adaptive presets omit a bitrate; prefer a fixed preset at the same rate.
            let leftFixed = lhs.transcoding.preset?.contains("abr") != true
            let rightFixed = rhs.transcoding.preset?.contains("abr") != true
            return leftFixed && !rightFixed
        }
    }
}

// The public API does not expose profile headers. SoundCloud's profile page
// includes them in its user hydration data; treat this optional data as best effort.
enum SoundCloudProfileHeader {
    static func profileURL(_ url: URL) -> URL? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              ["soundcloud.com", "www.soundcloud.com"].contains(url.host?.lowercased() ?? ""),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        components.scheme = "https"
        components.host = "soundcloud.com"
        components.port = nil
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        components.path = "/" + url.path.split(separator: "/").joined(separator: "/")
        return components.url
    }

    static func imageURL(in html: String, for user: SoundCloudUser) -> URL? {
        guard let marker = html.range(of: "window.__sc_hydration = "),
              let end = html.range(of: "</script>", range: marker.upperBound..<html.endIndex),
              let data = html[marker.upperBound..<end.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
                .data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }

        for entry in entries where entry["hydratable"] as? String == "user" {
            guard let profile = entry["data"] as? [String: Any],
                  matches(profile, user: user),
                  let visuals = profile["visuals"] as? [String: Any],
                  visuals["enabled"] as? Bool != false,
                  let images = visuals["visuals"] as? [[String: Any]] else { continue }
            for image in images {
                guard let value = image["visual_url"] as? String,
                      let url = URL(string: value),
                      url.scheme == "https",
                      let host = url.host?.lowercased(),
                      host.hasSuffix(".sndcdn.com") else { continue }
                return url
            }
        }
        return nil
    }

    private static func matches(_ profile: [String: Any], user: SoundCloudUser) -> Bool {
        if let urn = user.urn, let profileURN = profile["urn"] as? String {
            return urn == profileURN
        }
        guard let permalink = profile["permalink_url"] as? String,
              let url = URL(string: permalink),
              let canonicalURL = profileURL(url),
              let expectedURL = profileURL(user.permalinkURL) else { return false }
        return canonicalURL == expectedURL
    }

}

struct PlaylistArtwork: Sendable {
    enum Format: String, Sendable {
        case gif, jpeg, png

        var mimeType: String { "image/\(rawValue)" }
    }

    let data: Data
    let format: Format
}

private enum SoundCloudTags {
    static func parse(_ tagList: String?) -> [String] {
        var tags: [String] = []
        var tag = ""
        var isQuoted = false
        for character in tagList ?? "" {
            if character == "\"" {
                isQuoted.toggle()
            } else if character.isWhitespace && !isQuoted {
                if !tag.isEmpty { tags.append(tag) }
                tag = ""
            } else {
                tag.append(character)
            }
        }
        if !tag.isEmpty { tags.append(tag) }
        // Machine tags are metadata and are not shown on SoundCloud pages.
        return tags.filter {
            $0.range(of: #"^[^:\s]+:[^=\s]+="#, options: .regularExpression) == nil
                && !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

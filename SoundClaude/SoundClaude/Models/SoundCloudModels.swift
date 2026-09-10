import Foundation

struct SoundCloudUser: Codable, Sendable, Hashable {
    let urn: String?
    let username: String
    let avatarURL: URL?
    let permalinkURL: URL
    var followersCount: Int? = nil

    enum CodingKeys: String, CodingKey {
        case urn
        case username
        case avatarURL = "avatar_url"
        case permalinkURL = "permalink_url"
        case followersCount = "followers_count"
    }
}

enum ArtistUserList: String, Sendable, Hashable, CaseIterable {
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

    var id: String { urn }
    var uploader: String { artist.username }

    enum Access: String, Codable, Sendable {
        case playable
        case preview
        case blocked
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

struct RawFeedActivity: Decodable {
    let content: SoundCloudFeedContent?
    let isRepost: Bool
    let reposterURN: String?
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case type, origin, reposter
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        isRepost = type == "track:repost" || type == "playlist:repost"
        switch type {
        case "track", "track:repost":
            content = try container.decodeIfPresent(RawTrack.self, forKey: .origin)?
                .normalized().map(SoundCloudFeedContent.track)
        case "playlist", "playlist:repost":
            content = try container.decodeIfPresent(RawPlaylist.self, forKey: .origin)?
                .normalized().map(SoundCloudFeedContent.playlist)
        default:
            content = nil
            reposterURN = nil
            createdAt = nil
            return
        }
        reposterURN = try container.decodeIfPresent(String.self, forKey: .reposter)
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

    var id: String { urn }
}

struct SoundCloudPlaylistPage: Sendable {
    let playlists: [SoundCloudPlaylist]
    let nextURL: URL?
}

struct SoundCloudTrackDetails: Sendable, Equatable {
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
        case urn, body, user, timestamp
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        urn = try container.decode(String.self, forKey: .urn)
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
    let refreshToken: String
    let expiresAt: Date
    var user: SoundCloudUser?
}

struct OAuthTokenResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: TimeInterval

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
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
            collection = try container.decode([RawTrack].self, forKey: .collection)
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
            collection = try container.decode([RawPlaylist].self, forKey: .collection)
            nextURL = try container.decodeIfPresent(URL.self, forKey: .nextURL)
        }
    }

    enum CodingKeys: String, CodingKey {
        case collection
        case nextURL = "next_href"
    }
}

struct RawPlaylist: Decodable {
    let urn: String?
    let title: String?
    let user: RawUser?
    private let rawArtworkURL: String?
    let permalinkURL: URL?
    let description: String?
    let trackCount: Int?
    let duration: Int?
    let sharing: String?

    enum CodingKeys: String, CodingKey {
        case urn, title, user, description, duration, sharing
        case rawArtworkURL = "artwork_url"
        case permalinkURL = "permalink_url"
        case trackCount = "track_count"
    }

    func normalized() -> SoundCloudPlaylist? {
        guard let urn, let title, let owner = user?.normalized(),
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
            isPrivate: sharing == "private"
        )
    }
}

struct RawTrack: Decodable {
    let urn: String?
    let title: String?
    let artworkURL: URL?
    private let rawWaveformURL: String?
    var waveformURL: URL? {
        guard let rawWaveformURL, !rawWaveformURL.isEmpty else { return nil }
        return URL(string: rawWaveformURL)
    }
    let permalinkURL: URL?
    let duration: Int?
    let access: SoundCloudTrack.Access?
    let secretURI: URL?
    let user: RawUser?
    let description: String?
    let genre: String?
    let createdAt: String?
    let playbackCount: Int?
    let favoritingsCount: Int?
    let repostsCount: Int?
    let commentCount: Int?

    enum CodingKeys: String, CodingKey {
        case urn
        case title
        case artworkURL = "artwork_url"
        case rawWaveformURL = "waveform_url"
        case permalinkURL = "permalink_url"
        case duration
        case access
        case secretURI = "secret_uri"
        case user
        case description
        case genre
        case createdAt = "created_at"
        case playbackCount = "playback_count"
        case favoritingsCount = "favoritings_count"
        case repostsCount = "reposts_count"
        case commentCount = "comment_count"
    }

    func normalized() -> SoundCloudTrack? {
        guard let urn,
              let title,
              let permalinkURL,
              let access,
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
            secretToken: Self.extractSecretToken(from: secretURI),
            likesCount: favoritingsCount,
            repostsCount: repostsCount,
            commentCount: commentCount,
            genre: genre
        )
    }

    func normalizedDetails() -> SoundCloudTrackDetails? {
        guard let track = normalized() else { return nil }
        return SoundCloudTrackDetails(
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

    enum CodingKeys: String, CodingKey {
        case urn, description, city, country
        case followersCount = "followers_count"
        case followingsCount = "followings_count"
        case trackCount = "track_count"
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
            followersCount: followersCount
        )
    }

    func normalizedArtistDetails() -> SoundCloudArtistDetails? {
        guard let user = normalized() else { return nil }
        return SoundCloudArtistDetails(
            user: user,
            description: description,
            city: city,
            country: country,
            followersCount: followersCount,
            followingsCount: followingsCount,
            trackCount: trackCount
        )
    }
}

struct StreamResponse: Decodable {
    let hlsAAC160URL: URL?
    let hlsMP3128URL: URL?
    let previewMP3128URL: URL?

    enum CodingKeys: String, CodingKey {
        case hlsAAC160URL = "hls_aac_160_url"
        case hlsMP3128URL = "hls_mp3_128_url"
        case previewMP3128URL = "preview_mp3_128_url"
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

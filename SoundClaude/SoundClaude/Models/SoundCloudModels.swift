import Foundation

struct SoundCloudUser: Codable, Sendable, Hashable {
    let urn: String?
    let username: String
    let avatarURL: URL?
    let permalinkURL: URL

    enum CodingKeys: String, CodingKey {
        case urn
        case username
        case avatarURL = "avatar_url"
        case permalinkURL = "permalink_url"
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

struct SoundCloudTrackDetails: Sendable, Equatable {
    let track: SoundCloudTrack
    let description: String?
    let genre: String?
    let createdAt: String?
    let playbackCount: Int?
    let favoritingsCount: Int?
    let commentCount: Int?
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
            secretToken: Self.extractSecretToken(from: secretURI)
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
            permalinkURL: permalinkURL
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

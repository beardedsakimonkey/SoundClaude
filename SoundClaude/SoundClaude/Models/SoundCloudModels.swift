import Foundation

struct SoundCloudUser: Codable, Sendable, Equatable {
    let username: String
    let avatarURL: URL?
    let permalinkURL: URL

    enum CodingKeys: String, CodingKey {
        case username
        case avatarURL = "avatar_url"
        case permalinkURL = "permalink_url"
    }
}

struct SoundCloudTrack: Identifiable, Sendable, Hashable {
    let urn: String
    let title: String
    let uploader: String
    let artworkURL: URL?
    let waveformURL: URL?
    let permalinkURL: URL
    let uploaderPermalinkURL: URL
    let durationMilliseconds: Int
    let access: Access
    let secretToken: String?

    var id: String { urn }

    enum Access: String, Decodable, Sendable {
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

    enum CodingKeys: String, CodingKey {
        case collection
        case nextURL = "next_href"
    }
}

struct RawTrack: Decodable {
    let urn: String?
    let title: String?
    let artworkURL: URL?
    let waveformURL: URL?
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
        case waveformURL = "waveform_url"
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
              let user,
              let uploader = user.username,
              let uploaderPermalinkURL = user.permalinkURL else {
            return nil
        }
        return SoundCloudTrack(
            urn: urn,
            title: title,
            uploader: uploader,
            artworkURL: artworkURL,
            waveformURL: waveformURL,
            permalinkURL: permalinkURL,
            uploaderPermalinkURL: uploaderPermalinkURL,
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
    let username: String?
    let avatarURL: URL?
    let permalinkURL: URL?

    enum CodingKeys: String, CodingKey {
        case username
        case avatarURL = "avatar_url"
        case permalinkURL = "permalink_url"
    }

    func normalized() -> SoundCloudUser? {
        guard let username, let permalinkURL else { return nil }
        return SoundCloudUser(
            username: username,
            avatarURL: avatarURL,
            permalinkURL: permalinkURL
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

import SwiftUI

struct ArtistMentionText: View {
    @Environment(\.searchTag) private var searchTag

    let onSelectArtist: (SoundCloudUser) -> Void
    private let mentions: ArtistMentions

    init(_ text: String, onSelectArtist: @escaping (SoundCloudUser) -> Void) {
        mentions = ArtistMentions.cached(text)
        self.onSelectArtist = onSelectArtist
    }

    var body: some View {
        Text(mentions.text)
            .opacity(0.95)
            .environment(\.openURL, OpenURLAction { url in
                if let tag = mentions.tagsByURL[url] {
                    searchTag(tag)
                    return .handled
                }
                guard let artist = mentions.artistsByURL[url] else {
                    return .systemAction
                }
                onSelectArtist(artist)
                return .handled
            })
    }
}

private struct ArtistMentions {
    let text: AttributedString
    let artistsByURL: [URL: SoundCloudUser]
    let tagsByURL: [URL: String]

    @MainActor private static let cache = MemoryCache<NSString, ArtistMentions>(countLimit: 256)

    @MainActor static func cached(_ text: String) -> ArtistMentions {
        let key = text as NSString
        if let mentions = cache.value(forKey: key) {
            return mentions
        }
        let mentions = ArtistMentions(text)
        cache.insert(mentions, forKey: key)
        return mentions
    }

    private static let linkDetector = try! NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    // Match profile handles without treating email addresses or URL paths as mentions.
    private static let mentionPattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_./%+@-])@([A-Za-z0-9_-]+)(?![\p{L}\p{N}_-])"#
    )

    // Include Unicode letters, combining marks, numbers, underscores, and hyphens.
    private static let hashtagPattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{M}\p{N}_./%+@#-])#([\p{L}\p{N}_][\p{L}\p{M}\p{N}_-]*)"#
    )

    init(_ description: String) {
        var text = AttributedString(description)
        var artistsByURL: [URL: SoundCloudUser] = [:]
        var tagsByURL: [URL: String] = [:]
        let links = Self.linkDetector.matches(
            in: description,
            range: NSRange(description.startIndex..., in: description)
        )
        for link in links {
            guard let url = link.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let linkRange = Range(link.range, in: description),
                  let attributedRange = Range(linkRange, in: text) else { continue }
            text[attributedRange].link = url
        }

        let matches = Self.mentionPattern.matches(
            in: description,
            range: NSRange(description.startIndex..., in: description)
        )
        for match in matches {
            guard !links.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) else {
                continue
            }
            guard let handleRange = Range(match.range(at: 1), in: description),
                  let mentionRange = Range(match.range, in: description),
                  let attributedRange = Range(mentionRange, in: text) else { continue }
            let handle = String(description[handleRange])
            let url = URL(string: "https://soundcloud.com")!.appendingPathComponent(handle)
            // Keep mentions separate from web links to the same artist profile.
            let mentionURL = URL(string: "soundclaude-mention://artist")!.appendingPathComponent(handle)
            text[attributedRange].link = mentionURL
            artistsByURL[mentionURL] = SoundCloudUser(
                urn: nil,
                username: handle,
                avatarURL: nil,
                permalinkURL: url
            )
        }
        let hashtags = Self.hashtagPattern.matches(
            in: description,
            range: NSRange(description.startIndex..., in: description)
        )
        for hashtag in hashtags {
            guard !links.contains(where: { NSIntersectionRange($0.range, hashtag.range).length > 0 }),
                  let tagRange = Range(hashtag.range(at: 1), in: description),
                  let hashtagRange = Range(hashtag.range, in: description),
                  let attributedRange = Range(hashtagRange, in: text) else { continue }
            let tag = String(description[tagRange])
            let tagURL = URL(string: "soundclaude-tag://tracks")!.appendingPathComponent(tag)
            text[attributedRange].link = tagURL
            tagsByURL[tagURL] = tag
        }
        self.text = text
        self.artistsByURL = artistsByURL
        self.tagsByURL = tagsByURL
    }
}

import SwiftUI

struct ArtistMentionText: View {
    @Environment(\.searchTag) private var searchTag
    @State private var isHovering = false
    @State private var hoverLocation: CGPoint?
    @State private var hoveredLink: Int?

    let onSelectArtist: (SoundCloudUser) -> Void
    private let mentions: ArtistMentions
    private let isQuoted: Bool

    init(_ text: String, isQuoted: Bool = false, onSelectArtist: @escaping (SoundCloudUser) -> Void) {
        mentions = ArtistMentions.cached(text)
        self.isQuoted = isQuoted
        self.onSelectArtist = onSelectArtist
    }

    var body: some View {
        displayText
            .opacity(0.95)
            .onContentHover { isHovering = $0 }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hoverLocation = location
                case .ended: hoverLocation = nil
                }
            }
            .backgroundPreferenceValue(Text.LayoutKey.self) { layouts in
                GeometryReader { geometry in
                    let link = linkAtPointer(in: layouts, geometry: geometry)
                    Color.clear
                        .onChange(of: link, initial: true) { _, value in
                            hoveredLink = value
                        }
                }
                .allowsHitTesting(false)
            }
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
            #if DEBUG
            .debugViewUpdates("ArtistMentionText")
            #endif
    }

    private var displayText: Text {
        if isQuoted {
            Text("\(Text("“").foregroundStyle(.secondary))\(linkedText)\(Text("”").foregroundStyle(.secondary))")
        } else {
            linkedText
        }
    }

    private var linkedText: Text {
        mentions.text.runs.enumerated().reduce(Text("")) { result, element in
            let (index, run) = element
            var part = Text(AttributedString(mentions.text[run.range]))
            if run.link != nil {
                part = part
                    .customAttribute(MentionLinkAttribute(index: index))
                    .underline(isHovering && hoveredLink == index)
            }
            return Text("\(result)\(part)")
        }
    }

    private func linkAtPointer(in layouts: [Text.LayoutKey.AnchoredLayout], geometry: GeometryProxy) -> Int? {
        guard let hoverLocation else { return nil }
        for anchored in layouts {
            let origin = geometry[anchored.origin]
            let point = CGPoint(x: hoverLocation.x - origin.x, y: hoverLocation.y - origin.y)
            for line in anchored.layout {
                for run in line where run.typographicBounds.rect.contains(point) {
                    if let link = run[MentionLinkAttribute.self] {
                        return link.index
                    }
                }
            }
        }
        return nil
    }
}

private struct MentionLinkAttribute: TextAttribute {
    let index: Int
}

private struct ArtistMentions {
    let text: AttributedString
    let artistsByURL: [URL: SoundCloudUser]
    let tagsByURL: [URL: String]

    @MainActor private static let cache = MemoryCache<NSString, ArtistMentions>(name: "Artist Mentions", countLimit: 256)

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

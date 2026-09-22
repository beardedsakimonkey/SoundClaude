import SwiftUI

struct ExpandableDescriptionText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let description: ArtistMentionText

    private let collapsedLineLimit = 5
    private let opacity = 0.9

    @State private var isExpanded = false
    @State private var isHoveringToggle = false
    @State private var collapsedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    private var isTruncated: Bool {
        !isExpanded && fullHeight > collapsedHeight
    }

    init(description: String, onSelectArtist: @escaping (SoundCloudUser) -> Void) {
        self.description = ArtistMentionText(description, onSelectArtist: onSelectArtist)
    }

    @ViewBuilder
    private var selectableDescription: some View {
        // Native text selection can draw outside the fade mask when activated.
        if isTruncated {
            description.textSelection(.disabled)
        } else {
            description.textSelection(.enabled)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            selectableDescription
                // Keep the full text laid out while its visible height animates.
                .lineLimit(fullHeight > 0 ? nil : collapsedLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .topLeading) {
                    // Measure both sizes at the current width, even while expanded.
                    ZStack(alignment: .topLeading) {
                        description
                            .lineLimit(collapsedLineLimit)
                            .fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.size.height
                            } action: { collapsedHeight = $0 }

                        description
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.size.height
                            } action: { fullHeight = $0 }
                    }
                    .textSelection(.disabled)
                    .hidden()
                    .accessibilityHidden(true)
                }
                .modifier(DescriptionHeight(height: isExpanded ? fullHeight : collapsedHeight))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: isExpanded)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(opacity), location: 0),
                            .init(color: .black.opacity(opacity), location: 0.8),
                            .init(color: isTruncated ? .clear : .black.opacity(opacity), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }

            if isExpanded || isTruncated {
                Button(isExpanded ? "Show less" : "Show more") {
                    isExpanded.toggle()
                }
                .buttonStyle(.link)
                .fontWeight(.semibold)
                .brightness(isHoveringToggle ? 0.1 : 0)
                .opacity(isHoveringToggle ? 1 : 0.9)
                .onContentHover { isHoveringToggle = $0 }
                .accessibilityHint(isExpanded ? "Collapse description" : "Expand description")
            }
        }
    }
}

private struct DescriptionHeight: AnimatableModifier {
    var height: CGFloat

    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    func body(content: Content) -> some View {
        // Update layout on each frame so lazy rows below move together, including
        // rows created while scrolling. Do not animate their individual positions.
        content
            .frame(height: height > 0 ? height : nil, alignment: .topLeading)
            .clipped()
            .transaction { $0.animation = nil }
    }
}

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

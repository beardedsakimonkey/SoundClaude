import SwiftUI

struct ExpandableDescriptionText: View {
    private let description: ArtistMentionText

    private let collapsedLineLimit = 5
    private let opacity = 0.8

    @State private var isExpanded = false
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
                .lineLimit(isExpanded ? nil : collapsedLineLimit)
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
                .opacity(0.9)
                .accessibilityHint(isExpanded ? "Collapse description" : "Expand description")
            }
        }
    }
}

struct ArtistMentionText: View {
    let onSelectArtist: (SoundCloudUser) -> Void
    private let mentions: ArtistMentions

    init(_ text: String, onSelectArtist: @escaping (SoundCloudUser) -> Void) {
        mentions = ArtistMentions(text)
        self.onSelectArtist = onSelectArtist
    }

    var body: some View {
        Text(mentions.text)
            .opacity(0.9)
            .environment(\.openURL, OpenURLAction { url in
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

    private static let linkDetector = try! NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    // Match profile handles without treating email addresses or URL paths as mentions.
    private static let mentionPattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_./%+@-])@([A-Za-z0-9_-]+)(?![\p{L}\p{N}_-])"#
    )

    init(_ description: String) {
        var text = AttributedString(description)
        var artistsByURL: [URL: SoundCloudUser] = [:]
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
        self.text = text
        self.artistsByURL = artistsByURL
    }
}

import SwiftUI

struct ExpandableDescriptionText: View {
    private let description: ArtistMentionText

    private let collapsedLineLimit = 5

    @State private var isExpanded = false
    @State private var collapsedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    init(description: String, onSelectArtist: @escaping (SoundCloudUser) -> Void) {
        self.description = ArtistMentionText(description, onSelectArtist: onSelectArtist)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            description
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
                    .hidden()
                    .accessibilityHidden(true)
                }

            if isExpanded || fullHeight > collapsedHeight {
                Button(isExpanded ? "Show less" : "Show more") {
                    isExpanded.toggle()
                }
                .buttonStyle(.link)
                .accessibilityHint(isExpanded ? "Collapse description" : "Expand description")
            }
        }
    }
}

private struct ArtistMentionText: View {
    let onSelectArtist: (SoundCloudUser) -> Void
    private let mentions: ArtistMentions

    init(_ text: String, onSelectArtist: @escaping (SoundCloudUser) -> Void) {
        mentions = ArtistMentions(text)
        self.onSelectArtist = onSelectArtist
    }

    var body: some View {
        Text(mentions.text)
            .textSelection(.enabled)
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

    // Match profile handles without treating email addresses or URL paths as mentions.
    private static let mentionPattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_./%+@-])@([A-Za-z0-9_-]+)(?![\p{L}\p{N}_-])"#
    )

    init(_ description: String) {
        var text = AttributedString(description)
        var artistsByURL: [URL: SoundCloudUser] = [:]
        let matches = Self.mentionPattern.matches(
            in: description,
            range: NSRange(description.startIndex..., in: description)
        )
        for match in matches {
            guard let handleRange = Range(match.range(at: 1), in: description),
                  let mentionRange = Range(match.range, in: description),
                  let attributedRange = Range(mentionRange, in: text) else { continue }
            let handle = String(description[handleRange])
            let url = URL(string: "https://soundcloud.com")!.appendingPathComponent(handle)
            text[attributedRange].link = url
            artistsByURL[url] = SoundCloudUser(
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

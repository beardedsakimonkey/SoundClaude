import SwiftUI

struct UserGridView: View {
    let users: [SoundCloudUser]
    let artworkLoader: ArtworkLoader
    let onSelectArtist: (SoundCloudUser) -> Void

    @State private var hoveredUserURL: URL?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 24)], spacing: 24) {
            ForEach(users, id: \.permalinkURL) { user in
                Button {
                    onSelectArtist(user)
                } label: {
                    VStack(spacing: 10) {
                        TrackArtworkView(
                            artworkURL: user.avatarURL,
                            loader: artworkLoader,
                            size: 120,
                            rendition: .square500,
                            showsPlaceholderIcon: false
                        )
                        .clipShape(Circle())
                        VStack(spacing: 4) {
                            Text(user.username)
                                .font(.headline)
                                .underline(hoveredUserURL == user.permalinkURL)
                                .lineLimit(2)
                            if let followersCount = user.followersCount {
                                Text("\(followersCount.formatted()) \(followersCount == 1 ? "follower" : "followers")")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .multilineTextAlignment(.center)
                        .frame(minHeight: 40, alignment: .top)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onContentHover { isHovering in
                    if isHovering {
                        hoveredUserURL = user.permalinkURL
                    } else if hoveredUserURL == user.permalinkURL {
                        hoveredUserURL = nil
                    }
                }
                .help("View profile: \(user.username)")
                .accessibilityLabel("View profile: \(user.username)")
                .modifier(UserFadeIn())
            }
        }
    }
}

private struct UserFadeIn: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    func body(content: Content) -> some View {
        content
            .opacity(hasAppeared || reduceMotion ? 1 : 0)
            .onAppear {
                guard !hasAppeared else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                    hasAppeared = true
                }
            }
    }
}

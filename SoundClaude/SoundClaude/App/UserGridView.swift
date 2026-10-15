import SwiftUI

struct UserGridView: View {
    let users: [SoundCloudUser]
    let artworkLoader: ArtworkLoader
    let onSelectArtist: (SoundCloudUser) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 164), spacing: 0)], spacing: 0) {
            ForEach(users, id: \.permalinkURL) { user in
                UserGridCard(
                    user: user,
                    artworkLoader: artworkLoader,
                    onSelectArtist: onSelectArtist
                )
            }
        }
        #if DEBUG
        .debugViewUpdates("UserGridView")
        #endif
    }
}

// Keep pointer changes local to the card instead of updating the whole grid.
private struct UserGridCard: View {
    let user: SoundCloudUser
    let artworkLoader: ArtworkLoader
    let onSelectArtist: (SoundCloudUser) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button {
            onSelectArtist(user)
        } label: {
            VStack(spacing: 10) {
                TrackArtworkView(
                    artworkURL: user.avatarURL,
                    loader: artworkLoader,
                    size: 120,
                    rendition: .square500,
                    showsBorder: false,
                    showsPlaceholderIcon: false
                )
                .scaleEffect(
                    isHovering && !reduceMotion ? 1.06 : 1
                )
                .animation(
                    reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.8),
                    value: isHovering
                )
                .clipShape(Circle())
                .modifier(PlayerArtworkGlass(
                    cornerRadius: 60,
                    isHovering: isHovering && !reduceMotion
                ))
                .scaleEffect(
                    isHovering && !reduceMotion ? 1.06 : 1
                )
                .animation(
                    reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.6),
                    value: isHovering
                )
                VStack(spacing: 4) {
                    Text(user.username)
                        .font(.headline)
                        .lineLimit(1)
                    if let followersCount = user.followersCount {
                        Text("\(followersCount.formatted()) \(followersCount == 1 ? "follower" : "followers")")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .multilineTextAlignment(.center)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.primary.opacity(0.06))
                    .opacity(isHovering ? 1 : 0)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.25),
                        value: isHovering
                    )
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onContentHover { isHovering = $0 }
        .contentHelp("View profile: \(user.username)")
        .accessibilityLabel("View profile: \(user.username)")
        .modifier(UserFadeIn())
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

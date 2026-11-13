import SwiftUI

struct UserGridView: View {
    let users: [SoundCloudUser]
    let artworkLoader: ArtworkLoader
    let onSelectArtist: (SoundCloudUser) -> Void
    var nextPageURL: URL? = nil
    var onReachEnd: () async -> Void = {}

    // Avoid nesting this in another lazy stack: while nested, scrolling hung the main
    // thread in an endless lazy layout loop. An eager parent would build a footer spinner
    // right away, so paging starts from the last card, which stays lazy.
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: UserGridCard.minimumWidth), spacing: 0)], spacing: 0) {
            ForEach(users, id: \.permalinkURL) { user in
                let nextPage = users.last?.permalinkURL == user.permalinkURL ? nextPageURL : nil
                UserGridCard(
                    user: user,
                    artworkLoader: artworkLoader,
                    onSelectArtist: onSelectArtist
                )
                // Keyed by URL so that a page of only duplicates still loads the next one.
                .task(id: nextPage) {
                    if nextPage != nil { await onReachEnd() }
                }
            }
        }
        #if DEBUG
        .debugViewUpdates("UserGridView")
        #endif
    }
}

// Keep pointer changes local to the card instead of updating the whole grid.
struct UserGridCard: View {
    let user: SoundCloudUser
    let artworkLoader: ArtworkLoader
    let onSelectArtist: (SoundCloudUser) -> Void

    static let minimumWidth: CGFloat = 164
    /// The space between the card's edge and its avatar.
    static let avatarInset: CGFloat = 22

    @Environment(\.colorScheme) private var colorScheme
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
                .scaleEffect(isHovering && !reduceMotion ? 1.1 : 1)
                .clipShape(Circle())
                .modifier(PlayerArtworkGlass(
                    cornerRadius: 60,
                    size: CGSize(width: 120, height: 120)
                ))
                .animation(
                    reduceMotion ? nil : isHovering
                        ? .spring(response: 0.35, dampingFraction: 0.75)
                        : .spring(duration: 0.34, bounce: 0),
                    value: isHovering
                )
                VStack(spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(user.username)
                            .lineLimit(1)
                        if user.isVerified == true {
                            VerifiedBadge()
                        }
                    }
                    .font(.headline)
                    // Keep the line when the count is unknown so that every card is the
                    // same height, which keeps the grid's estimates for unbuilt rows accurate.
                    Text(user.followersCount.map {
                        "\($0.formatted(.number.notation(.compactName))) \($0 == 1 ? "follower" : "followers")"
                    } ?? " ")
                    .font(.caption)
                    .foregroundStyle(colorScheme == .light ? HierarchicalShapeStyle.secondary : .tertiary)
                }
                .multilineTextAlignment(.center)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(Self.avatarInset - 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The pointer sweeps across cards in the grid, so only a press prefetches.
        .prefetch(.artist(user), .pressOnly) { isHovering = $0 }
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

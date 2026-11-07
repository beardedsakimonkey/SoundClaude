import SwiftUI

struct ArtistLink: View {
    let artist: SoundCloudUser
    var artworkLoader: ArtworkLoader? = nil
    var avatarSize: CGFloat = 24
    var showsAvatarBorder = false
    var showsVerifiedBadge = false
    var helpTitle = "View artist"
    let onSelect: (SoundCloudUser) -> Void

    @State private var isHovering = false

    var body: some View {
        Button {
            onSelect(artist)
        } label: {
            HStack(spacing: 8) {
                if let artworkLoader {
                    TrackArtworkView(
                        artworkURL: artist.avatarURL,
                        loader: artworkLoader,
                        size: avatarSize,
                        showsBorder: false,
                        showsPlaceholderIcon: false
                    )
                    .clipShape(Circle())
                    .overlay {
                        if showsAvatarBorder {
                            Circle()
                                .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                        }
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(artist.username)
                        .underline(isHovering)
                        .lineLimit(1)
                    if showsVerifiedBadge, artist.isVerified == true {
                        VerifiedBadge()
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .artistContextMenu(artist: artist)
        .prefetch(.artist(artist)) { isHovering = $0 }
        .contentHelp(helpTitle)
        .accessibilityLabel("\(helpTitle): \(artist.username)")
    }
}

struct VerifiedBadge: View {
    var body: some View {
        Image(systemName: "checkmark.seal.fill")
            .foregroundStyle(.white, .blue)
            .contentHelp("Verified")
            .accessibilityLabel("Verified")
    }
}

// Shared by artist links in detail views and the player footer.
extension View {
    func artistContextMenu(artist: SoundCloudUser) -> some View {
        modifier(ArtistContextMenu(artist: artist))
    }
}

extension EnvironmentValues {
    @Entry var openArtistStation: (SoundCloudUser) -> Void = { _ in }
}

private struct ArtistContextMenu: ViewModifier {
    let artist: SoundCloudUser
    @Environment(\.openArtistStation) private var openArtistStation

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Start station", systemImage: "dot.radiowaves.left.and.right") {
                openArtistStation(artist)
            }
            .keyboardShortcut(nil)
        }
    }
}

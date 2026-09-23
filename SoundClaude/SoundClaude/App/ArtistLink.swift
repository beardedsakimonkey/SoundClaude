import SwiftUI

struct ArtistLink: View {
    let artist: SoundCloudUser
    var artworkLoader: ArtworkLoader? = nil
    var avatarSize: CGFloat = 24
    var showsAvatarBorder = false
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
                Text(artist.username)
                    .underline(isHovering)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onContentHover { isHovering = $0 }
        .help("View artist")
        .accessibilityLabel("View artist: \(artist.username)")
    }
}

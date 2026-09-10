import SwiftUI

struct ArtistLink: View {
    let artist: SoundCloudUser
    var artworkLoader: ArtworkLoader? = nil
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
                        size: 24,
                        showsBorder: false
                    )
                    .clipShape(Circle())
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

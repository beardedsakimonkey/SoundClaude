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
                        size: 24
                    )
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                    }
                }
                Text(artist.username)
                    .underline(isHovering)
                    .multilineTextAlignment(.leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("View artist: \(artist.username)")
        .accessibilityLabel("View artist: \(artist.username)")
    }
}

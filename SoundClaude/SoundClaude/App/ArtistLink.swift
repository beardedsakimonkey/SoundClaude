import SwiftUI

struct ArtistLink: View {
    let artist: SoundCloudUser
    let onSelect: (SoundCloudUser) -> Void

    @State private var isHovering = false

    var body: some View {
        Button {
            onSelect(artist)
        } label: {
            Text(artist.username)
                .underline(isHovering)
                .multilineTextAlignment(.leading)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("View artist: \(artist.username)")
        .accessibilityLabel("View artist: \(artist.username)")
    }
}

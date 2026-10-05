import SwiftUI

struct NowPlayingTrackRow: View {
    let track: SoundCloudTrack?
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHoveringTrackTitle = false

    var body: some View {
        // The placeholder alone sizes the row. Track transitions stay in an
        // overlay and cannot remeasure the detail header.
        Text(" ")
            .hidden()
            .accessibilityHidden(true)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .overlay(alignment: .leading) {
                if let track {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Button {
                            onSelectTrack(track)
                        } label: {
                            Text(track.title)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .underline(isHoveringTrackTitle)
                        }
                        .buttonStyle(.plain)
                        .onContentHover { isHoveringTrackTitle = $0 }
                        .contentHelp("View track: \(track.title)")
                        .accessibilityLabel("View track: \(track.title)")
                        Text("by")
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        ArtistLink(artist: track.artist, onSelect: onSelectArtist)
                    }
                    .foregroundStyle(.primary)
                    .opacity(0.9)
                    .geometryGroup()
                    .id(track.urn)
                    .transition(reduceMotion ? .identity : .opacity)
                }
            }
        .font(.title2)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.3),
            value: track?.urn
        )
        .onChange(of: track?.urn) { _, _ in
            isHoveringTrackTitle = false
        }
    }
}

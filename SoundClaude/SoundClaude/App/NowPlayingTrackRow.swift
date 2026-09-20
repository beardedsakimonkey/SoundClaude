import SwiftUI

struct NowPlayingTrackRow: View {
    let track: SoundCloudTrack?
    let isPlaying: Bool
    let isLoading: Bool
    let analyzer: SpectrumAnalyzer
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHoveringTrackTitle = false

    var body: some View {
        ZStack(alignment: .leading) {
            Text(" ")
                .font(.title3)
                .hidden()
                .accessibilityHidden(true)
            if let track = track {
                HStack(spacing: 6) {
                    TrackPlaybackIndicator(
                        isPlaying: isPlaying,
                        isLoading: isLoading,
                        analyzer: analyzer,
                        color: (colorScheme == .dark ? Color.white : Color.black).opacity(0.6)
                    )
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
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
                        .help("View track: \(track.title)")
                        .accessibilityLabel("View track: \(track.title)")
                        Text("by")
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                        ArtistLink(artist: track.artist, onSelect: onSelectArtist)
                    }
                    .font(.title3)
                    .foregroundStyle(.secondary)
                }
                // Keep row movement separate from the indicator's bar animations.
                .geometryGroup()
                .id(track.urn)
                .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.3),
            value: track?.urn
        )
    }
}

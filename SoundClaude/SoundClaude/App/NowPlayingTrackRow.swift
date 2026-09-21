import SwiftUI

struct NowPlayingTrackRow: View {
    let track: SoundCloudTrack?
    let isPlaying: Bool
    let isLoading: Bool
    let analyzer: SpectrumAnalyzer
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    var appearanceDelay: Duration = .zero

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHoveringTrackTitle = false
    @State private var isContentReady = false

    private var visibleTrack: SoundCloudTrack? {
        isContentReady || appearanceDelay == .zero || reduceMotion ? track : nil
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Text(" ")
                .font(.title3)
                .hidden()
                .accessibilityHidden(true)
            if let track = visibleTrack {
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
            value: visibleTrack?.urn
        )
        .task(id: track != nil) {
            guard track != nil else {
                isContentReady = false
                return
            }
            guard !isContentReady else { return }
            // Defer constructing the indicator so its timeline does not compete
            // with the waveform's initial bar animation.
            if !reduceMotion, appearanceDelay > .zero {
                do {
                    try await Task.sleep(for: appearanceDelay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            isContentReady = true
        }
    }
}

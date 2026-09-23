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
    @State private var readyTrackURN: String?

    private var visibleTrack: SoundCloudTrack? {
        readyTrackURN == track?.urn || appearanceDelay == .zero || reduceMotion ? track : nil
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Text(" ")
                .hidden()
                .accessibilityHidden(true)
            if let track = visibleTrack {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle((colorScheme == .dark ? Color.white : Color.black).opacity(0.8))
                        .fixedSize()
                        .accessibilityLabel(isLoading ? "Loading" : isPlaying ? "Now playing" : "Paused")
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
                        .help("View track: \(track.title)")
                        .accessibilityLabel("View track: \(track.title)")
                        Text("by")
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        ArtistLink(artist: track.artist, onSelect: onSelectArtist)
                    }
                    .foregroundStyle(.primary)
                    .opacity(0.9)
                }
                .geometryGroup()
                .id(track.urn)
                .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .font(.title2)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.3),
            value: visibleTrack?.urn
        )
        .task(id: track?.urn) {
            readyTrackURN = nil
            isHoveringTrackTitle = false
            guard let track else { return }
            // Delay the row's appearance until the waveform animation has started.
            if !reduceMotion, appearanceDelay > .zero {
                do {
                    try await Task.sleep(for: appearanceDelay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            readyTrackURN = track.urn
        }
    }
}

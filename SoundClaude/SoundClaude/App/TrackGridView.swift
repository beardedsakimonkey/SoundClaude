import SwiftUI

enum TrackLayout: String, CaseIterable {
    case grid
    case list

    var title: String { self == .grid ? "Grid view" : "List view" }
    var symbol: String { self == .grid ? "square.grid.2x2.fill" : "list.bullet" }
}

struct TrackLayoutPicker: View {
    @Binding var trackLayout: TrackLayout

    var body: some View {
        HStack(spacing: 4) {
            ForEach(TrackLayout.allCases, id: \.self) { layout in
                Button {
                    trackLayout = layout
                } label: {
                    Image(systemName: layout.symbol)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                        .foregroundStyle(trackLayout == layout ? Color.accentColor : Color.secondary)
                        .background {
                            if trackLayout == layout {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.accentColor.opacity(0.12))
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(layout.title)
                .accessibilityLabel(layout.title)
                .accessibilityAddTraits(trackLayout == layout ? .isSelected : [])
            }
        }
    }
}

struct TrackGridTile: View {
    let track: SoundCloudTrack
    let playback: PlaybackController
    let analyzer: SpectrumAnalyzer
    let artworkLoader: ArtworkLoader
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    let onPlayTrack: (SoundCloudTrack) async -> Void

    @State private var isHoveringArtwork = false
    @State private var isHoveringTitle = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isCurrentTrack: Bool {
        playback.currentTrack?.urn == track.urn
    }

    var body: some View {
        let isPlaybackActive = isCurrentTrack && playback.isPlaybackActive

        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                Button {
                    if isCurrentTrack {
                        playback.togglePlayPause()
                    } else {
                        Task { await onPlayTrack(track) }
                    }
                } label: {
                    TrackArtworkView(
                        artworkURL: track.displayArtworkURL,
                        loader: artworkLoader,
                        size: geometry.size.width,
                        rendition: .square500,
                        shape: RoundedRectangle(cornerRadius: 8)
                    )
                    .overlay {
                        if isHoveringArtwork || isCurrentTrack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.black.opacity(0.35))
                                .overlay {
                                    Image(systemName: isPlaybackActive ? "pause.fill" : "play.fill")
                                        .font(.system(size: 32, weight: .semibold))
                                        .foregroundStyle(.white)
                                }
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .buttonStyle(.plain)
                .onContentHover { isHoveringArtwork = $0 }
                .help(isPlaybackActive ? "Pause" : "Play")
                .accessibilityLabel("\(isPlaybackActive ? "Pause" : "Play"): \(track.title)")
            }
            .aspectRatio(1, contentMode: .fit)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Button {
                        onSelectTrack(track)
                    } label: {
                        HStack(spacing: 6) {
                            if isCurrentTrack {
                                TrackPlaybackIndicator(
                                    isPlaying: playback.isPlaying,
                                    isLoading: playback.isLoading,
                                    analyzer: analyzer
                                )
                            }
                            Text(track.title)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(isCurrentTrack ? Color.orange : Color.primary)
                                .underline(isHoveringTitle)
                                .multilineTextAlignment(.leading)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                        .animation(
                            reduceMotion ? nil : .easeInOut(duration: 0.2),
                            value: isCurrentTrack
                        )
                    }
                    .buttonStyle(.plain)
                    .onContentHover { isHoveringTitle = $0 }
                    .help(track.title)
                    if track.access == .preview {
                        TrackPreviewBadge()
                    }
                }

                ArtistLink(artist: track.artist, onSelect: onSelectArtist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

        }
    }
}

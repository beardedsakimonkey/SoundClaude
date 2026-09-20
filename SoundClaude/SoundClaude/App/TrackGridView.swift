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
    private static let artworkCornerRadius: CGFloat = 10

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
                        shape: RoundedRectangle(cornerRadius: Self.artworkCornerRadius, style: .continuous),
                        showsBorder: false
                    )
                    .scaleEffect(isHoveringArtwork && !reduceMotion ? 1.08 : 1)
                    .clipShape(RoundedRectangle(cornerRadius: Self.artworkCornerRadius, style: .continuous))
                    .modifier(PlayerArtworkGlass(
                        cornerRadius: Self.artworkCornerRadius,
                        isHovering: isHoveringArtwork && !reduceMotion
                    ))
                    .animation(
                        reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.75),
                        value: isHoveringArtwork
                    )
                    .overlay {
                        if isHoveringArtwork || isCurrentTrack {
                            Image(systemName: isPlaybackActive ? "pause.fill" : "play.fill")
                                .font(.system(size: 32, weight: .semibold))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 1)
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
                        Text(track.title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(isCurrentTrack ? Color.orange : Color.primary)
                            .underline(isHoveringTitle)
                            .multilineTextAlignment(.leading)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onContentHover { isHoveringTitle = $0 }
                    .help(track.title)
                    if track.access == .preview {
                        TrackPreviewBadge()
                    }
                }
                .modifier(TrackPlaybackTitleInset(inset: isCurrentTrack ? 16 : 0))
                .overlay(alignment: .leading) {
                    if isCurrentTrack {
                        TrackPlaybackIndicator(
                            isPlaying: playback.isPlaying,
                            isLoading: playback.isLoading,
                            analyzer: analyzer
                        )
                    }
                }
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.2),
                    value: isCurrentTrack
                )

                ArtistLink(artist: track.artist, onSelect: onSelectArtist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

        }
    }
}

import SwiftUI

enum TrackLayout: String, CaseIterable {
    case grid
    case list

    var title: String { self == .grid ? "Grid view" : "List view" }
    var symbol: String { self == .grid ? "square.grid.2x2.fill" : "list.bullet" }
}

struct TrackLayoutPicker: View {
    @Binding var trackLayout: TrackLayout
    @State private var hoveredLayout: TrackLayout?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(TrackLayout.allCases, id: \.self) { layout in
                let isSelected = trackLayout == layout
                let isHovered = hoveredLayout == layout && !isSelected

                Button {
                    trackLayout = layout
                } label: {
                    Image(systemName: layout.symbol)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                        .foregroundStyle(trackLayout == layout ? Color.accentColor : Color.secondary)
                        .background {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isSelected
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.primary.opacity(isHovered ? 0.1 : 0))
                        }
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovered)
                }
                .buttonStyle(.plain)
                .onContentHover { isHovering in
                    if isHovering {
                        hoveredLayout = layout
                    } else if hoveredLayout == layout {
                        hoveredLayout = nil
                    }
                }
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
    @ObservedObject var likes: LikesController
    let onAddToQueue: (SoundCloudTrack) -> Void
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    let onPlayTrack: (SoundCloudTrack) async -> Void

    @State private var isHoveringArtwork = false
    @State private var isHoveringTitle = false
    @State private var isHoveringMenu = false
    @State private var likeErrorMessage: String?
    @Environment(\.addToPlaylist) private var addToPlaylist
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
                        AnimatedPlayPauseIcon(isPlaybackActive: isPlaybackActive, size: 32)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 1)
                            .scaleEffect(reduceMotion || isHoveringArtwork || isCurrentTrack ? 1 : 0.8)
                            .opacity(isHoveringArtwork || isCurrentTrack ? 1 : 0)
                            .animation(
                                reduceMotion ? nil : .easeInOut(duration: 0.15),
                                value: isHoveringArtwork || isCurrentTrack
                            )
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
                .help(isPlaybackActive ? "Pause" : "Play")
                .accessibilityLabel("\(isPlaybackActive ? "Pause" : "Play"): \(track.title)")
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .bottomTrailing) {
                overflowMenu
                    .padding(8)
                    .opacity(isHoveringArtwork ? 1 : 0)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.15),
                        value: isHoveringArtwork
                    )
                    .allowsHitTesting(isHoveringArtwork)
                    .accessibilityHidden(!isHoveringArtwork)
            }
            .onContentHover { isHoveringArtwork = $0 }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Button {
                        onSelectTrack(track)
                    } label: {
                        Text(track.title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(isCurrentTrack ? Color.accentColor : Color.primary)
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
        .alert("Could not update like", isPresented: Binding(
            get: { likeErrorMessage != nil },
            set: { if !$0 { likeErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { likeErrorMessage = nil }
        } message: {
            Text(likeErrorMessage ?? "Please try again.")
        }
    }

    private var overflowMenu: some View {
        let isLiked = likes.isLiked(track)

        return Menu {
            Button("Add to queue", systemImage: "text.line.last.and.arrowtriangle.forward") {
                onAddToQueue(track)
            }
            Button("Add to playlist", systemImage: "music.note.list") {
                addToPlaylist(track)
            }
            Button(isLiked ? "Unlike" : "Like", systemImage: isLiked ? "heart.fill" : "heart") {
                Task {
                    do {
                        try await likes.toggleLike(track)
                    } catch is CancellationError {
                    } catch {
                        likeErrorMessage = error.localizedDescription
                    }
                }
            }
            .disabled(likes.updatingTrackURNs.contains(track.urn))
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(.black.opacity(isHoveringMenu ? 0.75 : 0.55), in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More options for \(track.title)")
        .help("More options")
        .onContentHover { isHoveringMenu = $0 }
    }
}

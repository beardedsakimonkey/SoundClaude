import SwiftUI

struct TrackListRow: View {
    let track: SoundCloudTrack
    let playback: PlaybackController
    let artworkLoader: ArtworkLoader
    @ObservedObject var likes: LikesController
    var showsLikedIndicator = true
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    let onPlayTrack: (SoundCloudTrack) async -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var isHoveringArtwork = false
    @State private var isHoveringTitle = false
    @State private var isHoveringArtist = false
    @GestureState private var isPressed = false

    var body: some View {
        let isCurrentTrack = playback.currentTrack?.urn == track.urn
        let isPlaybackActive = isCurrentTrack && playback.isPlaybackActive

        HStack(spacing: 12) {
            Button(action: playOrPauseTrack) {
                TrackArtworkView(
                    artworkURL: track.displayArtworkURL,
                    loader: artworkLoader,
                    size: 44,
                )
                .overlay {
                    ZStack {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.black.opacity(0.45))
                        ZStack {
                            Image(systemName: isPlaybackActive ? "pause.fill" : "play.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.white)
                                .opacity(0.9)
                                .id(isPlaybackActive)
                                .transition(reduceMotion ? .identity : .scale(scale: 0.01).combined(with: .opacity))
                        }
                        .animation(
                            reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.6),
                            value: isPlaybackActive
                        )
                    }
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .buttonStyle(.plain)
            .onContentHover { isHoveringArtwork = $0 }
            .help(isPlaybackActive ? "Pause" : "Play")
            .accessibilityLabel("\(isPlaybackActive ? "Pause" : "Play"): \(track.title)")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if isCurrentTrack {
                        TrackPlaybackIndicator(isPlaying: playback.isPlaying)
                    }
                    Button {
                        onSelectTrack(track)
                    } label: {
                        Text(track.title)
                            .underline(isHoveringTitle)
                            .foregroundStyle(isCurrentTrack ? Color.orange : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .opacity(0.9)
                    .onContentHover { isHoveringTitle = $0 }
                    if track.access == .preview {
                        TrackPreviewBadge()
                    }
                }
                ArtistLink(artist: track.artist, onSelect: onSelectArtist)
                    .font(.caption)
                    .foregroundStyle(isCurrentTrack ? Color.orange : Color.secondary)
                    .onContentHover { isHoveringArtist = $0 }
            }
            .lineLimit(1)
            Spacer()
            if showsLikedIndicator && likes.isLiked(track) {
                Image(systemName: "heart.fill")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.7))
                    .help("Liked")
                    .accessibilityLabel("Liked")
            }
            Text(duration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isHoveringArtwork, !isHoveringTitle, !isHoveringArtist else { return }
            playOrPauseTrack()
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .updating($isPressed) { _, pressed, _ in
                    pressed = true
                }
        )
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(rowBackground)
        }
        .onContentHover { isHovering = $0 }
        .accessibilityAction(named: isPlaybackActive ? "Pause" : "Play") {
            playOrPauseTrack()
        }
    }

    private func playOrPauseTrack() {
        if playback.currentTrack?.urn == track.urn {
            playback.togglePlayPause()
        } else {
            Task { await onPlayTrack(track) }
        }
    }

    private var rowBackground: Color {
        if isPressed {
            return Color.white.opacity(0.12)
        }
        return isHovering ? Color.primary.opacity(0.06) : Color.clear
    }

    private var duration: String {
        let seconds = max(track.durationMilliseconds, 0) / 1_000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct TrackPreviewBadge: View {
    var font: Font = .caption

    var body: some View {
        Text("Preview")
            .font(font.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
            .fixedSize()
            .help("Only a preview of this track is available.")
            .accessibilityLabel("Preview only")
    }
}

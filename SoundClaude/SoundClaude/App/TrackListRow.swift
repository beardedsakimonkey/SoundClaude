import SwiftUI

struct TrackListRow: View {
    let track: SoundCloudTrack
    let playback: PlaybackController
    let artworkLoader: ArtworkLoader
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    let onPlayTrack: (SoundCloudTrack) async -> Void

    @State private var isHovering = false
    @State private var isHoveringArtwork = false
    @State private var isHoveringTitle = false
    @State private var isHoveringArtist = false
    @GestureState private var isPressed = false

    var body: some View {
        let isCurrentTrack = playback.currentTrack?.urn == track.urn

        HStack(spacing: 12) {
            Button {
                onSelectTrack(track)
            } label: {
                TrackArtworkView(
                    artworkURL: track.artworkURL,
                    loader: artworkLoader,
                    size: 44
                )
            }
            .buttonStyle(TrackArtworkButtonStyle())
            .onContentHover { isHoveringArtwork = $0 }
            .accessibilityLabel("Open track: \(track.title)")
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
            Text(duration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isHoveringArtwork, !isHoveringTitle, !isHoveringArtist else { return }
            Task { await onPlayTrack(track) }
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
                .animation(.easeInOut(duration: 0.15), value: isHovering)
        }
        .onContentHover { isHovering = $0 }
        .accessibilityAction(named: "Play") {
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

private struct TrackArtworkButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? 0.92 : 1)
            .animation(
                reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.4),
                value: configuration.isPressed && isEnabled
            )
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

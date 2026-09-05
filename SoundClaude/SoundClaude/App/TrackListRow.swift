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

    var body: some View {
        HStack(spacing: 12) {
            Button {
                onSelectTrack(track)
            } label: {
                TrackArtworkView(
                    artworkURL: track.artworkURL,
                    loader: artworkLoader,
                    size: 44
                )
                .overlay(alignment: .bottomTrailing) {
                    if playback.currentTrack?.urn == track.urn {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(.orange, in: Circle())
                            .padding(2)
                    }
                }
            }
            .buttonStyle(.plain)
            .onHover { isHoveringArtwork = $0 }
            .accessibilityLabel("Open track: \(track.title)")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Button {
                        onSelectTrack(track)
                    } label: {
                        Text(track.title)
                            .underline(isHoveringTitle)
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .onHover { isHoveringTitle = $0 }
                    if track.access == .preview {
                        TrackPreviewBadge()
                    }
                }
                ArtistLink(artist: track.artist, onSelect: onSelectArtist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .onHover { isHoveringArtist = $0 }
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
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(hoverBackground)
                .animation(.easeInOut(duration: 0.15), value: isHovering)
        }
        .onHover { isHovering = $0 }
        .accessibilityAction(named: "Play") {
            Task { await onPlayTrack(track) }
        }
    }

    private var hoverBackground: Color {
        isHovering ? Color.primary.opacity(0.06) : Color.clear
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

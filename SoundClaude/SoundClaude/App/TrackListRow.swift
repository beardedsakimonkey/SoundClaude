import SwiftUI

struct TrackListRow: View {
    let track: SoundCloudTrack
    let playback: PlaybackController
    let analyzer: SpectrumAnalyzer
    let artworkLoader: ArtworkLoader
    @ObservedObject var likes: LikesController
    var showsArtist = true
    var isCompact = false
    var trackNumber: Int? = nil
    let onAddToQueue: (SoundCloudTrack) -> Void
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    let onPlayTrack: (SoundCloudTrack) async -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var isHoveringArtwork = false
    @State private var isHoveringTitle = false
    @State private var isHoveringArtist = false
    @State private var isHoveringMenu = false
    @GestureState private var isPressed = false

    var body: some View {
        let isCurrentTrack = playback.currentTrack?.urn == track.urn
        let isPlaybackActive = isCurrentTrack && playback.isPlaybackActive

        HStack(spacing: 12) {
            Button(action: playOrPauseTrack) {
                TrackArtworkView(
                    artworkURL: track.displayArtworkURL,
                    loader: artworkLoader,
                    size: isCompact ? 32 : 44,
                )
                .overlay {
                    ZStack {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.black.opacity(0.45))
                        ZStack {
                            Image(systemName: isPlaybackActive ? "pause.fill" : "play.fill")
                                .font(.system(size: isCompact ? 16 : 20, weight: .semibold))
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
            if let trackNumber {
                Text(trackNumber.formatted())
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 20, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Button {
                        onSelectTrack(track)
                    } label: {
                        Text(track.title)
                            .underline(isHoveringTitle)
                            .foregroundStyle(isCurrentTrack ? Color.orange : Color.primary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(0.9)
                    .onContentHover { isHoveringTitle = $0 }
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
                        .opacity(0.9)
                    }
                }
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.2),
                    value: isCurrentTrack
                )
                if showsArtist {
                    HStack(spacing: 4) {
                        ArtistLink(artist: track.artist, onSelect: onSelectArtist)
                            .onContentHover { isHoveringArtist = $0 }
                        if let likeCount = likes.likeCount(for: track) {
                            Text("·")
                                .accessibilityHidden(true)
                            HStack(spacing: 2) {
                                Image(systemName: "heart")
                                Text(likeCount.formatted())
                            }
                            .fixedSize()
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(likeCount.formatted()) likes")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(isCurrentTrack ? Color.orange : Color.secondary)
                }
            }
            .lineLimit(1)
            Spacer()
            if likes.isLiked(track) {
                Image(systemName: "heart.fill")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.7))
                    .help("Liked")
                    .accessibilityLabel("Liked")
            }
            Text(duration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
                // Keep the duration's width so hover does not change text truncation.
                .opacity(isHovering ? 0 : 1)
                .overlay {
                    Menu {
                        Button("Add to queue") {
                            onAddToQueue(track)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 28, height: 28)
                            .contentShape(Circle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .background {
                        Circle()
                            .fill(Color.primary.opacity(isHoveringMenu ? 0.1 : 0))
                            .frame(width: 28, height: 28)
                    }
                    .contentShape(Circle())
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(isHovering)
                    .accessibilityHidden(!isHovering)
                    .accessibilityLabel("More options for \(track.title)")
                    .help("More options")
                    .onContentHover { isHoveringMenu = $0 }
                }
        }
        .padding(.vertical, isCompact ? 4 : 6)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isHoveringArtwork, !isHoveringTitle, !isHoveringArtist, !isHoveringMenu else { return }
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
            .overlay {
                Capsule()
                    .strokeBorder(.secondary.opacity(0.35), lineWidth: 1)
            }
            .fixedSize()
            .help("Only a preview of this track is available.")
            .accessibilityLabel("Preview only")
    }
}

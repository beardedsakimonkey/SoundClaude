import SwiftUI

/// A reusable track presentation. The caller supplies navigation and queue behavior.
struct TrackCardView: View {
    let track: SoundCloudTrack
    let model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    let onPlayTrack: (SoundCloudTrack) async -> Void

    @State private var isHoveringTitle = false

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            Button {
                onSelectTrack(track)
            } label: {
                TrackArtworkView(
                    artworkURL: track.artworkURL,
                    loader: model.artworkLoader,
                    size: 140,
                    rendition: .square500
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open track: \(track.title)")

            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    if let genre = track.genre?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !genre.isEmpty {
                        HStack(alignment: .top, spacing: 12) {
                            trackTitle
                                .fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: 0)
                            GenrePill(genre: genre)
                        }
                    }
                    trackTitle
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ArtistLink(artist: track.artist, onSelect: onSelectArtist)
                    .font(.callout)
                    .foregroundStyle(isCurrentTrack ? Color.orange : Color.secondary)
                    .lineLimit(1)

                HStack(spacing: 10) {
                    playButton
                    if track.access == .preview {
                        TrackPreviewBadge()
                    }
                    TrackWaveformView(
                        track: track,
                        model: model,
                        layout: .compact,
                        onPlayTrack: onPlayTrack
                    )
                    .frame(maxWidth: .infinity)
                }

                HStack(spacing: 20) {
                    statistic(track.likesCount, label: "likes", systemImage: "heart")
                    statistic(track.repostsCount, label: "reposts", systemImage: "arrow.2.squarepath")
                    statistic(track.commentCount, label: "comments", systemImage: "bubble.right")
                    Spacer(minLength: 0)
                    Text(duration)
                        .monospacedDigit()
                        .accessibilityLabel("Duration: \(duration)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 140, alignment: .top)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var trackTitle: some View {
        HStack(spacing: 6) {
            if isCurrentTrack {
                TrackPlaybackIndicator(isPlaying: model.playback.isPlaying)
            }
            Button {
                onSelectTrack(track)
            } label: {
                Text(track.title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(isCurrentTrack ? Color.orange : Color.primary)
                    .underline(isHoveringTitle)
                    .multilineTextAlignment(.leading)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .onHover { isHoveringTitle = $0 }
            .help(track.title)
        }
    }

    private var isCurrentTrack: Bool {
        model.playback.currentTrack?.urn == track.urn
    }

    private var playButton: some View {
        let isPlaying = isCurrentTrack && model.playback.isPlaying

        return Button {
            if isCurrentTrack {
                model.playback.togglePlayPause()
            } else {
                Task { await onPlayTrack(track) }
            }
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .help(isPlaying ? "Pause" : "Play")
        .accessibilityLabel("\(isPlaying ? "Pause" : "Play") \(track.title)")
    }

    private func statistic(_ count: Int?, label: String, systemImage: String) -> some View {
        Label(count?.formatted(.number.notation(.compactName)) ?? "—", systemImage: systemImage)
            .monospacedDigit()
            .fixedSize()
            .help(count.map { "\($0.formatted()) \(label)" } ?? "\(label.capitalized) unavailable")
            .accessibilityLabel(
                count.map { "\($0.formatted()) \(label)" } ?? "\(label.capitalized) unavailable"
            )
    }

    private var duration: String {
        let seconds = max(track.durationMilliseconds, 0) / 1_000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

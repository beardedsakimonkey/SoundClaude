import SwiftUI

/// A reusable track presentation. The caller supplies navigation and queue behavior.
struct TrackCardView: View {
    let track: SoundCloudTrack
    let model: AppModel
    @ObservedObject private var reposts: RepostsController
    @ObservedObject private var likes: LikesController
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    let onPlayTrack: (SoundCloudTrack) async -> Void

    @State private var repostErrorMessage: String?
    @State private var isHoveringTitle = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        track: SoundCloudTrack,
        model: AppModel,
        onSelectTrack: @escaping (SoundCloudTrack) -> Void,
        onSelectArtist: @escaping (SoundCloudUser) -> Void,
        onPlayTrack: @escaping (SoundCloudTrack) async -> Void
    ) {
        self.track = track
        self.model = model
        _reposts = ObservedObject(wrappedValue: model.reposts)
        _likes = ObservedObject(wrappedValue: model.likes)
        self.onSelectTrack = onSelectTrack
        self.onSelectArtist = onSelectArtist
        self.onPlayTrack = onPlayTrack
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            Button {
                onSelectTrack(track)
            } label: {
                TrackArtworkView(
                    artworkURL: track.displayArtworkURL,
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

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ArtistLink(artist: track.artist, onSelect: onSelectArtist)
                        .foregroundStyle(Color.secondary)

                    RelativeTimestampView(
                        timestamp: track.createdAt,
                        accessibilityPrefix: "Created"
                    )
                    .foregroundStyle(.tertiary)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                HStack(spacing: 10) {
                    playButton
                    TrackWaveformView(
                        track: track,
                        model: model,
                        layout: .compact,
                        onPlayTrack: onPlayTrack
                    )
                    .frame(maxWidth: .infinity)
                }

                HStack(spacing: 10) {
                    likeButton
                    repostButton
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
        .task {
            // Retry on click and show any error there, once for the selected card.
            try? await reposts.load()
        }
        .alert("Could not update repost", isPresented: Binding(
            get: { repostErrorMessage != nil },
            set: { if !$0 { repostErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { repostErrorMessage = nil }
        } message: {
            Text(repostErrorMessage ?? "Please try again.")
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
        HStack(alignment: .center, spacing: 6) {
            Button {
                onSelectTrack(track)
            } label: {
                HStack(spacing: 6) {
                    if isCurrentTrack {
                        TrackPlaybackIndicator(
                            isPlaying: model.playback.isPlaying,
                            isLoading: model.playback.isLoading,
                            analyzer: model.analyzer
                        )
                    }
                    Text(track.title)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(isCurrentTrack ? Color.orange : Color.primary)
                        .underline(isHoveringTitle)
                        .multilineTextAlignment(.leading)
                        .lineLimit(1)
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
    }

    private var isCurrentTrack: Bool {
        model.playback.currentTrack?.urn == track.urn
    }

    private var playButton: some View {
        let isPlaying = isCurrentTrack && model.playback.isPlaybackActive

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

    private var likeButton: some View {
        let isLiked = likes.isLiked(track)

        return Button {
            Task {
                do {
                    try await likes.toggleLike(track)
                } catch {
                    model.likeErrorMessage = error.localizedDescription
                }
            }
        } label: {
            statistic(
                likes.likeCount(for: track),
                label: "likes",
                systemImage: isLiked ? "heart.fill" : "heart"
            )
        }
        .buttonStyle(TrackStatisticButtonStyle(color: .orange, isSelected: isLiked))
        .disabled(likes.updatingTrackURNs.contains(track.urn))
        .help(isLiked ? "Unlike track" : "Like track")
        .accessibilityLabel(isLiked ? "Unlike track" : "Like track")
        .accessibilityValue(isLiked ? "Liked" : "Not liked")
    }

    private var repostButton: some View {
        let isReposted = reposts.isReposted(track)
        return Button {
            Task {
                do {
                    try await reposts.toggleRepost(track)
                } catch is CancellationError {
                } catch {
                    repostErrorMessage = error.localizedDescription
                }
            }
        } label: {
            statistic(reposts.repostCount(for: track), label: "reposts", systemImage: "arrow.2.squarepath")
        }
        .buttonStyle(TrackStatisticButtonStyle(color: .green, isSelected: isReposted))
        .disabled(reposts.isLoading || reposts.updatingTrackURNs.contains(track.urn))
        .help(isReposted ? "Undo repost" : "Repost track")
        .accessibilityLabel(isReposted ? "Undo repost" : "Repost track")
        .accessibilityValue(isReposted ? "Reposted" : "Not reposted")
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

private struct TrackStatisticButtonStyle: ButtonStyle {
    let color: Color
    var isSelected = false

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let isHighlighted = isHovering && isEnabled

        configuration.label
            .foregroundStyle(isSelected ? color : (isHighlighted ? Color.primary.opacity(0.8) : Color.secondary))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                isSelected ? color.opacity(0.12) : Color.primary.opacity(isHighlighted ? 0.1 : 0.06),
                in: Capsule()
            )
            .brightness(isHighlighted ? 0.05 : 0)
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.5)
            .onContentHover { isHovering = $0 }
    }
}

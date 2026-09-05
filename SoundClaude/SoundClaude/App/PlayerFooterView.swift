import SwiftUI

struct PlayerFooterView: View {
    let model: AppModel
    let artworkLoader: ArtworkLoader
    let onSelectTrack: (SoundCloudTrack) -> Void

    @State private var artworkTrack: SoundCloudTrack?
    @State private var cachedFullSizeArtwork: CachedFullSizeArtwork?
    @State private var isHoveringArtwork = false
    @State private var isHoveringTitle = false
    @State private var likeErrorMessage: String?

    @Bindable private var playback: PlaybackController
    @ObservedObject private var likes: LikesController

    init(
        model: AppModel,
        onSelectTrack: @escaping (SoundCloudTrack) -> Void
    ) {
        self.model = model
        self.artworkLoader = model.artworkLoader
        self.onSelectTrack = onSelectTrack
        self.playback = model.playback
        _likes = ObservedObject(wrappedValue: model.likes)
    }

    var body: some View {
        HStack(spacing: 20) {
            trackIdentity
                .frame(width: 340)
            playbackControls
                .frame(maxWidth: .infinity)
                .layoutPriority(1)
        }
        .padding(14)
        .background {
            TrackArtworkBackdropView(
                artworkURL: playback.currentTrack?.artworkURL,
                loader: artworkLoader,
                fadesToBottom: false,
                animatesChanges: true
            )
            .mask {
                LinearGradient(
                    colors: [.black, .clear],
                    startPoint: .top,
                    endPoint: .center
                )
            }
        }
        .sheet(item: $artworkTrack) { track in
            FullSizeArtworkView(
                title: track.title,
                artworkURL: track.artworkURL,
                loader: artworkLoader,
                cachedArtwork: $cachedFullSizeArtwork
            )
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

    private var trackIdentity: some View {
        HStack(spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 6) {
                if let track = playback.currentTrack {
                    Button {
                        onSelectTrack(track)
                    } label: {
                        Text(track.title)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .underline(isHoveringTitle)
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .onHover { isHoveringTitle = $0 }
                    .help(track.title)
                } else {
                    Text("Select a track")
                }
                Text(playback.currentTrack?.uploader
                    ?? "Choose a track to start listening")
                    .font(.headline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .font(.title2.weight(.semibold))
            .opacity(0.85)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            likeButton
        }
    }

    private var likeButton: some View {
        let track = playback.currentTrack
        let isLiked = track.map { likes.isLiked($0) } ?? false
        let isUpdating = track.map {
            likes.updatingTrackURNs.contains($0.urn)
        } ?? false

        return Button {
            guard let track else { return }
            Task {
                do {
                    try await likes.toggleLike(track)
                } catch {
                    likeErrorMessage = error.localizedDescription
                }
            }
        } label: {
            Image(systemName: isLiked ? "heart.fill" : "heart")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.primary)
                .opacity(0.7)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(track == nil || isUpdating || likes.isLoading)
        .help(isLiked ? "Unlike track" : "Like track")
        .accessibilityLabel(isLiked ? "Unlike track" : "Like track")
        .accessibilityValue(isLiked ? "Liked" : "Not liked")
    }

    @ViewBuilder
    private var artwork: some View {
        if let track = playback.currentTrack, track.artworkURL != nil {
            Button {
                artworkTrack = track
            } label: {
                artworkThumbnail
                    .artworkExpandIndicator(isHovering: isHoveringArtwork)
            }
            .buttonStyle(.plain)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { isHoveringArtwork = $0 }
            .help("View full-size artwork")
            .accessibilityLabel("View full-size artwork for \(track.title)")
        } else {
            artworkThumbnail
        }
    }

    private var artworkThumbnail: some View {
        TrackArtworkView(
            artworkURL: playback.currentTrack?.artworkURL,
            loader: artworkLoader,
            size: 80,
            rendition: .square500
        )
    }

    private var playbackControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 16) {
                transportControls
                VStack(spacing: 4) {
                    if let track = playback.currentTrack {
                        TrackWaveformView(
                            track: track,
                            model: model,
                            layout: .compact
                        )
                            .id(track.urn)
                    } else {
                        Color.clear
                            .frame(height: TrackWaveformView.Layout.compact.height)
                            .accessibilityHidden(true)
                    }

                    HStack {
                        Text(format(seconds: playback.currentTime))
                        Spacer()
                        Text(format(seconds: playback.duration))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                // Compensate for the timestamps below the waveform.
                .offset(y: 8)

                Button(action: playback.toggleMute) {
                    Image(systemName: volumeIcon)
                        .frame(width: 24)
                }
                Slider(value: $playback.volume, in: 0...1)
                    .frame(width: 110)
                    .accessibilityLabel("Volume")
                    .accessibilityValue("\(Int(playback.volume * 100)) percent")
            }
            .buttonStyle(.borderless)

            if let playbackError = playback.errorMessage {
                Text(playbackError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var volumeIcon: String {
        if playback.isMuted || playback.volume == 0 {
            return "speaker.slash.fill"
        } else if playback.volume < 1.0 / 3.0 {
            return "speaker.wave.1.fill"
        } else if playback.volume < 2.0 / 3.0 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }

    private var transportControls: some View {
        Group {
            if #available(macOS 26.0, *) {
                transportButtons
                    .buttonStyle(SpringGlassButtonStyle())
            } else {
                transportButtons
                    .buttonStyle(.bordered)
            }
        }
        .buttonBorderShape(.circle)
        .controlSize(.large)
    }

    private var transportButtons: some View {
        HStack(spacing: 12) {
            Button(action: playback.previous) {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .help("Previous track")
            .accessibilityLabel("Previous track")

            Button(action: playback.togglePlayPause) {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(playback.currentTrack == nil || playback.isLoading)
            .help(playback.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

            Button(action: playback.next) {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .help("Next track")
            .accessibilityLabel("Next track")
        }
    }

    private func format(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

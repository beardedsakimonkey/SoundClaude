import SwiftUI

struct PlayerFooterView: View {
    let model: AppModel
    let artworkLoader: ArtworkLoader
    let onSelectArtist: (SoundCloudUser) -> Void
    let onSelectTrack: (SoundCloudTrack) -> Void
    @Binding var isShowingQueue: Bool

    @State private var isHoveringTitle = false
    @State private var likeErrorMessage: String?

    @Bindable private var playback: PlaybackController
    @ObservedObject private var likes: LikesController

    init(
        model: AppModel,
        isShowingQueue: Binding<Bool>,
        onSelectTrack: @escaping (SoundCloudTrack) -> Void,
        onSelectArtist: @escaping (SoundCloudUser) -> Void
    ) {
        self.model = model
        _isShowingQueue = isShowingQueue
        self.artworkLoader = model.artworkLoader
        self.onSelectTrack = onSelectTrack
        self.onSelectArtist = onSelectArtist
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
                    endPoint: .bottom
                )
            }
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.primary.opacity(0.2))
                .frame(height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
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
                    if track.access == .preview {
                        TrackPreviewBadge()
                    }
                    Button {
                        onSelectTrack(track)
                    } label: {
                        Text(track.title)
                            .lineLimit(track.access == .preview ? 1 : 2)
                            .multilineTextAlignment(.leading)
                            .underline(isHoveringTitle)
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .onHover { isHoveringTitle = $0 }
                    .help("View track")
                } else {
                    Text("Select a track")
                }
                Group {
                    if let track = playback.currentTrack {
                        ArtistLink(artist: track.artist, onSelect: onSelectArtist)
                    } else {
                        Text("Choose a track to start listening")
                    }
                }
                .font(.headline.weight(.medium))
                .foregroundStyle(.secondary)
            }
            .font(.title3.weight(.semibold))
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
                .foregroundStyle(isLiked ? Color.orange : Color.primary)
                .opacity(0.9)
                .frame(width: 32, height: 32)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(SpringPressEffect())
        .disabled(track == nil || isUpdating || likes.isLoading)
        .help(isLiked ? "Unlike track" : "Like track")
        .accessibilityLabel(isLiked ? "Unlike track" : "Like track")
        .accessibilityValue(isLiked ? "Liked" : "Not liked")
    }

    @ViewBuilder
    private var artwork: some View {
        if let track = playback.currentTrack {
            Button {
                onSelectTrack(track)
            } label: {
                artworkThumbnail
            }
            .buttonStyle(.plain)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .help("View track")
            .accessibilityLabel("View track: \(track.title)")
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

                HStack(spacing: 4) {
                    Button(action: playback.toggleMute) {
                        Group {
                            if playback.volume == 0 || playback.isMuted {
                                Image(systemName: "speaker.slash.fill")
                            } else {
                                Image(systemName: "speaker.wave.3.fill", variableValue: Double(playback.volume))
                            }
                        }
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 24, alignment: .leading)
                    }

                    Slider(value: $playback.volume, in: 0...1)
                        .frame(width: 110)
                        .accessibilityLabel("Volume")
                        .accessibilityValue("\(Int(playback.volume * 100)) percent")
                }

                Button {
                    isShowingQueue.toggle()
                } label: {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 18))
                        .foregroundStyle(isShowingQueue ? Color.orange : Color.primary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .modifier(SpringPressEffect())
                .keyboardShortcut("q", modifiers: [])
                .help(isShowingQueue ? "Hide track queue (Q)" : "Show track queue (Q)")
                .accessibilityLabel(isShowingQueue ? "Hide track queue" : "Show track queue")
                .accessibilityValue(isShowingQueue ? "Open" : "Closed")
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

            Button(action: model.toggleShuffle) {
                Image(systemName: "shuffle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(playback.isShuffleEnabled ? Color.green : Color.primary)
                    .frame(width: 20, height: 20)
                    .overlay(alignment: .bottom) {
                        if playback.isShuffleEnabled {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 4, height: 4)
                                .offset(y: 5)
                        }
                    }
            }
            .buttonStyle(.plain)
            .modifier(SpringPressEffect())
            .padding(.horizontal, 6)
            .help(playback.isShuffleEnabled ? "Turn shuffle off" : "Turn shuffle on")
            .accessibilityLabel("Shuffle")
            .accessibilityValue(playback.isShuffleEnabled ? "On" : "Off")

            Button(action: playback.cycleRepeatMode) {
                Image(systemName: playback.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(playback.repeatMode != .off ? Color.cyan : Color.primary)
                    .frame(width: 20, height: 20)
                    .overlay(alignment: .bottom) {
                        if playback.repeatMode != .off {
                            Circle()
                                .fill(Color.cyan)
                                .frame(width: 4, height: 4)
                                .offset(y: 5)
                        }
                    }
            }
            .buttonStyle(.plain)
            .modifier(SpringPressEffect())
            .padding(.horizontal, 6)
            .help("\(playback.repeatMode.nextAction) (R)")
            .accessibilityLabel("Repeat")
            .accessibilityValue(playback.repeatMode.label)
        }
    }

    private func format(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

#Preview {
    PlayerFooterView(
        model: AppModel(),
        isShowingQueue: .constant(false),
        onSelectTrack: { _ in },
        onSelectArtist: { _ in }
    )
    .frame(width: 900)
}

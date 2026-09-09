import SwiftUI

struct PlayerFooterView: View {
    let model: AppModel
    let artworkLoader: ArtworkLoader
    let onSelectArtist: (SoundCloudUser) -> Void
    let onSelectTrack: (SoundCloudTrack) -> Void
    @Binding var isShowingQueue: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previousArtworkURL: URL?
    @State private var hasPreviousTrack = false
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
        .modifier(PlayerFooterGlass())
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
                    .keyboardShortcut("f", modifiers: [])
                    .onContentHover { isHoveringTitle = $0 }
                    .help("Focus current track (F)")
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
                .font(.system(size: 14, weight: .semibold))
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
            .buttonStyle(PlayerFooterButtonStyle(
                pressAnimation: .interpolatingSpring(mass: 2, stiffness: 180, damping: 36),
                response: 0.3,
                dampingFraction: 0.45
            ))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .help("View track")
            .accessibilityLabel("View track: \(track.title)")
        } else {
            artworkThumbnail
        }
    }

    private var artworkThumbnail: some View {
        Color.clear
            .frame(width: 80, height: 80)
            .keyframeAnimator(initialValue: 180.0, trigger: playback.currentTrack?.urn) { _, angle in
                let sign = playback.trackChangeDirection == .forward ? -1.0 : 1.0
                let shouldFlip = !reduceMotion && hasPreviousTrack && playback.currentTrack != nil
                let rotation = shouldFlip ? angle : 180

                ZStack {
                    thumbnail(for: previousArtworkURL)
                        .opacity(rotation < 90 ? 1 : 0)
                        .rotation3DEffect(
                            .degrees(sign * rotation),
                            axis: (x: 0, y: 1, z: 0),
                            perspective: 0.5
                        )
                    thumbnail(for: playback.currentTrack?.artworkURL)
                        .opacity(rotation >= 90 ? 1 : 0)
                        .rotation3DEffect(
                            .degrees(sign * (rotation - 180)),
                            axis: (x: 0, y: 1, z: 0),
                            perspective: 0.5
                        )
                }
            } keyframes: { _ in
                MoveKeyframe(0)
                SpringKeyframe(
                    180,
                    spring: .init(duration: 0.42, bounce: 0.22),
                    startVelocity: 450
                )
            }
            .onChange(of: playback.currentTrack) { oldTrack, _ in
                previousArtworkURL = oldTrack?.artworkURL
                hasPreviousTrack = oldTrack != nil
            }
    }

    private func thumbnail(for url: URL?) -> some View {
        TrackArtworkView(
            artworkURL: url,
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
                            layout: .compact,
                            invertsBarsOnTrackChange: true
                        )
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

                Button {
                    isShowingQueue.toggle()
                } label: {
                    Image(systemName: "list.bullet")
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
        transportButtons
            .buttonStyle(PlayerFooterButtonStyle())
            .buttonBorderShape(.circle)
            .controlSize(.large)
    }

    private var transportButtons: some View {
        HStack(spacing: 12) {
            Button(action: playback.previous) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .help("Previous track")
            .accessibilityLabel("Previous track")

            Button(action: playback.togglePlayPause) {
                ZStack {
                    Image(systemName: playback.isPlaybackActive ? "pause.fill" : "play.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .id(playback.isPlaybackActive)
                        .transition(reduceMotion ? .identity : .scale(scale: 0.01).combined(with: .opacity))
                }
                .frame(width: 44, height: 44)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.6),
                    value: playback.isPlaybackActive
                )
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(playback.currentTrack == nil)
            .help(playback.isPlaybackActive ? "Pause" : "Play")
            .accessibilityLabel(playback.isPlaybackActive ? "Pause" : "Play")

            Button(action: playback.next) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .help("Next track")
            .accessibilityLabel("Next track")

            Button(action: model.toggleShuffle) {
                Image(systemName: "shuffle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(playback.isShuffleEnabled ? Color.green : Color.primary)
                    .opacity(0.9)
                    .frame(width: 20, height: 20)
            }
            .padding(.horizontal, 6)
            .help(playback.isShuffleEnabled ? "Turn shuffle off" : "Turn shuffle on")
            .accessibilityLabel("Shuffle")
            .accessibilityValue(playback.isShuffleEnabled ? "On" : "Off")

            Button(action: playback.cycleRepeatMode) {
                Image(systemName: playback.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(playback.repeatMode != .off ? Color.cyan : Color.primary)
                    .opacity(0.9)
                    .frame(width: 20, height: 20)
            }
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

private struct PlayerFooterButtonStyle: ButtonStyle {
    var pressAnimation: Animation? = nil
    var response: Double = 0.2
    var dampingFraction: Double = 0.7

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed && isEnabled
        let spring = Animation.spring(response: response, dampingFraction: dampingFraction)

        return configuration.label
            .scaleEffect(isPressed && !reduceMotion ? 0.9 : 1)
            .animation(
                reduceMotion ? nil : (isPressed ? pressAnimation ?? spring : spring),
                value: isPressed
            )
    }
}

private struct PlayerFooterGlass: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
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

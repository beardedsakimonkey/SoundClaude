import SwiftUI

struct PlayerFooterView: View {
    private let artworkThumbnailSize: CGFloat = 72
    private let cornerRadius: CGFloat = 18
    private let contentInset: CGFloat = 6

    private var artworkShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius - contentInset, style: .continuous)
    }

    @ObservedObject var model: AppModel
    let artworkLoader: ArtworkLoader
    let onSelectArtist: (SoundCloudUser) -> Void
    let onSelectTrack: (SoundCloudTrack) -> Void
    @Binding var isShowingQueue: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previousArtworkURL: URL?
    @State private var hasPreviousTrack = false
    @State private var isHoveringTitle = false
    @State private var isHoveringArtwork = false

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
        HStack(spacing: 6) {
            trackIdentity
                .frame(width: 340)
            playbackControls
                .frame(maxWidth: .infinity)
                .layoutPriority(1)
        }
        .padding(contentInset)
        .padding(.horizontal, 2)
        .modifier(PlayerFooterGlass(cornerRadius: cornerRadius))
        .alert("Could not update like", isPresented: Binding(
            get: { model.likeErrorMessage != nil },
            set: { if !$0 { model.likeErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.likeErrorMessage = nil }
        } message: {
            Text(model.likeErrorMessage ?? "Please try again.")
        }
    }

    private var trackIdentity: some View {
        HStack(spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 6) {
                if let track = playback.currentTrack {
                    if track.access == .preview {
                        TrackPreviewBadge(font: .caption2)
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
            .font(.system(size: 14, weight: .semibold))
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
            model.toggleCurrentTrackLike()
        } label: {
            Image(systemName: isLiked ? "heart.fill" : "heart")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isLiked ? Color.orange : Color.primary)
                .opacity(0.9)
                .frame(width: 32, height: 32)
                .modifier(PlayerFooterButtonBackground(color: .orange, isActive: isLiked))
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(SpringPressEffect())
        .disabled(track == nil || isUpdating)
        .help(isLiked ? "Unlike track (L)" : "Like track (L)")
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
            .contentShape(artworkShape)
            .help("View track")
            .accessibilityLabel("View track: \(track.title)")
        } else {
            artworkThumbnail
        }
    }

    private var artworkThumbnail: some View {
        Color.clear
            .frame(width: artworkThumbnailSize, height: artworkThumbnailSize)
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
                    thumbnail(for: playback.currentTrack?.displayArtworkURL)
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
            .scaleEffect(isHoveringArtwork && !reduceMotion ? 1.05 : 1)
            .animation(
                reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.75),
                value: isHoveringArtwork
            )
            // Keep the hover area fixed while the thumbnail scales.
            .frame(width: artworkThumbnailSize, height: artworkThumbnailSize)
            .contentShape(artworkShape)
            .onContentHover { isHoveringArtwork = $0 }
            .onChange(of: playback.currentTrack) { oldTrack, _ in
                previousArtworkURL = oldTrack?.displayArtworkURL
                hasPreviousTrack = oldTrack != nil
            }
    }

    private func thumbnail(for url: URL?) -> some View {
        TrackArtworkView(
            artworkURL: url,
            loader: artworkLoader,
            size: artworkThumbnailSize,
            rendition: .square500,
            shape: artworkShape,
            showsBorder: false
        )
        .modifier(PlayerArtworkGlass(
            cornerRadius: cornerRadius - contentInset,
            isHovering: isHoveringArtwork && !reduceMotion
        ))
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
                            invertsBarsOnTrackChange: true,
                            collapsesBarsWhenPaused: true
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
                    .foregroundStyle(.tertiary)
                    .offset(y: -4)
                }
                .frame(maxWidth: .infinity)
                // Compensate for the timestamps below the waveform.
                .offset(y: 8)

                Button {
                    isShowingQueue.toggle()
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 14))
                        .foregroundStyle(isShowingQueue ? Color.orange : Color.primary)
                        .frame(width: 32, height: 32)
                        .modifier(PlayerFooterButtonBackground(color: .orange, isActive: isShowingQueue))
                        .contentShape(Circle())
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

                    Slider(value: Binding(
                        get: { displayedVolume },
                        set: {
                            playback.volume = $0
                            playback.isMuted = false
                        }
                    ), in: 0...1)
                        .frame(width: 110)
                        .accessibilityLabel("Volume")
                        .accessibilityValue("\(Int(displayedVolume * 100)) percent")
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

    private var displayedVolume: Float {
        playback.isMuted ? 0 : playback.volume
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
                    .frame(width: 32, height: 32)
                    .modifier(PlayerFooterButtonBackground())
            }
            .help("Previous track")
            .accessibilityLabel("Previous track")
            .keyboardShortcut("<", modifiers: [])

            Button(action: playback.togglePlayPause) {
                ZStack {
                    Image(systemName: playback.isPlaybackActive ? "pause.fill" : "play.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .id(playback.isPlaybackActive)
                        .transition(reduceMotion ? .identity : .scale(scale: 0.01).combined(with: .opacity))
                }
                .frame(width: 44, height: 44)
                .modifier(PlayerFooterButtonBackground())
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
                    .frame(width: 32, height: 32)
                    .modifier(PlayerFooterButtonBackground())
            }
            .help("Next track")
            .accessibilityLabel("Next track")
            .keyboardShortcut(">", modifiers: [])

            Button(action: model.toggleShuffle) {
                Image(systemName: "shuffle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(playback.isShuffleEnabled ? Color.green : Color.primary)
                    .opacity(0.9)
                    .frame(width: 32, height: 32)
                    .modifier(PlayerFooterButtonBackground(color: .green, isActive: playback.isShuffleEnabled))
                    .contentShape(Circle())
            }
            .help(playback.isShuffleEnabled ? "Turn shuffle off" : "Turn shuffle on")
            .accessibilityLabel("Shuffle")
            .accessibilityValue(playback.isShuffleEnabled ? "On" : "Off")

            Button(action: playback.cycleRepeatMode) {
                Image(systemName: playback.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(playback.repeatMode != .off ? Color.cyan : Color.primary)
                    .opacity(0.9)
                    .frame(width: 32, height: 32)
                    .modifier(PlayerFooterButtonBackground(color: .cyan, isActive: playback.repeatMode != .off))
                    .contentShape(Circle())
            }
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

private struct PlayerFooterButtonBackground: ViewModifier {
    var color: Color = .primary
    var isActive: Bool = false

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background {
                Circle()
                    .fill(isActive ? color.opacity(0.12) : Color(white: 0.5).opacity(isHovering && isEnabled ? 0.12 : 0))
            }
            .contentShape(Circle())
            .onContentHover { isHovering = $0 }
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
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

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

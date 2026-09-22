import SwiftUI

struct PlayerFooterView: View {
    private let artworkThumbnailSize: CGFloat = 72
    private let waveformHeight: CGFloat = 50
    private let cornerRadius: CGFloat = 18
    private let contentInset: CGFloat = 6

    private var artworkShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius - contentInset, style: .continuous)
    }

    @ObservedObject var model: AppModel
    let artworkLoader: ArtworkLoader
    let onSelectArtist: (SoundCloudUser) -> Void
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectPlaylist: (SoundCloudPlaylist) -> Void
    let onSelectStation: (String, String) -> Void
    @Binding var isShowingQueue: Bool
    @Binding var isShowingVisualizer: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previousArtworkURL: URL?
    @State private var hasPreviousTrack = false
    @State private var isHoveringSource = false
    @State private var isHoveringTitle = false
    @State private var isHoveringArtwork = false
    @State private var isHoveringWaveform = false
    @State private var footerWidth: CGFloat = 0

    @Bindable private var playback: PlaybackController
    @ObservedObject private var likes: LikesController
    @ObservedObject private var playlists: PlaylistsController

    init(
        model: AppModel,
        isShowingQueue: Binding<Bool>,
        isShowingVisualizer: Binding<Bool>,
        onSelectTrack: @escaping (SoundCloudTrack) -> Void,
        onSelectArtist: @escaping (SoundCloudUser) -> Void,
        onSelectPlaylist: @escaping (SoundCloudPlaylist) -> Void,
        onSelectStation: @escaping (String, String) -> Void
    ) {
        self.model = model
        _isShowingQueue = isShowingQueue
        _isShowingVisualizer = isShowingVisualizer
        self.artworkLoader = model.artworkLoader
        self.onSelectTrack = onSelectTrack
        self.onSelectPlaylist = onSelectPlaylist
        self.onSelectStation = onSelectStation
        self.onSelectArtist = onSelectArtist
        self.playback = model.playback
        _likes = ObservedObject(wrappedValue: model.likes)
        _playlists = ObservedObject(wrappedValue: model.playlists)
    }

    var body: some View {
        HStack(spacing: 6) {
            trackIdentity
                .frame(width: min(340, max(140, footerWidth * 0.35)), alignment: .leading)
            playbackControls
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.width
        } action: { width in
            footerWidth = width
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
                    if let stationURN {
                        sourceButton(title: stationTitle, icon: "dot.radiowaves.left.and.right", kind: "station") {
                            onSelectStation(stationURN, stationTitle)
                        }
                        .id(stationURN)
                        .transition(reduceMotion ? .identity : .opacity)
                    } else if let playlist = currentPlaylist {
                        sourceButton(title: playlist.title, icon: "music.note.list", kind: "playlist") {
                            onSelectPlaylist(playlist)
                        }
                        .id(playlist.urn)
                        .transition(reduceMotion ? .identity : .opacity)
                    }
                    if showsPreviewBadge {
                        TrackPreviewBadge(font: .caption2)
                    }
                    Button {
                        onSelectTrack(track)
                    } label: {
                        Text(track.title)
                            .lineLimit(stationURN != nil || currentPlaylist != nil || showsPreviewBadge ? 1 : 2)
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
                            .keyboardShortcut("a", modifiers: [])
                            .help("Focus current artist (A)")
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
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: stationURN)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: currentPlaylist?.urn)
            likeButton
        }
    }

    private func sourceButton(title: String, icon: String, kind: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(title)
                    .underline(isHoveringSource)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .onContentHover { isHoveringSource = $0 }
        .help("View \(kind): \(title)")
        .accessibilityLabel("View \(kind): \(title)")
    }

    private var showsPreviewBadge: Bool {
        switch model.queue.source {
        case .station, .playlist:
            return false
        default:
            return playback.currentTrack?.access == .preview
        }
    }

    private var currentPlaylist: SoundCloudPlaylist? {
        guard case let .playlist(urn) = model.queue.source else { return nil }
        return playlists.cache.contents[urn]?.playlist
            ?? playlists.playlists.first { $0.urn == urn }
    }

    private var stationURN: String? {
        guard case let .station(urn) = model.queue.source else { return nil }
        return urn
    }

    private var stationTitle: String { model.queue.stationTitle ?? "Station" }

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
                .foregroundStyle(isLiked ? Color.accentColor : Color.primary)
                .frame(width: 32, height: 32)
                .modifier(PlayerFooterButtonBackground(color: .accentColor, isActive: isLiked))
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(SpringPressEffect())
        .disabled(track == nil)
        .opacity(isUpdating ? 0.5 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isLiked)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isUpdating)
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
            .draggable(TrackPlaylistDrag(track: track))
            .help("View track or drag to a playlist")
            .accessibilityLabel("View track: \(track.title)")
        } else {
            artworkThumbnail
        }
    }

    private var artworkThumbnail: some View {
        ZStack {
            artworkFace(for: previousArtworkURL, isPrevious: true)
            artworkFace(for: playback.currentTrack?.displayArtworkURL, isPrevious: false)
        }
        .animation(
            reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.75),
            value: isHoveringArtwork
        )
        .frame(width: artworkThumbnailSize, height: artworkThumbnailSize)
        .contentShape(artworkShape)
        .onContentHover { isHoveringArtwork = $0 }
        .onChange(of: playback.currentTrack) { oldTrack, _ in
            previousArtworkURL = oldTrack?.displayArtworkURL
            hasPreviousTrack = oldTrack != nil
        }
    }

    private func artworkFace(for url: URL?, isPrevious: Bool) -> some View {
        let sign = playback.trackChangeDirection == .forward ? -1.0 : 1.0
        let shouldFlip = !reduceMotion && hasPreviousTrack && playback.currentTrack != nil

        // Keep image loading outside the animator's content closure so an image
        // arriving during the flip does not replace the animated view.
        return thumbnail(for: url)
            .keyframeAnimator(initialValue: 180.0, trigger: playback.currentTrack?.urn) { content, angle in
                let rotation = shouldFlip ? angle : 180

                content
                    .opacity((rotation < 90) == isPrevious ? 1 : 0)
                    .rotation3DEffect(
                        .degrees(sign * (isPrevious ? rotation : rotation - 180)),
                        axis: (x: 0, y: 1, z: 0),
                        perspective: 0.5
                    )
            } keyframes: { _ in
                MoveKeyframe(0)
                SpringKeyframe(
                    180,
                    spring: .init(duration: 0.42, bounce: 0.22),
                    startVelocity: 450
                )
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
        .scaleEffect(isHoveringArtwork && !reduceMotion ? 1.15 : 1)
        .clipShape(artworkShape)
        .modifier(PlayerArtworkGlass(
            cornerRadius: cornerRadius - contentInset,
            isHovering: isHoveringArtwork && !reduceMotion
        ))
    }

    private var playbackControls: some View {
        let raisesTimestamps = playback.currentTrack != nil
            && !playback.isPlaybackActive && !isHoveringWaveform

        return VStack(spacing: 10) {
            HStack(spacing: 16) {
                transportControls
                VStack(spacing: 4) {
                    if let track = playback.currentTrack {
                        TrackWaveformView(
                            track: track,
                            model: model,
                            layout: .compact,
                            height: waveformHeight,
                            invertsBarsOnTrackChange: true,
                            collapsesBarsWhenPaused: true
                        )
                        .onContentHover { isHoveringWaveform = $0 }
                    } else {
                        Color.clear
                            .frame(height: waveformHeight)
                            .accessibilityHidden(true)
                    }

                    HStack {
                        Text(format(seconds: playback.currentTime))
                        Spacer()
                        Text(format(seconds: playback.duration))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    // Follow the lower edge as centered bars collapse to 4 points.
                    .offset(y: -4 - (raisesTimestamps
                        ? (TrackWaveformView.Layout.compact.availableBarHeight(for: waveformHeight) - 4) / 2 - 1
                        : 0))
                    .animation(
                        reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.3),
                        value: raisesTimestamps
                    )
                }
                .frame(maxWidth: .infinity)
                // Compensate for the timestamps below the waveform.
                .offset(y: 8)

                Button {
                    isShowingQueue.toggle()
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 14))
                        .foregroundStyle(isShowingQueue ? Color.accentColor : Color.primary)
                        .frame(width: 32, height: 32)
                        .modifier(PlayerFooterButtonBackground(color: .accentColor, isActive: isShowingQueue))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .modifier(SpringPressEffect())
                .keyboardShortcut("q", modifiers: [])
                .help(isShowingQueue ? "Hide track queue (Q)" : "Show track queue (Q)")
                .accessibilityLabel(isShowingQueue ? "Hide track queue" : "Show track queue")
                .accessibilityValue(isShowingQueue ? "Open" : "Closed")

                Button {
                    isShowingVisualizer.toggle()
                } label: {
                    Image(systemName: "waveform.path")
                        .font(.system(size: 14))
                        .foregroundStyle(isShowingVisualizer ? Color.accentColor : Color.primary)
                        .frame(width: 32, height: 32)
                        .modifier(PlayerFooterButtonBackground(color: .accentColor, isActive: isShowingVisualizer))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .modifier(SpringPressEffect())
                .keyboardShortcut("v", modifiers: [])
                .help(isShowingVisualizer ? "Hide visualizer (V)" : "Show visualizer (V)")
                .accessibilityLabel(isShowingVisualizer ? "Hide visualizer" : "Show visualizer")
                .accessibilityValue(isShowingVisualizer ? "Open" : "Closed")

                PlayerVolumeControl(playback: playback, usesCompactVolume: footerWidth < 1_000)
                    .padding(.trailing, 8)
            }
            .buttonStyle(.borderless)

            if let playbackError = playback.errorMessage {
                Text(playbackError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

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

            Button(action: playback.togglePlayPause) {
                AnimatedPlayPauseIcon(isPlaybackActive: playback.isPlaybackActive, size: 28)
                    .frame(width: 44, height: 44)
                    .modifier(PlayerFooterButtonBackground())
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

            Button(action: model.toggleShuffle) {
                Image(systemName: "shuffle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(playback.isShuffleEnabled ? Color.green : Color.primary)
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
            .opacity(0.9)
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
        isShowingVisualizer: .constant(false),
        onSelectTrack: { _ in },
        onSelectArtist: { _ in },
        onSelectPlaylist: { _ in },
        onSelectStation: { _, _ in }
    )
    .frame(width: 900)
}

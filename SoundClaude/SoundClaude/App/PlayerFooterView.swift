import SwiftUI

struct PlayerFooterView: View {
    // Matches the height of the waveform and its timestamps, so neither makes the footer taller.
    private let artworkThumbnailSize: CGFloat = 67
    private let cornerRadius: CGFloat = 18
    private let contentInset: CGFloat = 6

    private var artworkShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius - contentInset, style: .continuous)
    }

    let model: AppModel
    let artworkLoader: ArtworkLoader
    let onSelectArtist: (SoundCloudUser) -> Void
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectPlaylist: (SoundCloudPlaylist) -> Void
    let onSelectStation: (String, String) -> Void
    @Binding var isShowingQueue: Bool
    @Binding var isShowingVisualizer: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var footerWidth: CGFloat = 0

    @Bindable private var playback: PlaybackController

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
    }

    var body: some View {
        HStack(spacing: 6) {
            trackIdentity
                .frame(width: min(340, max(140, footerWidth * 0.3)), alignment: .leading)
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
        .modifier(PlayerFooterGlass(cornerRadius: cornerRadius))
        .alert("Could not update like", isPresented: Binding(
            get: { model.likeErrorMessage != nil },
            set: { if !$0 { model.likeErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.likeErrorMessage = nil }
        } message: {
            Text(model.likeErrorMessage ?? "Please try again.")
        }
        #if DEBUG
        .debugViewUpdates("PlayerFooterView")
        #endif
    }

    private var trackIdentity: some View {
        HStack(spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 6) {
                if let track = playback.currentTrack {
                    if let stationURN {
                        PlayerFooterSourceButton(
                            title: stationTitle, icon: "dot.radiowaves.left.and.right", kind: "station",
                            prefetch: .station(stationURN)
                        ) {
                            onSelectStation(stationURN, stationTitle)
                        }
                        .id(stationURN)
                    } else if let playlist = currentPlaylist {
                        PlayerFooterSourceButton(title: playlist.title, icon: "music.note.list", kind: "playlist") {
                            Task {
                                if let details = await model.playlistDetails(urn: playlist.urn, title: playlist.title) {
                                    onSelectPlaylist(details)
                                }
                            }
                        }
                        .id(playlist.urn)
                    }
                    if showsPreviewBadge {
                        TrackPreviewBadge(font: .caption2)
                    }
                    PlayerFooterTrackTitleButton(
                        title: track.title,
                        track: track,
                        lineLimit: stationURN != nil || currentPlaylist != nil || showsPreviewBadge ? 1 : 2
                    ) {
                        onSelectTrack(track)
                    }
                    .contextMenu {
                        TrackStationMenuItem(track: track)
                    }
                } else {
                    Text("Select a track")
                }
                Group {
                    if let track = playback.currentTrack {
                        ArtistLink(artist: track.artist, onSelect: onSelectArtist)
                            .keyboardShortcut("a", modifiers: [])
                            .contentHelp("Focus current artist (A)")
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

    private var showsPreviewBadge: Bool {
        switch model.queue.source {
        case .station, .playlist:
            return false
        default:
            return playback.currentTrack?.access == .preview
        }
    }

    private var currentPlaylist: (urn: String, title: String)? { model.queuePlaylist }

    private var stationURN: String? {
        guard case let .station(urn) = model.queue.source else { return nil }
        return urn
    }

    private var stationTitle: String { model.queue.sourceTitle ?? "Station" }

    private var likeButton: some View {
        PlayerFooterLikeButton(model: model)
    }

    @ViewBuilder
    private var artwork: some View {
        if let track = playback.currentTrack {
            Button {
                onSelectTrack(track)
            } label: {
                artworkThumbnail
            }
            .buttonStyle(PlayerFooterArtworkButtonStyle(shape: artworkShape))
            .contentShape(artworkShape)
            .prefetch(.track(track))
            .trackDraggable(track)
            .contextMenu {
                TrackMenuItems(
                    track: track,
                    likes: model.likes,
                    likeErrorMessage: Binding(
                        get: { model.likeErrorMessage },
                        set: { model.likeErrorMessage = $0 }
                    )
                )
            }
            .contentHelp("View track or drag to a playlist")
            .accessibilityLabel("View track: \(track.title)")
        } else {
            artworkThumbnail
        }
    }

    private var artworkThumbnail: some View {
        PlayerFooterArtworkThumbnail(
            artworkURL: playback.currentTrack?.displayArtworkURL,
            artworkLoader: artworkLoader,
            artworkThumbnailSize: artworkThumbnailSize,
            cornerRadius: cornerRadius - contentInset
        )
    }

    private var playbackControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                transportControls
                PlayerFooterWaveform(model: model, playback: playback)

                PlayerSpeedControl(playback: playback)

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
                .buttonStyle(PlayerFooterButtonStyle())
                .keyboardShortcut("v", modifiers: [])
                .contentHelp(isShowingVisualizer ? "Hide visualizer (V)" : "Show visualizer (V)")
                .accessibilityLabel(isShowingVisualizer ? "Hide visualizer" : "Show visualizer")
                .accessibilityValue(isShowingVisualizer ? "Open" : "Closed")

                Button {
                    isShowingQueue.toggle()
                } label: {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        .font(.system(size: 14))
                        .foregroundStyle(isShowingQueue ? Color.accentColor : Color.primary)
                        .frame(width: 32, height: 32)
                        .modifier(PlayerFooterButtonBackground(color: .accentColor, isActive: isShowingQueue))
                        .contentShape(Circle())
                }
                .buttonStyle(PlayerFooterButtonStyle())
                .keyboardShortcut("q", modifiers: [])
                .contentHelp(isShowingQueue ? "Hide track queue (Q)" : "Show track queue (Q)")
                .accessibilityLabel(isShowingQueue ? "Hide track queue" : "Show track queue")
                .accessibilityValue(isShowingQueue ? "Open" : "Closed")

                PlayerVolumeControl(playback: playback, usesCompactVolume: footerWidth < 1_000)
            }
            .buttonStyle(.borderless)

        }
    }

    private var transportControls: some View {
        transportButtons
            .buttonStyle(PlayerFooterButtonStyle())
            .buttonBorderShape(.circle)
            .controlSize(.large)
    }

    private var transportButtons: some View {
        HStack(spacing: 6) {
            PlayerFooterSkipButton(isBackward: true, action: playback.previous)
            .keyboardShortcut("p", modifiers: [])
            .contentHelp("Previous track (P)")
            .accessibilityLabel("Previous track")
            .disabled(model.queue.tracks.isEmpty)

            PlayerFooterPlayPauseButton(playback: playback)
                .disabled(model.queue.tracks.isEmpty)

            PlayerFooterSkipButton(isBackward: false, action: playback.next)
            .keyboardShortcut("n", modifiers: [])
            .contentHelp("Next track (N)")
            .accessibilityLabel("Next track")
            .disabled(model.queue.tracks.isEmpty)

            Button(action: model.toggleShuffle) {
                Image(systemName: "shuffle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(playback.isShuffleEnabled ? Color.green : Color.primary)
                    .frame(width: 32, height: 32)
                    .modifier(PlayerFooterButtonBackground(color: .green, isActive: playback.isShuffleEnabled))
                    .contentShape(Circle())
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: playback.isShuffleEnabled)
            .contentHelp(playback.isShuffleEnabled ? "Turn shuffle off" : "Turn shuffle on")
            .accessibilityLabel("Shuffle")
            .accessibilityValue(playback.isShuffleEnabled ? "On" : "Off")

            Button(action: playback.cycleRepeatMode) {
                Image(systemName: playback.repeatMode == .one ? "repeat.1" : "repeat")
                    .contentTransition(playback.repeatMode == .one ? .symbolEffect(.replace) : .identity)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(playback.repeatMode != .off ? Color.cyan : Color.primary)
                    .frame(width: 32, height: 32)
                    .modifier(PlayerFooterButtonBackground(color: .cyan, isActive: playback.repeatMode != .off))
                    .contentShape(Circle())
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: playback.repeatMode)
            .contentHelp("\(playback.repeatMode.nextAction) (R)")
            .accessibilityLabel("Repeat")
            .accessibilityValue(playback.repeatMode.label)
        }
    }

}

// Each button owns its animation so a click does not update the whole footer.
private struct PlayerFooterSkipButton: View {
    let isBackward: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animationTrigger = 0

    var body: some View {
        Button {
            if !reduceMotion { animationTrigger &+= 1 }
            action()
        } label: {
            AnimatedSkipIcon(isBackward: isBackward, trigger: animationTrigger, reduceMotion: reduceMotion, isOnGlass: true)
                .frame(width: 21, height: 13)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .frame(width: 32, height: 32)
                .modifier(PlayerFooterButtonBackground())
                .contentShape(Circle())
        }
    }
}

// Read playback state in its own body so toggling does not update the footer.
private struct PlayerFooterPlayPauseButton: View {
    let playback: PlaybackController

    // Pausing flips isPlaybackActive asynchronously, so withAnimation can't scope this to a click.
    @State private var animatesIconChange = false

    var body: some View {
        Button {
            // The Space shortcut also runs this action, so check what triggered it.
            animatesIconChange = NSApp.currentEvent?.type == .leftMouseUp
            playback.togglePlayPause()
        } label: {
            AnimatedPlayPauseIcon(
                isPlaybackActive: playback.isPlaybackActive,
                size: 28,
                animatesChange: animatesIconChange
            )
            .frame(width: 44, height: 44)
            .modifier(PlayerFooterButtonBackground())
        }
        .onChange(of: playback.isPlaybackActive) { animatesIconChange = false }
        .keyboardShortcut(.space, modifiers: [])
        .disabled(playback.currentTrack == nil)
        .contentHelp(playback.isPlaybackActive ? "Pause" : "Play")
        .accessibilityLabel(playback.isPlaybackActive ? "Pause" : "Play")
    }
}

// Each title owns its hover state so underlining does not update the footer.
private struct PlayerFooterTrackTitleButton: View {
    let title: String
    let track: SoundCloudTrack
    let lineLimit: Int
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .lineLimit(lineLimit)
                .multilineTextAlignment(.leading)
                .underline(isHovering)
                .foregroundStyle(.primary)
                .opacity(0.9)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("f", modifiers: [])
        .prefetch(.track(track)) { isHovering = $0 }
        .trackDraggable(track, previewTitle: title)
        .contentHelp("Focus current track (F) or drag to a playlist")
    }
}

private struct PlayerFooterSourceButton: View {
    let title: String
    let icon: String
    let kind: String
    // The playlist source has only a URN until its details load, so it does not prefetch.
    var prefetch: PrefetchTarget? = nil
    let action: () -> Void

    @State private var isHoveringSource = false

    var body: some View {
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
        .prefetch(prefetch) { isHoveringSource = $0 }
        .contentHelp("View \(kind): \(title)")
        .accessibilityLabel("View \(kind): \(title)")
    }
}

// Keep artwork hover animation updates out of the footer body.
private struct PlayerFooterArtworkThumbnail: View {
    let artworkURL: URL?
    let artworkLoader: ArtworkLoader
    let artworkThumbnailSize: CGFloat
    let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHoveringArtwork = false

    private var artworkShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        TrackArtworkView(
            artworkURL: artworkURL,
            loader: artworkLoader,
            size: artworkThumbnailSize,
            rendition: .square300,
            shape: artworkShape,
            showsBorder: false
        )
        .scaleEffect(isHoveringArtwork && !reduceMotion ? 1.15 : 1)
        .clipShape(artworkShape)
        .modifier(PlayerArtworkGlass(
            cornerRadius: cornerRadius,
            shadowRadius: 2,
            shadowOffsetY: 1
        ))
        .id(artworkURL)
        .animation(
            reduceMotion ? nil : isHoveringArtwork
                ? .spring(response: 0.4, dampingFraction: 0.75)
                : .spring(duration: 0.34, bounce: 0),
            value: isHoveringArtwork
        )
        .frame(width: artworkThumbnailSize, height: artworkThumbnailSize)
        .contentShape(artworkShape)
        .onContentHover { isHoveringArtwork = $0 }
    }
}

// Keep waveform hover and layout updates local to the waveform and timestamps.
private struct PlayerFooterWaveform: View {
    let model: AppModel
    let playback: PlaybackController

    private let waveformHeight: CGFloat = 50
    @State private var waveformHorizontalInset: CGFloat = 0

    var body: some View {
        let canInteract = playback.currentTrack != nil && playback.errorMessage == nil

        VStack(spacing: 4) {
            TrackWaveformView(
                track: playback.currentTrack,
                model: model,
                layout: .compact,
                height: waveformHeight,
                invertsBarsOnTrackChange: true,
                collapsesBarsWhenPaused: true
            )
            .environment(\.contentHoverEnabled, canInteract)
            .disabled(!canInteract)
            .allowsHitTesting(canInteract)
            .accessibilityHidden(playback.currentTrack == nil)

            PlayerFooterTimestamps(playback: playback)
            .opacity(playback.currentTrack == nil ? 0 : 1)
            .accessibilityHidden(playback.currentTrack == nil)
            .padding(.horizontal, playback.currentTrack == nil ? 0 : waveformHorizontalInset)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .overlay(alignment: .top) {
                if let playbackError = playback.errorMessage {
                    Label(playbackError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        // The overlay is one timestamp line tall; let a second line hang below it.
                        .fixedSize(horizontal: false, vertical: true)
                        // Clear the timestamps on either side.
                        .padding(.horizontal, 44)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .contentHelp(playbackError)
                }
            }
            .offset(y: -4)
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { geometry in
            TrackWaveformView.Layout.compact.horizontalBarInset(for: geometry.size.width)
        } action: { inset in
            waveformHorizontalInset = inset
        }
        // Compensate for the timestamps below the waveform.
        .offset(y: 8)
    }
}

// Read the playback clock in its own body to keep time updates out of the footer.
private struct PlayerFooterTimestamps: View {
    let playback: PlaybackController

    var body: some View {
        HStack {
            Text(format(seconds: playback.currentTime))
            Spacer()
            Text(format(seconds: playback.duration))
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
            .background {
                Circle()
                    .fill(color.opacity(isActive && isHovering && isEnabled ? 0.12 * 0.7 : 0))
            }
            .contentShape(Circle())
            .onContentHover { isHovering = $0 }
            .animation(.easeInOut(duration: 0.15), value: isHovering && isEnabled)
    }
}

private struct PlayerFooterArtworkButtonStyle: ButtonStyle {
    let shape: RoundedRectangle

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                shape
                    .fill(.black.opacity(configuration.isPressed && isEnabled ? 0.25 : 0))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

struct PlayerFooterButtonStyle: ButtonStyle {

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.4)
            .pressBounce(configuration.isPressed)
            // Keep the click area at its original size while the label scales.
            .contentShape(Rectangle())
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

private struct PlayerFooterLikeButton: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var playback: PlaybackController { model.playback }
    private var likes: LikesController { model.likes }

    var body: some View {
        let track = playback.currentTrack
        let isLiked = playback.sessionToRestore?.isLiked ?? track.map { likes.isLiked($0) } ?? false

        return Button {
            model.toggleCurrentTrackLike()
        } label: {
            Image(systemName: isLiked ? "heart.fill" : "heart")
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isLiked ? Color.accentColor : Color.primary)
                .symbolEffect(.bounce, options: .nonRepeating, value: model.currentTrackLikeEvents)
                .frame(width: 32, height: 32)
                .modifier(PlayerFooterButtonBackground(color: .accentColor, isActive: isLiked))
                .padding(.leading, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlayerFooterButtonStyle())
        .disabled(track == nil)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isLiked)
        .contentHelp(isLiked ? "Unlike track (L)" : "Like track (L)")
        .accessibilityLabel(isLiked ? "Unlike track" : "Like track")
        .accessibilityValue(isLiked ? "Liked" : "Not liked")
    }

}

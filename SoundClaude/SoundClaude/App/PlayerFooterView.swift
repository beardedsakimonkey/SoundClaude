import SwiftUI

struct PlayerFooterView: View {
    private let artworkThumbnailSize: CGFloat = 72
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
    @ObservedObject private var likes: LikesController

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
                        PlayerFooterSourceButton(title: stationTitle, icon: "dot.radiowaves.left.and.right", kind: "station") {
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

    private var currentPlaylist: (urn: String, title: String)? {
        guard case let .playlist(urn) = model.queue.source else { return nil }
        // AppModel updates the queue when this playlist title changes. Reading
        // the cache here does not subscribe the footer to every playlist load.
        let playlists = model.playlists
        guard let title = playlists.cache.contents[urn]?.playlist.title
            ?? playlists.playlists.first(where: { $0.urn == urn })?.title
            ?? model.queue.playlistTitle else { return nil }
        return (urn, title)
    }

    private var stationURN: String? {
        guard case let .station(urn) = model.queue.source else { return nil }
        return urn
    }

    private var stationTitle: String { model.queue.stationTitle ?? "Station" }

    private var likeButton: some View {
        let track = playback.currentTrack
        let isLiked = playback.sessionToRestore?.isLiked ?? track.map { likes.isLiked($0) } ?? false
        let isUpdating = track.map {
            likes.updatingTrackURNs.contains($0.urn)
        } ?? false

        return Button {
            model.toggleCurrentTrackLike()
        } label: {
            Image(systemName: isLiked ? "heart.fill" : "heart")
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isLiked ? Color.accentColor : Color.primary)
                .frame(width: 32, height: 32)
                .modifier(PlayerFooterButtonBackground(color: .accentColor, isActive: isLiked))
                .padding(.leading, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(SpringPressEffect())
        .disabled(track == nil)
        .opacity(isUpdating ? 0.5 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isLiked)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isUpdating)
        .contentHelp(isLiked ? "Unlike track (L)" : "Like track (L)")
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
            .buttonStyle(PlayerFooterArtworkButtonStyle(shape: artworkShape))
            .contentShape(artworkShape)
            .trackDraggable(track)
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
                .buttonStyle(.plain)
                .modifier(SpringPressEffect())
                .keyboardShortcut("v", modifiers: [])
                .contentHelp(isShowingVisualizer ? "Hide visualizer (V)" : "Show visualizer (V)")
                .accessibilityLabel(isShowingVisualizer ? "Hide visualizer" : "Show visualizer")
                .accessibilityValue(isShowingVisualizer ? "Open" : "Closed")

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
            Button(action: playback.previous) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .modifier(PlayerFooterButtonBackground())
            }
            .contentHelp("Previous track")
            .accessibilityLabel("Previous track")

            PlayerFooterPlayPauseButton(playback: playback)

            Button(action: playback.next) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .modifier(PlayerFooterButtonBackground())
            }
            .contentHelp("Next track")
            .accessibilityLabel("Next track")

            Button(action: model.toggleShuffle) {
                Image(systemName: "shuffle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(playback.isShuffleEnabled ? Color.cyan : Color.primary)
                    .frame(width: 32, height: 32)
                    .modifier(PlayerFooterButtonBackground(color: .cyan, isActive: playback.isShuffleEnabled))
                    .contentShape(Circle())
            }
            .contentHelp(playback.isShuffleEnabled ? "Turn shuffle off" : "Turn shuffle on")
            .accessibilityLabel("Shuffle")
            .accessibilityValue(playback.isShuffleEnabled ? "On" : "Off")

            Button(action: playback.cycleRepeatMode) {
                Image(systemName: playback.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(playback.repeatMode != .off ? Color.purple : Color.primary)
                    .frame(width: 32, height: 32)
                    .modifier(PlayerFooterButtonBackground(color: .purple, isActive: playback.repeatMode != .off))
                    .contentShape(Circle())
            }
            .contentHelp("\(playback.repeatMode.nextAction) (R)")
            .accessibilityLabel("Repeat")
            .accessibilityValue(playback.repeatMode.label)
        }
    }

}

// Read playback state in its own body so toggling does not update the footer.
private struct PlayerFooterPlayPauseButton: View {
    let playback: PlaybackController

    var body: some View {
        Button(action: playback.togglePlayPause) {
            AnimatedPlayPauseIcon(isPlaybackActive: playback.isPlaybackActive, size: 28)
                .frame(width: 44, height: 44)
                .modifier(PlayerFooterButtonBackground())
        }
        .keyboardShortcut(.space, modifiers: [])
        .disabled(playback.currentTrack == nil)
        .contentHelp(playback.isPlaybackActive ? "Pause" : "Play")
        .accessibilityLabel(playback.isPlaybackActive ? "Pause" : "Play")
    }
}

// Each title owns its hover state so underlining does not update the footer.
private struct PlayerFooterTrackTitleButton: View {
    let title: String
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
        .onContentHover { isHovering = $0 }
        .contentHelp("Focus current track (F)")
    }
}

private struct PlayerFooterSourceButton: View {
    let title: String
    let icon: String
    let kind: String
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
        .onContentHover { isHoveringSource = $0 }
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
        thumbnail(for: artworkURL)
        .id(artworkURL)
        .animation(
            reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.75),
            value: isHoveringArtwork
        )
        .frame(width: artworkThumbnailSize, height: artworkThumbnailSize)
        .contentShape(artworkShape)
        .onContentHover { isHoveringArtwork = $0 }
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
            cornerRadius: cornerRadius
        ))
    }

}

// Keep waveform hover and layout updates local to the waveform and timestamps.
private struct PlayerFooterWaveform: View {
    let model: AppModel
    let playback: PlaybackController

    private let waveformHeight: CGFloat = 50
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHoveringWaveform = false
    @State private var waveformHorizontalInset: CGFloat = 0

    var body: some View {
        let canInteract = playback.errorMessage == nil
        let raisesTimestamps = playback.currentTrack != nil
            && !playback.isPlaybackActive && !isHoveringWaveform

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
                .environment(\.contentHoverEnabled, canInteract)
                .disabled(!canInteract)
                .allowsHitTesting(canInteract)
            } else {
                Text("Select a track to play")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .frame(height: waveformHeight)
            }

            PlayerFooterTimestamps(playback: playback)
            .opacity(playback.currentTrack == nil ? 0 : 1)
            .accessibilityHidden(playback.currentTrack == nil)
            .padding(.horizontal, playback.currentTrack == nil ? 0 : waveformHorizontalInset)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.tertiary)
            .overlay {
                if let playbackError = playback.errorMessage {
                    Label(playbackError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .contentHelp(playbackError)
                        .offset(y: -8)
                }
            }
            // Follow the lower edge as centered bars collapse.
            .offset(y: -4 - (raisesTimestamps
                ? (TrackWaveformView.Layout.compact.availableBarHeight(for: waveformHeight)
                    - TrackWaveformView.collapsedBarHeight) / 2 - 1
                : 0))
            .animation(
                reduceMotion ? nil : (raisesTimestamps
                    ? .spring(duration: 0.44, bounce: 0.22)
                    : .spring(duration: 0.44, bounce: 0.44)),
                value: raisesTimestamps
            )
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
                .foregroundStyle(.secondary)
                .offset(x: -6)
            Spacer()
            Text(format(seconds: playback.duration))
                .offset(x: 6)
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

private struct PlayerFooterButtonStyle: ButtonStyle {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed && isEnabled
        return configuration.label
            .scaleEffect(isPressed && !reduceMotion ? 0.9 : 1)
            .animation(
                reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.7),
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

private struct PlayerSpeedControl: View {
    @Bindable var playback: PlaybackController
    @Environment(\.colorScheme) private var colorScheme
    @State private var isShowingSpeed = false

    private var rateLabel: String {
        playback.playbackRate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    var body: some View {
        Button {
            isShowingSpeed.toggle()
        } label: {
            Text(rateLabel)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isShowingSpeed ? Color.orange : Color.primary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(PlayerSpeedHoverFeedback(color: .orange, isActive: isShowingSpeed))
        .contentHelp("Playback speed and pitch")
        .accessibilityLabel("Playback speed and pitch")
        .accessibilityValue(rateLabel)
        .popover(isPresented: $isShowingSpeed, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Speed")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                PlayerSpeedSlider(value: Binding(
                    get: { playback.playbackRate },
                    set: { playback.setCustomSpeed($0) }
                ))
            }
            .padding(20)
            .frame(width: 340)
            // Matches the queue panel's tint behind the glass.
            .background {
                (colorScheme == .dark ? Color.black : Color.white)
                    .opacity(colorScheme == .dark ? 0.4 : 0.6)
                    .ignoresSafeArea()
            }
        }
    }

}

private struct PlayerSpeedHoverFeedback: ViewModifier {
    var color: Color = .primary
    var isActive: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isActive ? color.opacity(0.12) : Color.primary.opacity(isHovering ? 0.08 : 0))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .onContentHover { isHovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
    }
}

private struct PlayerSpeedSlider: View {
    @Binding var value: Float

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var isDragging = false
    @State private var isHovering = false
    @State private var hoverLocation: CGPoint?
    @FocusState private var isFocused: Bool

    // Steps are semitones, so they sit evenly on the log track: 0.5× and 2× are an octave from 1×.
    private let semitoneRange = -12...12
    // 0.75× and 1.5× are a fourth below and a fifth above, within 0.002×.
    private let markSemitones = [-12, -5, 0, 7, 12]
    private var marks: [Float] { markSemitones.map(speed(semitones:)) }
    private var steps: [Float] {
        semitoneRange.filter { !markSemitones.contains($0) }.map(speed(semitones:))
    }
    private let inset: CGFloat = 8
    private let trackHeight: CGFloat = 32

    private func fraction(_ speed: Float) -> CGFloat {
        // Equal speed ratios occupy equal distances: 0.5×, 1×, 2×.
        CGFloat((log2(min(max(speed, 0.5), 2)) + 1) / 2)
    }

    private func speed(semitones: Int) -> Float {
        Float(pow(2.0, Double(semitones) / 12))
    }

    private func semitones(_ speed: Float) -> Int {
        Int((12 * log2(speed)).rounded())
    }

    private func speed(at location: CGPoint, length: CGFloat) -> Float {
        let position = min(max((location.x - inset) / length, 0), 1)
        // Below the track, snap to the labeled markers.
        if location.y >= trackHeight {
            return marks.min { abs(fraction($0) - position) < abs(fraction($1) - position) }!
        }
        return speed(semitones: Int((position * 24).rounded()) - 12)
    }

    var body: some View {
        GeometryReader { geometry in
            let length = max(geometry.size.width - inset * 2, 1)
            let previewSpeed = isHovering && !isDragging
                ? hoverLocation.map { speed(at: $0, length: length) } : nil
            let previewPosition = previewSpeed.map { inset + length * fraction($0) }
            let isPreviewingLabels = (hoverLocation?.y ?? 0) >= trackHeight
            VStack(spacing: 0) {
                track(width: geometry.size.width, length: length, previewSpeed: previewSpeed)
                ZStack(alignment: .topLeading) {
                    ForEach(marks, id: \.self) { mark in
                        // Highlight fixed labels in place; a traveling copy can overlap its neighbors.
                        markerLabel(mark, isHighlighted: isPreviewingLabels && previewSpeed == mark)
                            .opacity(!isPreviewingLabels && previewPosition.map { abs($0 - (inset + length * fraction(mark))) < 36 } == true ? 0 : 1)
                            .position(x: inset + length * fraction(mark), y: 22)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: previewSpeed)
                    }
                }
                .frame(width: geometry.size.width, height: 32)
                .overlay(alignment: .topLeading) {
                    if !isPreviewingLabels, let previewSpeed, let previewPosition {
                        markerLabel(previewSpeed, isHighlighted: true)
                            .position(x: previewPosition, y: 22)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: previewSpeed)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            }
            // The marker labels and end margins are interactive too; speed(at:) clamps to the endpoints.
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isDragging) { _, dragging, _ in dragging = true }
                    .onChanged { gesture in
                        isFocused = true
                        value = speed(at: gesture.location, length: length)
                    }
            )
            .onContentHover { isHovering = $0 }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hoverLocation = location
                case .ended: hoverLocation = nil
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .onMoveCommand { direction in
                switch direction {
                case .left, .down: value = speed(semitones: max(semitones(value) - 1, -12))
                case .right, .up: value = speed(semitones: min(semitones(value) + 1, 12))
                default: break
                }
            }
            .accessibilityRepresentation {
                Slider(value: Binding(
                    get: { Double(semitones(value)) },
                    set: { value = speed(semitones: Int($0.rounded())) }
                ), in: -12...12, step: 1)
                    .accessibilityLabel("Playback speed")
                    .accessibilityValue(value.formatted(.number.precision(.fractionLength(0...2))) + "×")
            }
        }
        .frame(height: trackHeight + 32)
    }

    private func track(width: CGFloat, length: CGFloat, previewSpeed: Float?) -> some View {
        // Overlays keep the hover indicator from changing the track's layout size.
        // The track fills the end margins; speeds map onto the inset span between them.
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return shape
            .fill(Color.primary.opacity(isDragging ? 0.24 : 0.16))
            .frame(width: width, height: trackHeight)
            .overlay(alignment: .topLeading) {
                ForEach(steps, id: \.self) { step in
                    Capsule()
                        .fill(Color.primary.opacity(isDragging ? 0.36 : 0.26))
                        .frame(width: 1, height: 5)
                        .position(x: inset + length * fraction(step), y: trackHeight / 2)
                }
            }
            .overlay(alignment: .topLeading) {
                ForEach(marks, id: \.self) { mark in
                    let isMajor = mark == 0.5 || mark == 1 || mark == 2
                    Capsule()
                        .fill(Color.primary.opacity(isDragging ? 0.36 : 0.26))
                        .frame(width: 2, height: isMajor ? 12 : 9)
                        .position(x: inset + length * fraction(mark), y: trackHeight / 2)
                }
            }
            .overlay(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2, height: trackHeight)
                    .position(x: inset + length * fraction(value), y: trackHeight / 2)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: value)
            }
            .overlay(alignment: .topLeading) {
                if let previewSpeed {
                    Rectangle()
                        .fill(Color.primary.opacity(0.4))
                        .frame(width: 1, height: trackHeight)
                        .position(x: inset + length * fraction(previewSpeed), y: trackHeight / 2)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: previewSpeed)
                }
            }
        .clipShape(shape)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isDragging)
    }

    private func markerLabel(_ speed: Float, isHighlighted: Bool = false) -> some View {
        let label = speed.formatted(.number.precision(.fractionLength(0...2))) + "×"
        return Text(label)
            .font(.system(size: 14, weight: speed == 1 ? .semibold : .regular))
            .monospacedDigit()
            .foregroundStyle(Color.primary)
            .opacity(isHighlighted ? 1 : 0.45)
            .frame(width: 44, height: 44)
            .allowsHitTesting(false)
    }
}

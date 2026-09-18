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
    var onAddToQueue: ((SoundCloudTrack) -> Void)? = nil
    var onRemoveFromQueue: ((SoundCloudTrack) -> Void)? = nil
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    let onPlayTrack: (SoundCloudTrack) async -> Void

    @Environment(\.addToPlaylist) private var addToPlaylist
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var isHoveringArtwork = false
    @State private var isHoveringTitle = false
    @State private var isHoveringArtist = false
    @State private var isHoveringMenu = false
    @State private var likeErrorMessage: String?
    @State private var isStartingPlayback = false
    @GestureState private var isPressed = false

    var body: some View {
        let isCurrentTrack = playback.currentTrack?.urn == track.urn
        let isPlaybackActive = isCurrentTrack
            ? playback.isPlaybackActive : isStartingPlayback
        let isLiked = likes.isLiked(track)

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
                let likeCount = likes.likeCount(for: track)
                if showsArtist || likeCount != nil || isLiked {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if showsArtist {
                            ArtistLink(artist: track.artist, onSelect: onSelectArtist)
                                .onContentHover { isHoveringArtist = $0 }
                        }
                        if likeCount != nil || isLiked {
                            if showsArtist {
                                Text("·")
                                    .accessibilityHidden(true)
                            }
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Image(systemName: isLiked ? "heart.fill" : "heart")
                                if let likeCount {
                                    Text(likeCount.formatted())
                                }
                            }
                            .font(.system(size: 9))
                            .fixedSize()
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(
                                [isLiked ? "Liked" : nil, likeCount.map { "\($0.formatted()) likes" }]
                                    .compactMap { $0 }
                                    .joined(separator: ", ")
                            )
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(isCurrentTrack ? Color.orange : Color.secondary)
                }
            }
            .lineLimit(1)
            Spacer()
            Text(duration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
                // Keep the duration's width so hover does not change text truncation.
                .opacity(isHovering ? 0 : 1)
                .overlay {
                    Menu {
                        if let onRemoveFromQueue {
                            Button("Remove from queue", systemImage: "text.badge.minus") {
                                onRemoveFromQueue(track)
                            }
                        } else if let onAddToQueue {
                            Button("Add to queue", systemImage: "text.line.last.and.arrowtriangle.forward") {
                                onAddToQueue(track)
                            }
                        }
                        Button("Add to playlist", systemImage: "music.note.list") {
                            addToPlaylist(track)
                        }
                        Button(isLiked ? "Unlike" : "Like", systemImage: isLiked ? "heart.fill" : "heart") {
                            Task {
                                do {
                                    try await likes.toggleLike(track)
                                } catch is CancellationError {
                                } catch {
                                    likeErrorMessage = error.localizedDescription
                                }
                            }
                        }
                        .disabled(likes.updatingTrackURNs.contains(track.urn))
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
        .onChange(of: playback.currentTrack?.urn) { _, _ in
            isStartingPlayback = false
        }
        .alert("Could not update like", isPresented: Binding(
            get: { likeErrorMessage != nil },
            set: { if !$0 { likeErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { likeErrorMessage = nil }
        } message: {
            Text(likeErrorMessage ?? "Please try again.")
        }
        .accessibilityAction(named: isPlaybackActive ? "Pause" : "Play") {
            playOrPauseTrack()
        }
    }

    private func playOrPauseTrack() {
        if playback.currentTrack?.urn == track.urn {
            playback.togglePlayPause()
        } else {
            guard !isStartingPlayback else { return }
            // Acknowledge the click before the async callback selects the track.
            isStartingPlayback = true
            Task {
                defer { isStartingPlayback = false }
                await onPlayTrack(track)
            }
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

private struct AddToPlaylistKey: EnvironmentKey {
    static let defaultValue: (SoundCloudTrack) -> Void = { _ in }
}

extension EnvironmentValues {
    var addToPlaylist: (SoundCloudTrack) -> Void {
        get { self[AddToPlaylistKey.self] }
        set { self[AddToPlaylistKey.self] = newValue }
    }
}

struct AddToPlaylistView: View {
    let track: SoundCloudTrack
    let user: SoundCloudUser
    @ObservedObject var playlists: PlaylistsController
    @Environment(\.dismiss) private var dismiss
    @State private var selectedURN: String?
    @State private var isAdding = false
    @State private var errorMessage: String?

    private var ownedPlaylists: [SoundCloudPlaylist] {
        playlists.playlists.filter {
            ($0.owner.urn == user.urn && user.urn != nil)
                || $0.owner.permalinkURL == user.permalinkURL
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add to playlist").font(.title2.bold())
            Text(track.title).foregroundStyle(.secondary).lineLimit(2)
            List(ownedPlaylists, selection: $selectedURN) { playlist in
                Label(playlist.title, systemImage: playlist.isPrivate ? "lock" : "music.note.list")
                    .tag(playlist.urn)
            }
            .overlay {
                if ownedPlaylists.isEmpty {
                    if playlists.isLoading {
                        ProgressView()
                    } else {
                        Text("No playlists. Create a playlist in the sidebar first.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                }
            }
            .disabled(isAdding)
            if let message = errorMessage ?? playlists.errorMessage {
                Text(message).foregroundStyle(.red).font(.callout)
                Button("Reload playlists") { Task { await playlists.load() } }
                    .disabled(isAdding || playlists.isLoading)
            }
            HStack {
                if isAdding { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isAdding)
                Button("Add") {
                    guard let playlist = ownedPlaylists.first(where: { $0.urn == selectedURN }) else { return }
                    isAdding = true
                    errorMessage = nil
                    Task { @MainActor in
                        defer { isAdding = false }
                        do {
                            try await playlists.addTrack(track, to: playlist)
                            dismiss()
                        } catch is CancellationError {
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isAdding || selectedURN == nil)
            }
        }
        .padding(24)
        .frame(width: 420, height: 380)
        .interactiveDismissDisabled(isAdding)
        .task { await playlists.load() }
    }
}

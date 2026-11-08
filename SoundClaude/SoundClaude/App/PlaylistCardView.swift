import SwiftUI

struct PlaylistCardView: View {
    let playlist: SoundCloudPlaylist
    let model: AppModel
    let playlists: PlaylistsController
    let onSelectPlaylist: (SoundCloudPlaylist) -> Void
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void

    @State private var isExpanded = false
    @State private var isHoveringTrackToggle = false
    @State private var selectedTrackURN: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cardState: PlaylistCardState { playlists.cardState(for: playlist.urn) }
    private var contents: PlaylistContents? { cardState.contents }
    private var displayedPlaylist: SoundCloudPlaylist { contents?.playlist ?? playlist }
    private var tracks: [SoundCloudTrack] { contents?.tracks ?? [] }
    private var isLoading: Bool { cardState.isLoading }
    private var errorMessage: String? { cardState.errorMessage }
    private var waveformTrack: SoundCloudTrack? {
        tracks.first(where: { model.playback[isCurrentTrack: $0.urn] })
            ?? tracks.first(where: { $0.urn == selectedTrackURN })
            ?? tracks.first
    }
    private var trackCount: Int { max(displayedPlaylist.trackCount ?? 0, tracks.count) }
    /// Rows to reserve before the first page arrives, so the card keeps its final height.
    private var displayedRowCount: Int {
        if contents?.hasLoadedPage == true || errorMessage != nil { return tracks.count }
        return max(displayedPlaylist.trackCount ?? 0, tracks.count)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            PlaylistCardArtwork(
                playlistURN: playlist.urn,
                displayedPlaylist: displayedPlaylist,
                tracks: tracks,
                model: model
            ) {
                onSelectPlaylist(displayedPlaylist)
            }
            .accessibilityLabel("Open playlist: \(displayedPlaylist.title)")
            .trackContextMenu(
                track: waveformTrack,
                likes: model.likes,
                onAddToQueue: model.addToQueue
            )
            .overlay(alignment: .bottomTrailing) {
                // Before the first page, the skeleton rows already show loading.
                if isLoading, !showsSkeleton {
                    LoadingSpinner()
                        .accessibilityLabel("Loading playlist")
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                        .padding(8)
                        .background(.regularMaterial, in: Circle())
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                PlaylistCardTitleRow(
                    playlist: displayedPlaylist,
                    cardState: cardState,
                    model: model,
                    playlists: playlists,
                    onSelect: { onSelectPlaylist(displayedPlaylist) }
                )

                ArtistLink(artist: displayedPlaylist.owner, onSelect: onSelectArtist)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let track = waveformTrack {
                    HStack(spacing: 10) {
                        playButton(for: track)
                        TrackWaveformView(
                            track: track,
                            model: model,
                            layout: .compact,
                            animatesBarTransitions: false,
                            onPlayTrack: play
                        )
                        .id(track.urn)
                        .frame(maxWidth: .infinity)
                    }
                } else if displayedRowCount > 0 {
                    HStack(spacing: 10) {
                        Button {} label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 36, height: 36)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.circle)
                        .disabled(true)
                        .accessibilityHidden(true)
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: TrackWaveformView.Layout.compact.height)
                    }
                }

                trackList
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .task(id: playlist.urn) {
            await playlists.loadPreview(playlist)
        }
        #if DEBUG
        .debugViewUpdates("PlaylistCardView")
        #endif
    }

    private var hasMoreTracks: Bool { trackCount > 5 || contents?.nextPageURL != nil }
    /// Rows are reserved for tracks that haven't arrived yet.
    private var showsSkeleton: Bool { tracks.isEmpty && displayedRowCount > 0 }
    private var hasLoadedTracks: Bool { contents?.hasLoadedPage == true }

    @ViewBuilder
    private var trackList: some View {
        // Keep the row hierarchy stable so toggling preserves loaded artwork.
        ScrollView {
            LazyVStack(spacing: 0) {
                trackRows(limit: isExpanded ? tracks.count : 5)
            }
        }
        .overlay(alignment: .top) {
            if showsSkeleton {
                PlaylistCardSkeletonRows(count: min(displayedRowCount, 5), isAnimating: isLoading)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: showsSkeleton)
        .frame(height: CGFloat(min(displayedRowCount, isExpanded ? 8 : 5)) * TrackListRow.compactHeight)
        .scrollDisabled(!isExpanded)
        // While collapsed, fade the bottom to hint at the tracks behind the toggle.
        .scrollEdgeFade(fadesBottom: !isExpanded && hasMoreTracks)

        if isExpanded || hasMoreTracks {
            Button(isExpanded ? "View fewer tracks" : "View \(trackCount) tracks") {
                isExpanded.toggle()
                if isExpanded { Task { await playlists.loadPlaylist(playlist) } }
            }
            .buttonStyle(.plain)
            // Expanding before the first page arrives would reveal empty rows.
            .disabled(!hasLoadedTracks)
            .foregroundStyle(isHoveringTrackToggle && hasLoadedTracks ? Color.primary : Color.secondary)
            .font(.callout)
            .onContentHover { isHoveringTrackToggle = $0 }
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .padding(.vertical, 8)
        }

        if let errorMessage {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Try Again") {
                Task {
                    if isExpanded { await playlists.loadPlaylist(playlist) }
                    else { await playlists.loadPreview(playlist) }
                }
            }
            .disabled(isLoading)
        }
        if !isLoading, contents?.hasLoadedPage == true, tracks.isEmpty, errorMessage == nil {
            Text(displayedPlaylist.trackCount == 0 ? "Empty playlist" : "No playable tracks")
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        }
    }

    private func trackRows(limit: Int) -> some View {
        TrackArtworkList(tracks: Array(tracks.prefix(limit)), loader: model.artworkLoader) { track in
            TrackListRow(
                track: track,
                playback: model.playback,
                analyzer: model.analyzer,
                artworkLoader: model.artworkLoader,
                likes: model.likes,
                showsArtist: false,
                isCompact: true,
                onAddToQueue: model.addToQueue,
                onSelectTrack: onSelectTrack,
                onSelectArtist: onSelectArtist,
                onPlayTrack: play
            )
        }
    }

    private func playButton(for track: SoundCloudTrack) -> some View {
        let isCurrentTrack = model.playback[isCurrentTrack: track.urn]
        let isPlaying = isCurrentTrack && model.playback.isPlaybackActive

        return Button {
            if isCurrentTrack {
                model.playback.togglePlayPause()
            } else {
                let startingTrack = model.playback.isShuffleEnabled ? (tracks.randomElement() ?? track) : track
                Task { await play(startingTrack) }
            }
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .contentHelp(isPlaying ? "Pause" : "Play")
        .accessibilityLabel("\(isPlaying ? "Pause" : "Play") \(track.title)")
    }

    private func play(_ track: SoundCloudTrack) async {
        selectedTrackURN = track.urn
        // The preview already contains the selected track. Start its stream
        // without waiting for playlist details, remaining pages, or disk writes.
        guard let loaded = contents else { return }
        await model.play(track, queue: TrackQueue(
            source: .playlist(playlist.urn),
            tracks: loaded.tracks,
            nextPageURL: loaded.nextPageURL, sourceTitle: loaded.playlist.title
        ), loadRemainingTracks: true)
    }
}

/// Placeholder rows matching the compact `TrackListRow` layout, shown before the first page loads.
private struct PlaylistCardSkeletonRows: View {
    let count: Int
    let isAnimating: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDimmed = false

    var body: some View {
        // One opacity animation on the container, so loading cards don't redraw each row.
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<count, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)
                    .frame(width: 40, height: 40)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 8)
                    .frame(height: TrackListRow.compactHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isDimmed ? 0.5 : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { updatePulse() }
        .onChange(of: isAnimating) { _, _ in updatePulse() }
    }

    private func updatePulse() {
        guard isAnimating, !reduceMotion else {
            withAnimation(nil) { isDimmed = false }
            return
        }
        withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
            isDimmed = true
        }
    }
}

/// Fades the scroll view's top and bottom edges while more content lies beyond them.
private struct ScrollEdgeFade: ViewModifier {
    var length: CGFloat = 32
    /// Fades the bottom edge even when the content does not extend past it.
    var fadesBottom = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var edges = Edges()

    private struct Edges: Equatable {
        var top = false
        var bottom = false
    }

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .onScrollGeometryChange(for: Edges.self) { geometry in
                    let offset = geometry.contentOffset.y + geometry.contentInsets.top
                    let maxOffset = geometry.contentSize.height - geometry.containerSize.height
                        + geometry.contentInsets.top + geometry.contentInsets.bottom
                    return Edges(top: offset > 1, bottom: offset < maxOffset - 1)
                } action: { _, newEdges in
                    edges = newEdges
                }
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.black.opacity(edges.top ? 0 : 1), .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: length)
                        Rectangle()
                        LinearGradient(colors: [.black, .black.opacity(edges.bottom || fadesBottom ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                            .frame(height: length)
                    }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: edges)
                }
        } else {
            content
                .mask {
                    VStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .black.opacity(fadesBottom ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                            .frame(height: length)
                    }
                }
        }
    }
}

private extension View {
    func scrollEdgeFade(length: CGFloat = 32, fadesBottom: Bool = false) -> some View {
        modifier(ScrollEdgeFade(length: length, fadesBottom: fadesBottom))
    }
}

// Keep title hover state here so underlining doesn't update the whole card.
private struct PlaylistCardTitleRow: View {
    let playlist: SoundCloudPlaylist
    let cardState: PlaylistCardState
    let model: AppModel
    let playlists: PlaylistsController
    let onSelect: () -> Void

    @State private var isHoveringTitle = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Button(action: onSelect) {
                Text(playlist.title)
                    .underline(isHoveringTitle)
                    .multilineTextAlignment(.leading)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .prefetch(.playlist(playlist)) { isHoveringTitle = $0 }
            .contentHelp(playlist.title)
            .accessibilityLabel("Playlist, \(playlist.title)")

            // Reserve the button's height so title rows match on cards that can't be liked.
            if playlist.isPrivate || playlist.isSystemPlaylist {
                likeButton.hidden()
            } else {
                likeButton
            }
        }
        .font(.title2.weight(.semibold))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var likeButton: some View {
        TrackCollectionLikeButton(
            isLiked: cardState.isLiked,
            isUpdating: cardState.isUpdatingLike,
            isLoading: cardState.isLoadingLike,
            subject: "playlist: \(playlist.title)",
            size: .card
        ) {
            Task {
                do {
                    try await playlists.toggleLike(playlist)
                } catch is CancellationError {
                } catch {
                    model.likeErrorMessage = error.localizedDescription
                }
            }
        }
    }
}

// Queue source and current-track metadata affect artwork independently of the
// card's track list. Keep those broader subscriptions, and hover, in this small subtree.
private struct PlaylistCardArtwork: View {
    let playlistURN: String
    let displayedPlaylist: SoundCloudPlaylist
    let tracks: [SoundCloudTrack]
    let model: AppModel
    let onSelect: () -> Void

    @State private var isHovering = false

    private var artworkURL: URL? {
        if let track = model.playback.currentTrack,
           model.queue.source == .playlist(playlistURN)
            || tracks.contains(where: { $0.urn == track.urn }) {
            return track.displayArtworkURL
        }
        return displayedPlaylist.artworkURL ?? tracks.first(where: { $0.displayArtworkURL != nil })?.displayArtworkURL
    }

    var body: some View {
        Button(action: onSelect) {
            TrackArtworkView(
                artworkURL: artworkURL,
                loader: model.artworkLoader,
                size: Self.size,
                rendition: .square500,
                shape: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous),
                showsBorder: false,
                animatesChanges: true
            )
            .modifier(ArtworkHoverZoom(
                isHovering: isHovering, cornerRadius: Self.cornerRadius, size: Self.size
            ))
        }
        .buttonStyle(.plain)
        // The pointer crosses large artwork on its way elsewhere.
        .prefetch(.playlist(displayedPlaylist), .pressOnly) { isHovering = $0 }
    }

    static let size: CGFloat = 150
    private static let cornerRadius: CGFloat = 10
}

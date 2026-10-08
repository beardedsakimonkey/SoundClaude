import SwiftUI

struct PlaylistDetailView: View {
    private let artworkSize: CGFloat = 250

    let playlist: SoundCloudPlaylist
    @ObservedObject var model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    let onDeletePlaylist: (SoundCloudPlaylist) -> Void

    @ObservedObject var playlists: PlaylistsController
    @ObservedObject var likes: LikesController

    private var contents: PlaylistContents? { playlists.cache.contents[playlist.urn] }
    private var tracks: [SoundCloudTrack] { contents?.tracks ?? [] }
    private var nextPageURL: URL? { contents?.nextPageURL }
    private var hasLoadedTracks: Bool { contents?.hasLoadedPage == true }
    private var isLoading: Bool { playlists.loadingPlaylistURNs.contains(playlist.urn) }
    private var errorMessage: String? { playlists.playlistErrors[playlist.urn] }
    @AppStorage("playlistTrackLayout") private var trackLayout = TrackLayout.list
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingArtwork = false
    @State private var isHoveringPlaylistLabel = false
    @State private var cachedFullSizeArtwork: CachedFullSizeArtwork?
    @State private var likeErrorMessage: String?
    @State private var editingPlaylist: SoundCloudPlaylist?
    @State private var playlistDeletion = PlaylistDeletionState()
    @State private var removeTrackErrorMessage: String?

    private var isOwnedByCurrentUser: Bool {
        guard !playlist.isSystemPlaylist, case let .signedIn(user) = model.auth.state,
              let urn = user.urn else { return false }
        return displayedPlaylist.owner.urn == urn
    }

    private var displayedPlaylist: SoundCloudPlaylist { contents?.playlist ?? playlist }
    private var currentPlaylistTrack: SoundCloudTrack? {
        guard model.queue.source == .playlist(playlist.urn) else { return nil }
        return model.playback.currentTrack
    }

    private var startingTrack: SoundCloudTrack? { tracks.first }

    private var displayedTrack: SoundCloudTrack? { currentPlaylistTrack ?? startingTrack }

    private var artworkURL: URL? {
        if let track = displayedTrack {
            return track.displayArtworkURL
        }
        return displayedPlaylist.artworkURL
    }

    private var artworkTitle: String { displayedTrack?.title ?? displayedPlaylist.title }

    private var artworkTrack: SoundCloudTrack? { displayedTrack }

    var body: some View {
        ScrollbarReservedScrollView { _ in
            VStack(alignment: .leading, spacing: 24) {
                header
                VStack(alignment: .leading, spacing: trackLayout == .list ? 8 : 24) {
                    HStack {
                        CountedSectionHeader(
                            title: "Tracks",
                            count: displayedPlaylist.trackCount ?? tracks.count
                        )
                        Spacer()
                        TrackLayoutPicker(trackLayout: $trackLayout)
                    }
                    .modifier(FadeInOnAppear())
                    if let message = model.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color.accentColor)
                    }
                    trackList
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .background(alignment: .top) {
            TrackCollectionBackdrop(artworkURL: artworkURL, loader: model.artworkLoader)
                .ignoresSafeArea(edges: .top)
        }
        .navigationTitle(displayedPlaylist.title)
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible, placement: .primaryAction)
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Spacer()
                }
            }
            if isOwnedByCurrentUser {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            editingPlaylist = displayedPlaylist
                        } label: {
                            Label("Edit playlist", systemImage: "pencil")
                        }
                        .disabled(playlists.updatingPlaylistURNs.contains(playlist.urn)
                            || playlistDeletion.deletingURNs.contains(playlist.urn))
                        DeletePlaylistButton(playlist: displayedPlaylist, state: $playlistDeletion)
                    } label: {
                        Label("Playlist actions", systemImage: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                    .disabled(playlistDeletion.deletingURNs.contains(playlist.urn))
                    .contentHelp("Playlist actions")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                OpenInSoundCloudButton(url: displayedPlaylist.permalinkURL)
                    .contentHelp("Open this playlist in your web browser")
            }
        }
        .task(id: playlist.urn) {
            await load()
        }
        .task(id: displayedPlaylist.isPrivate) {
            if playlist.isSystemPlaylist {
                do {
                    try await likes.loadStationLikes()
                } catch {
                    likeErrorMessage = error.localizedDescription
                }
            } else if !displayedPlaylist.isPrivate {
                await playlists.loadLikes()
            }
        }
        .alert("Could not update playlist like", isPresented: Binding(
            get: { likeErrorMessage != nil },
            set: { if !$0 { likeErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { likeErrorMessage = nil }
        } message: {
            Text(likeErrorMessage ?? "Please try again.")
        }
        .sheet(item: $editingPlaylist) { playlist in
            PlaylistEditorView(playlists: playlists, playlist: playlist)
        }
        .modifier(PlaylistDeletionModifier(
            state: $playlistDeletion, playlists: playlists, onDeleted: onDeletePlaylist
        ))
        .alert("Could not remove track", isPresented: Binding(
            get: { removeTrackErrorMessage != nil },
            set: { if !$0 { removeTrackErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { removeTrackErrorMessage = nil }
        } message: {
            Text(removeTrackErrorMessage ?? "Please try again.")
        }
        .sheet(isPresented: $isShowingArtwork) {
            FullSizeArtworkView(
                title: artworkTitle,
                artworkURL: artworkURL,
                loader: model.artworkLoader,
                cachedArtwork: $cachedFullSizeArtwork
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 24) {
            artworkAndPlayback
            if let description = displayedPlaylist.description?
                .trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
                ExpandableDescriptionText(
                    description: description,
                    onSelectArtist: onSelectArtist
                )
            }
            if !displayedPlaylist.tags.isEmpty {
                TagLayout {
                    ForEach(Array(displayedPlaylist.tags.enumerated()), id: \.offset) { _, tag in
                        TagPill(tag: tag)
                    }
                }
                .modifier(FadeInOnAppear())
            }
            if !playlist.isSystemPlaylist || playlistTimestamp.hasTimestamp {
                playlistMetadata
            }
        }
    }

    private var artworkAndPlayback: some View {
        HStack(alignment: .top, spacing: 24) {
            playlistArtwork
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label("Playlist: \(displayedPlaylist.title)", systemImage: "music.note.list")
                        .labelStyle(.titleAndIcon)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                        .accessibilityLabel("Playlist, \(displayedPlaylist.title)")
                    if displayedPlaylist.isPrivate {
                        Image(systemName: "lock.fill")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Private playlist")
                    }
                    if !displayedPlaylist.isPrivate {
                        likeButton
                            .opacity(isHoveringPlaylistLabel ? 1 : 0)
                            .animation(.easeInOut(duration: 0.2), value: isHoveringPlaylistLabel)
                    }
                }
                .contentShape(Rectangle())
                .onContentHover { isHoveringPlaylistLabel = $0 }
                .modifier(FadeInOnAppear())
                Group {
                    if let displayedTrack {
                        DetailTrackHeadingSlot(
                            track: displayedTrack,
                            isCollection: true,
                            collectionURN: playlist.urn,
                            artworkLoader: model.artworkLoader,
                            onSelectTrack: onSelectTrack,
                            onSelectArtist: onSelectArtist
                        )
                    } else {
                        Color.clear
                    }
                }
                .frame(minHeight: 64, alignment: .leading)

                VStack(alignment: .leading, spacing: 16) {
                    ViewThatFits(in: .horizontal) {
                        playbackControls(iconOnly: false)
                            .labelStyle(.titleAndIcon)
                            .fixedSize(horizontal: true, vertical: false)
                        playbackControls(iconOnly: true)
                            .labelStyle(.iconOnly)
                    }
                    if !playlist.isSystemPlaylist, !displayedPlaylist.isPrivate, let error = playlists.likesErrorMessage {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                        Button("Retry likes") { Task { await playlists.loadLikes() } }
                    }
                }
                .padding(.top, 8)
                .modifier(FadeInOnAppear())
                Spacer(minLength: 6)
                TrackWaveformView(
                    track: displayedTrack,
                    model: model,
                    invertsBarsOnTrackChange: true,
                    collapsesBarsWhenPaused: true,
                    keepsBarsVisible: true,
                    onPlayTrack: playTrack
                )
                .offset(y: -2)
            }
            // Match the track detail header's waveform ground and reflection.
            .frame(
                maxWidth: .infinity,
                minHeight: artworkSize + TrackWaveformView.Layout.detail.reflectionHeight,
                alignment: .topLeading
            )
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var playlistTimestamp: RelativeTimestampView {
        RelativeTimestampView(
            timestamp: displayedPlaylist.lastModified,
            accessibilityPrefix: "Last updated",
            prefix: "Updated",
            showsSeparator: false,
            systemImage: "clock"
        )
    }

    private var playlistMetadata: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            playlistTimestamp
            if !playlist.isSystemPlaylist {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("by")
                    ArtistLink(
                        artist: displayedPlaylist.owner,
                        onSelect: onSelectArtist
                    )
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .opacity(0.9)
        .lineLimit(1)
        .modifier(FadeInOnAppear())
    }

    private var playlistArtwork: some View {
        ZStack {
            DetailArtworkView(
                artworkURL: artworkURL,
                title: artworkTitle,
                loader: model.artworkLoader,
                size: artworkSize,
                cornerRadius: 12,
                track: artworkTrack,
                likes: model.likes,
                onAddToQueue: model.addToQueue,
                onRemoveFromPlaylist: isOwnedByCurrentUser ? removeTrack : nil,
                isUpdatingPlaylist: playlists.updatingPlaylistURNs.contains(playlist.urn),
                onShowArtwork: { isShowingArtwork = true }
            )
            .id(artworkTrack?.urn)
            .transition(DetailArtworkTransition(playback: model.playback, reduceMotion: reduceMotion))
        }
        .modifier(DetailArtworkTrackAnimation(trackURN: artworkTrack?.urn))
        .modifier(DetailArtworkRotation(
            isShowingArtwork: isShowingArtwork,
            flattensOnHover: true
        ))
    }

    private func playbackControls(iconOnly: Bool) -> some View {
        HStack(spacing: 12) {
            playButton(iconOnly: iconOnly)
            trackNavigationButtons
            if let track = displayedTrack {
                DetailLikeButton(
                    isLiked: likes.isLiked(track),
                    isUpdating: likes.updatingTrackURNs.contains(track.urn),
                    likeCount: likes.likeCount(for: track),
                    iconOnly: iconOnly,
                    subject: "track: \(track.title)"
                ) {
                    Task {
                        do {
                            try await likes.toggleLike(track)
                        } catch {
                            model.likeErrorMessage = error.localizedDescription
                        }
                    }
                }
                .detailSlot(trackURN: track.urn, isCollection: true)
            }
        }
    }

    private func playButton(iconOnly: Bool) -> some View {
        let isStarting = currentPlaylistTrack == nil
        let isPlaying = !isStarting && model.playback.isPlaybackActive
        return DetailPlayButtonSlot(configuration: DetailPlayButtonConfiguration(
            trackURN: displayedTrack?.urn, isCollection: true,
            isStarting: isStarting, isPlaying: isPlaying,
            isEnabled: currentPlaylistTrack != nil || !tracks.isEmpty,
            iconOnly: iconOnly, subject: "playlist"
        )) {
            if currentPlaylistTrack != nil {
                model.playback.togglePlayPause()
            } else if let track = startingTrack {
                Task {
                    await model.play(track, queue: TrackQueue(
                        source: .playlist(playlist.urn), tracks: tracks, nextPageURL: nextPageURL
                    ))
                }
            }
        }
    }

    private var trackNavigationButtons: some View {
        Group {
            Button {
                navigateTrack(backward: true)
            } label: {
                Label("Previous track", systemImage: "backward.fill")
                    .frame(width: 44, height: 24)
            }
            .contentHelp("Previous track")
            .accessibilityLabel("Previous track")

            Button {
                navigateTrack(backward: false)
            } label: {
                Label("Next track", systemImage: "forward.fill")
                    .frame(width: 44, height: 24)
            }
            .contentHelp("Next track")
            .accessibilityLabel("Next track")
        }
        .labelStyle(.iconOnly)
        .font(.title3.weight(.semibold))
        .buttonStyle(TrackActionButtonStyle(fill: .primary.opacity(0.12)))
        .disabled(currentPlaylistTrack == nil && tracks.isEmpty)
    }

    private func navigateTrack(backward: Bool) {
        if currentPlaylistTrack != nil {
            if backward {
                model.playback.previous()
                if !model.playback.isPlaybackActive {
                    model.playback.togglePlayPause()
                }
            } else {
                model.playback.next()
            }
        } else if let track = startingTrack {
            model.navigateTrack(from: track, offset: backward ? -1 : 1, queue: TrackQueue(
                source: .playlist(playlist.urn), tracks: tracks, nextPageURL: nextPageURL
            ))
        }
    }

    private var likeButton: some View {
        let isLiked = playlist.isSystemPlaylist
            ? likes.likedStationURNs.contains(playlist.urn)
            : playlists.likedPlaylistURNs.contains(playlist.urn)
        let actionLabel = "\(isLiked ? "Unlike" : "Like") playlist: \(displayedPlaylist.title)"
        return Button {
            Task {
                do {
                    if playlist.isSystemPlaylist {
                        try await likes.toggleStationLike(urn: playlist.urn, title: displayedPlaylist.title)
                    } else {
                        try await playlists.toggleLike(displayedPlaylist)
                    }
                } catch {
                    likeErrorMessage = error.localizedDescription
                }
            }
        } label: {
            Image(systemName: isLiked ? "heart.fill" : "heart")
                .foregroundStyle(.secondary)
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentHelp(actionLabel)
        .accessibilityLabel(actionLabel)
        .accessibilityValue(isLiked ? "Liked" : "Not liked")
        .disabled(playlist.isSystemPlaylist
            ? !likes.hasLoadedStationLikes || likes.updatingStationURNs.contains(playlist.urn)
            : !playlists.hasLoadedLikes || playlists.updatingLikeURNs.contains(playlist.urn))
    }

    private var trackList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            TrackCollectionTracks(
                tracks: tracks, trackLayout: trackLayout, model: model,
                onSelectTrack: onSelectTrack, onSelectArtist: onSelectArtist,
                onPlayTrack: playTrack,
                onRemoveFromPlaylist: isOwnedByCurrentUser ? removeTrack : nil,
                isUpdatingPlaylist: playlists.updatingPlaylistURNs.contains(playlist.urn)
            )
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.secondary)
                Button("Try Again") { Task { await load() } }
                    .disabled(isLoading)
            }
            if isLoading {
                LoadingSpinner()
                    .accessibilityLabel("Loading playlist")
                    .frame(maxWidth: .infinity)
            } else if hasLoadedTracks, tracks.isEmpty, errorMessage == nil {
                EmptyStateView(displayedPlaylist.trackCount == 0 ? "Empty playlist" : "No playable tracks")
            }
        }
    }

    private func removeTrack(_ track: SoundCloudTrack) {
        Task {
            do {
                try await playlists.removeTrack(track, from: displayedPlaylist)
            } catch is CancellationError {
            } catch {
                removeTrackErrorMessage = error.localizedDescription
            }
        }
    }

    private func playTrack(_ track: SoundCloudTrack) async {
        await model.play(track, queue: TrackQueue(
            source: .playlist(playlist.urn),
            tracks: tracks,
            nextPageURL: nextPageURL
        ))
    }

    private func load() async {
        await playlists.loadPlaylist(playlist)
    }
}

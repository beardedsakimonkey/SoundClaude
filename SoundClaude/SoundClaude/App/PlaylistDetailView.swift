import SwiftUI

struct PlaylistDetailView: View {
    private let artworkSize: CGFloat = 250

    let playlist: SoundCloudPlaylist
    let model: AppModel
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
    @State private var cachedFullSizeArtwork: CachedFullSizeArtwork?
    @State private var likeErrorMessage: String?
    @State private var editingPlaylist: SoundCloudPlaylist?
    @State private var playlistDeletion = PlaylistDeletionState()
    @State private var removeTrackErrorMessage: String?
    @State private var removingTrackURN: String?

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
                VStack(alignment: .leading, spacing: trackLayout == .list ? 4 : 12) {
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
            TrackCollectionPlaybackContent {
                TrackCollectionBackdrop(artworkURL: artworkURL, loader: model.artworkLoader)
                    .ignoresSafeArea(edges: .top)
            }
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
        #if DEBUG
        .debugViewUpdates("PlaylistDetailView")
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 24) {
            TrackCollectionPlaybackContent {
                artworkAndPlayback
            }
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
                PlaylistNameRow(title: displayedPlaylist.title) {
                    if !displayedPlaylist.isPrivate {
                        likeButton
                    }
                    if isOwnedByCurrentUser {
                        playlistEditingButtons
                    }
                }
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
        VStack(alignment: .leading, spacing: 8) {
            if displayedPlaylist.isPrivate {
                if isOwnedByCurrentUser {
                    PlaylistPrivacyButton {
                        editingPlaylist = displayedPlaylist
                    }
                    .disabled(playlists.updatingPlaylistURNs.contains(playlist.urn)
                        || playlistDeletion.deletingURNs.contains(playlist.urn))
                } else {
                    Label("Private", systemImage: "lock.fill")
                        .labelStyle(.titleAndIcon)
                }
            }
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
        return CollectionPlayButtonSlot(
            playback: model.playback,
            trackURN: displayedTrack?.urn,
            isStarting: isStarting,
            isEnabled: currentPlaylistTrack != nil || !tracks.isEmpty,
            iconOnly: iconOnly, subject: "playlist"
        ) {
            if currentPlaylistTrack != nil {
                model.playback.togglePlayPause()
            } else if let track = startingTrack {
                Task {
                    await model.play(track, queue: TrackQueue(
                        source: .playlist(playlist.urn), tracks: tracks, nextPageURL: nextPageURL, playlistTitle: displayedPlaylist.title
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
                source: .playlist(playlist.urn), tracks: tracks, nextPageURL: nextPageURL, playlistTitle: displayedPlaylist.title
            ))
        }
    }

    private var playlistEditingButtons: some View {
        HStack(spacing: 8) {
            Button {
                editingPlaylist = displayedPlaylist
            } label: {
                Image(systemName: "pencil")
            }
            .contentHelp("Edit playlist")
            .accessibilityLabel("Edit playlist")
            .disabled(playlists.updatingPlaylistURNs.contains(playlist.urn)
                || playlistDeletion.deletingURNs.contains(playlist.urn))

            DeletePlaylistButton(playlist: displayedPlaylist, state: $playlistDeletion)
                .labelStyle(.iconOnly)
                .contentHelp("Delete playlist")
        }
        .buttonStyle(PlaylistHeaderButtonStyle())
        .fixedSize()
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
        }
        .buttonStyle(PlaylistHeaderButtonStyle())
        .contentHelp(actionLabel)
        .accessibilityLabel(actionLabel)
        .accessibilityValue(isLiked ? "Liked" : "Not liked")
        .disabled(playlist.isSystemPlaylist
            ? !likes.hasLoadedStationLikes || likes.updatingStationURNs.contains(playlist.urn)
            : !playlists.hasLoadedLikes || playlists.updatingLikeURNs.contains(playlist.urn))
    }

    private var trackList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            PlaylistTrackList(
                playlist: displayedPlaylist, tracks: tracks, nextPageURL: nextPageURL,
                trackLayout: trackLayout, model: model,
                onSelectTrack: onSelectTrack, onSelectArtist: onSelectArtist,
                onRemoveFromPlaylist: isOwnedByCurrentUser ? removeTrack : nil,
                isUpdatingPlaylist: removingTrackURN != nil || playlists.updatingPlaylistURNs.contains(playlist.urn),
                removingTrackURN: removingTrackURN
            )
            .equatable()
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
        guard removingTrackURN == nil,
              !playlists.updatingPlaylistURNs.contains(playlist.urn) else { return }
        removingTrackURN = track.urn
        let targetPlaylist = displayedPlaylist
        Task {
            defer { removingTrackURN = nil }
            do {
                try await playlists.removeTrack(track, from: targetPlaylist)
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
            nextPageURL: nextPageURL, playlistTitle: displayedPlaylist.title
        ))
    }

    private func load() async {
        await playlists.loadPlaylist(playlist)
    }
}

// Keep pointer updates local so they do not invalidate the playlist detail body.
private struct PlaylistNameRow<Actions: View>: View {
    let title: String
    @ViewBuilder let actions: Actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Label {
                Text("Playlist: \(Text(title).foregroundStyle(Color.primary.opacity(0.9)))")
            } icon: {
                Image(systemName: "music.note.list")
            }
            .labelStyle(.titleAndIcon)
            .font(.body)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .textSelection(.enabled)
            .accessibilityLabel("Playlist, \(title)")

            actions
                .opacity(isHovered ? 1 : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isHovered)
        }
        .contentShape(Rectangle())
        .onContentHover { isHovered = $0 }
    }
}

private struct PlaylistPrivacyButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label {
                Text("Private")
                    .underline(isHovered)
            } icon: {
                Image(systemName: "lock.fill")
            }
            .labelStyle(.titleAndIcon)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onContentHover { isHovered = $0 }
        .contentHelp("Edit playlist privacy")
        .accessibilityLabel("Private playlist, edit privacy")
    }
}

private struct PlaylistHeaderButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let isHighlighted = isEnabled && (isHovered || configuration.isPressed)
        let isDestructive = configuration.role == .destructive
        let foreground: Color = isDestructive ? .red : (isHighlighted ? .primary : .secondary)
        let background: Color = isDestructive ? .red : .primary

        configuration.label
            .foregroundStyle(foreground)
            .padding(4)
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(background.opacity(isHighlighted ? (configuration.isPressed ? 0.16 : 0.08) : 0))
            }
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.5)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHighlighted)
            .onContentHover { isHovered = $0 }
            .onDisappear { isHovered = false }
    }
}

// Starting playback invalidates the page header. Compare only the inputs the row
// closures capture so the rows are not re-rendered with fresh closures.
private struct PlaylistTrackList: View, Equatable {
    let playlist: SoundCloudPlaylist
    let tracks: [SoundCloudTrack]
    let nextPageURL: URL?
    let trackLayout: TrackLayout
    let model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    let onRemoveFromPlaylist: ((SoundCloudTrack) -> Void)?
    let isUpdatingPlaylist: Bool
    let removingTrackURN: String?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.playlist == rhs.playlist && lhs.tracks == rhs.tracks
            && lhs.nextPageURL == rhs.nextPageURL && lhs.trackLayout == rhs.trackLayout
            && (lhs.onRemoveFromPlaylist == nil) == (rhs.onRemoveFromPlaylist == nil)
            && lhs.isUpdatingPlaylist == rhs.isUpdatingPlaylist
            && lhs.removingTrackURN == rhs.removingTrackURN
    }

    var body: some View {
        TrackCollectionTracks(
            tracks: tracks, trackLayout: trackLayout, model: model,
            onSelectTrack: onSelectTrack, onSelectArtist: onSelectArtist,
            onPlayTrack: playTrack,
            fadesInTracks: true,
            onRemoveFromPlaylist: onRemoveFromPlaylist,
            isUpdatingPlaylist: isUpdatingPlaylist,
            removingTrackURN: removingTrackURN
        )
    }

    private func playTrack(_ track: SoundCloudTrack) async {
        await model.play(track, queue: TrackQueue(
            source: .playlist(playlist.urn),
            tracks: tracks,
            nextPageURL: nextPageURL, playlistTitle: playlist.title
        ))
    }
}

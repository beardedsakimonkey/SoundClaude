import SwiftUI

struct PlaylistDetailView: View {
    let playlist: SoundCloudPlaylist
    let model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    let onDeletePlaylist: (SoundCloudPlaylist) -> Void

    @ObservedObject var playlists: PlaylistsController
    let likes: LikesController

    private var contents: PlaylistContents? { playlists.cache.contents[playlist.urn] }
    private var tracks: [SoundCloudTrack] { contents?.tracks ?? [] }
    private var nextPageURL: URL? { contents?.nextPageURL }
    private var hasLoadedTracks: Bool { contents?.hasLoadedPage == true }
    private var isLoading: Bool { playlists.loadingPlaylistURNs.contains(playlist.urn) }
    private var errorMessage: String? { playlists.playlistErrors[playlist.urn] }
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
    private var collection: TrackCollection {
        TrackCollection(
            kind: .playlist, urn: playlist.urn, title: displayedPlaylist.title, tracks: tracks,
            nextPageURL: nextPageURL, fallbackArtworkURL: displayedPlaylist.artworkURL
        )
    }

    var body: some View {
        ScrollbarReservedScrollView { _ in
            VStack(alignment: .leading, spacing: 24) {
                header
                TrackCollectionSection(
                    count: displayedPlaylist.trackCount ?? tracks.count,
                    errorMessage: model.errorMessage
                ) { trackLayout in
                    trackList(trackLayout: trackLayout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(24)
        }
        .background(alignment: .top) {
            TrackCollectionBackdrop(collection: collection, model: model)
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
                ToolbarItemGroup(placement: .primaryAction) {
                    playlistEditingButtons
                }
                if #available(macOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .primaryAction)
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
                // Load failures are shown with a retry action in the sidebar.
                try? await likes.loadStationLikes()
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
        #if DEBUG
        .debugViewUpdates("PlaylistDetailView")
        #endif
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
        TrackCollectionHeader(
            collection: collection,
            model: model,
            likes: likes,
            onRemoveFromPlaylist: isOwnedByCurrentUser ? removeTrack : nil,
            isUpdatingPlaylist: playlists.updatingPlaylistURNs.contains(playlist.urn),
            onSelectTrack: onSelectTrack,
            onSelectArtist: onSelectArtist
        ) {
            TrackCollectionTitleRow {
                Label {
                    Text(displayedPlaylist.title)
                        .foregroundStyle(Color.primary.opacity(0.9))
                } icon: {
                    Image(systemName: "music.note.list")
                }
                .textSelection(.enabled)
                .accessibilityLabel("Playlist, \(displayedPlaylist.title)")
            } actions: {
                // Private playlists cannot be liked; reserve the button's height so the
                // header lines up with stations.
                if displayedPlaylist.isPrivate {
                    likeButton.hidden()
                } else {
                    likeButton
                }
            }
        } controlsFooter: {
            if !playlist.isSystemPlaylist, !displayedPlaylist.isPrivate, let error = playlists.likesErrorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary)
                Button("Retry likes") { Task { await playlists.loadLikes() } }
            }
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

    @ViewBuilder
    private var playlistEditingButtons: some View {
        Button {
            editingPlaylist = displayedPlaylist
        } label: {
            Label("Edit Playlist", systemImage: "pencil")
                .labelStyle(.iconOnly)
                .frame(width: 20, height: 20)
        }
        .contentHelp("Edit playlist")
        .disabled(playlists.updatingPlaylistURNs.contains(playlist.urn)
            || playlistDeletion.deletingURNs.contains(playlist.urn))

        Button(role: .destructive) {
            playlistDeletion.pendingPlaylist = displayedPlaylist
        } label: {
            Label("Delete Playlist", systemImage: "trash")
                .labelStyle(.iconOnly)
                .frame(width: 20, height: 20)
        }
        .contentHelp("Delete playlist")
        .disabled(playlistDeletion.deletingURNs.contains(playlist.urn))
    }

    private var likeButton: some View {
        TrackCollectionLikeButton(
            isLiked: playlist.isSystemPlaylist
                ? likes.likedStationURNs.contains(playlist.urn)
                : playlists.likedPlaylistURNs.contains(playlist.urn),
            isUpdating: playlist.isSystemPlaylist
                ? !likes.hasLoadedStationLikes || likes.updatingStationURNs.contains(playlist.urn)
                : !playlists.hasLoadedLikes || playlists.updatingLikeURNs.contains(playlist.urn),
            subject: "playlist: \(displayedPlaylist.title)"
        ) {
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
        }
    }

    private func trackList(trackLayout: TrackLayout) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            TrackCollectionTrackList(
                collection: collection, trackLayout: trackLayout, model: model,
                onSelectTrack: onSelectTrack, onSelectArtist: onSelectArtist,
                onRemoveFromPlaylist: isOwnedByCurrentUser ? removeTrack : nil,
                isUpdatingPlaylist: removingTrackURN != nil || playlists.updatingPlaylistURNs.contains(playlist.urn),
                removingTrackURN: removingTrackURN
            )
            .equatable()
            TrackCollectionLoadStatus(
                errorMessage: errorMessage,
                isLoading: isLoading,
                isEmpty: hasLoadedTracks && tracks.isEmpty,
                loadingLabel: "Loading playlist",
                emptyMessage: displayedPlaylist.trackCount == 0 ? "Empty playlist" : "No playable tracks",
                onRetry: { Task { await load() } }
            )
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

    private func load() async {
        await playlists.loadPlaylist(playlist)
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

import SwiftUI

struct PlaylistDetailView: View {
    private let artworkSize: CGFloat = 250

    let playlist: SoundCloudPlaylist
    @ObservedObject var model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void

    @ObservedObject var playlists: PlaylistsController

    private var contents: PlaylistContents? { playlists.cache.contents[playlist.urn] }
    private var tracks: [SoundCloudTrack] { contents?.tracks ?? [] }
    private var nextPageURL: URL? { contents?.nextPageURL }
    private var hasLoadedTracks: Bool { contents?.hasLoadedPage == true }
    private var isLoading: Bool { playlists.loadingPlaylistURNs.contains(playlist.urn) }
    private var errorMessage: String? { playlists.playlistErrors[playlist.urn] }
    @AppStorage("playlistTrackLayout") private var trackLayout = TrackLayout.list
    @State private var isShowingArtwork = false
    @State private var cachedFullSizeArtwork: CachedFullSizeArtwork?
    @State private var likeErrorMessage: String?
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingDeletion = false
    @State private var isDeleting = false
    @State private var deleteErrorMessage: String?

    private var isOwnedByCurrentUser: Bool {
        guard case let .signedIn(user) = model.auth.state,
              let urn = user.urn else { return false }
        return displayedPlaylist.owner.urn == urn
    }

    private var displayedPlaylist: SoundCloudPlaylist { contents?.playlist ?? playlist }
    private var currentPlaylistTrack: SoundCloudTrack? {
        guard let track = model.playback.currentTrack,
              model.queue.source == .playlist(playlist.urn)
                || tracks.contains(where: { $0.urn == track.urn }) else { return nil }
        return track
    }

    private var artworkURL: URL? {
        if let track = currentPlaylistTrack {
            return track.displayArtworkURL
        }
        return displayedPlaylist.artworkURL ?? tracks.first(where: { $0.displayArtworkURL != nil })?.displayArtworkURL
    }

    private var artworkTitle: String { currentPlaylistTrack?.title ?? displayedPlaylist.title }

    var body: some View {
        ZStack(alignment: .top) {
            artworkBackdrop
                .ignoresSafeArea(edges: .top)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if let description = displayedPlaylist.description?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
                        ExpandableDescriptionText(
                            description: description,
                            onSelectArtist: onSelectArtist
                        )
                    }
                    HStack {
                        CountedSectionHeader(
                            title: "Tracks",
                            count: displayedPlaylist.trackCount ?? tracks.count
                        )
                        Spacer()
                        TrackLayoutPicker(trackLayout: $trackLayout)
                    }
                    if let message = model.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    trackList
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
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
            if isOwnedByCurrentUser {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Delete Playlist…", systemImage: "trash", role: .destructive) {
                            isConfirmingDeletion = true
                        }
                    } label: {
                        Label("Playlist actions", systemImage: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                    .disabled(isDeleting)
                    .help("Playlist actions")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                OpenInSoundCloudButton(url: displayedPlaylist.permalinkURL)
                    .help("Open this playlist in your web browser")
            }
        }
        .task(id: playlist.urn) {
            await load()
        }
        .task(id: displayedPlaylist.isPrivate) {
            if !displayedPlaylist.isPrivate { await playlists.loadLikes() }
        }
        .alert("Could not update playlist like", isPresented: Binding(
            get: { likeErrorMessage != nil },
            set: { if !$0 { likeErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { likeErrorMessage = nil }
        } message: {
            Text(likeErrorMessage ?? "Please try again.")
        }
        .confirmationDialog("Delete \(displayedPlaylist.title)?", isPresented: $isConfirmingDeletion,
                            titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) {
                isDeleting = true
                Task {
                    defer { isDeleting = false }
                    do {
                        try await playlists.deletePlaylist(displayedPlaylist)
                        dismiss()
                    } catch {
                        deleteErrorMessage = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the playlist from SoundCloud.")
        }
        .alert("Could not delete playlist", isPresented: Binding(
            get: { deleteErrorMessage != nil },
            set: { if !$0 { deleteErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { deleteErrorMessage = nil }
        } message: {
            Text(deleteErrorMessage ?? "Please try again.")
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

    @ViewBuilder
    private var artworkBackdrop: some View {
        let backdrop = TrackArtworkBackdropView(
            artworkURL: artworkURL,
            loader: model.artworkLoader,
            fadesToBottom: false,
            animatesChanges: true
        )
        .frame(height: 600)
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.25),
                    .init(color: .black.opacity(0.5), location: 0.65),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }

        if #available(macOS 26.0, *) {
            backdrop.backgroundExtensionEffect()
        } else {
            backdrop
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            playlistArtwork
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "music.note.list")
                        .accessibilityLabel("Playlist")
                    Text(displayedPlaylist.title)
                        .textSelection(.enabled)
                }
                .font(.system(size: 28, weight: .semibold))
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ArtistLink(
                        artist: displayedPlaylist.owner,
                        artworkLoader: model.artworkLoader,
                        onSelect: onSelectArtist
                    )

                    RelativeTimestampView(
                        timestamp: displayedPlaylist.lastModified,
                        accessibilityPrefix: "Last updated",
                        prefix: "Updated"
                    )

                    if displayedPlaylist.isPrivate {
                        Text("·")
                            .accessibilityHidden(true)
                        Label("Private", systemImage: "lock.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .accessibilityLabel("Private playlist")
                    }
                }
                .font(.title3)
                .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        playButton
                        trackNavigationButtons
                        if !displayedPlaylist.isPrivate { likeButton }
                    }
                    if !displayedPlaylist.isPrivate, let error = playlists.likesErrorMessage {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                        Button("Retry likes") { Task { await playlists.loadLikes() } }
                    }
                }
                .padding(.top, 8)

                if let track = currentPlaylistTrack {
                    Spacer(minLength: 6)
                    TrackWaveformView(
                        track: track,
                        model: model,
                        invertsBarsOnTrackChange: true,
                        collapsesBarsWhenPaused: true
                    )
                    .offset(y: -2)
                }
            }
            // Match the track detail header's waveform ground and reflection.
            .frame(
                maxWidth: .infinity,
                minHeight: currentPlaylistTrack != nil
                    ? artworkSize + TrackWaveformView.Layout.detail.reflectionHeight : nil,
                alignment: .topLeading
            )
        }
    }

    private var playlistArtwork: some View {
        DetailArtworkView(
            artworkURL: artworkURL,
            title: artworkTitle,
            loader: model.artworkLoader,
            size: artworkSize,
            animatesChanges: true,
            onShowArtwork: { isShowingArtwork = true }
        )
    }

    private var playButton: some View {
        let isPlaying = currentPlaylistTrack != nil && model.playback.isPlaybackActive
        return Button {
            if currentPlaylistTrack != nil {
                model.playback.togglePlayPause()
            } else if let track = tracks.first {
                Task {
                    await model.play(track, queue: TrackQueue(
                        source: .playlist(playlist.urn), tracks: tracks, nextPageURL: nextPageURL
                    ))
                }
            }
        } label: {
            ZStack {
                Label("Play", systemImage: "play.fill")
                    .opacity(isPlaying ? 0 : 1)
                    .accessibilityHidden(isPlaying)
                Label("Pause", systemImage: "pause.fill")
                    .opacity(isPlaying ? 1 : 0)
                    .accessibilityHidden(!isPlaying)
            }
            .labelStyle(.titleAndIcon)
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 24)
            .frame(minHeight: 24)
        }
        .buttonStyle(TrackActionButtonStyle(fill: .primary.opacity(0.12)))
        .disabled(currentPlaylistTrack == nil && tracks.isEmpty)
        .help(isPlaying ? "Pause playlist" : "Play playlist")
        .accessibilityLabel(isPlaying ? "Pause playlist" : "Play playlist")
    }

    private var trackNavigationButtons: some View {
        Group {
            Button(action: model.playback.previous) {
                Label("Previous track", systemImage: "backward.fill")
                    .frame(width: 44, height: 24)
            }
            .help("Previous track")
            .accessibilityLabel("Previous track")

            Button(action: model.playback.next) {
                Label("Next track", systemImage: "forward.fill")
                    .frame(width: 44, height: 24)
            }
            .help("Next track")
            .accessibilityLabel("Next track")
        }
        .labelStyle(.iconOnly)
        .font(.title3.weight(.semibold))
        .buttonStyle(TrackActionButtonStyle(fill: .primary.opacity(0.12)))
        .disabled(currentPlaylistTrack == nil)
    }

    private var likeButton: some View {
        DetailLikeButton(
            isLiked: playlists.likedPlaylistURNs.contains(playlist.urn),
            subject: "playlist"
        ) {
            Task {
                do {
                    try await playlists.toggleLike(displayedPlaylist)
                } catch {
                    likeErrorMessage = error.localizedDescription
                }
            }
        }
        .disabled(!playlists.hasLoadedLikes || playlists.updatingLikeURNs.contains(playlist.urn))
    }

    private var trackList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if trackLayout == .grid {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 160), spacing: 20, alignment: .top)],
                    alignment: .leading,
                    spacing: 24
                ) {
                    ForEach(tracks) { track in
                        TrackGridTile(
                            track: track,
                            playback: model.playback,
                            analyzer: model.analyzer,
                            artworkLoader: model.artworkLoader,
                            onSelectTrack: onSelectTrack,
                            onSelectArtist: onSelectArtist,
                            onPlayTrack: playTrack
                        )
                    }
                }
                .padding(.bottom, 16)
            } else {
                ForEach(tracks) { track in
                    TrackListRow(
                        track: track,
                        playback: model.playback,
                        analyzer: model.analyzer,
                        artworkLoader: model.artworkLoader,
                        likes: model.likes,
                        onAddToQueue: model.addToQueue,
                        onSelectTrack: onSelectTrack,
                        onSelectArtist: onSelectArtist,
                        onPlayTrack: playTrack
                    )
                }
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.secondary)
                Button("Try Again") { Task { await load() } }
                    .disabled(isLoading)
            }
            if isLoading {
                ProgressView("Loading playlist")
                    .frame(maxWidth: .infinity)
            } else if hasLoadedTracks, tracks.isEmpty, errorMessage == nil {
                ContentUnavailableView(
                    displayedPlaylist.trackCount == 0 ? "Empty playlist" : "No playable tracks",
                    systemImage: "music.note.list",
                    description: Text(displayedPlaylist.trackCount == 0
                        ? "This playlist has no tracks."
                        : "This playlist has no tracks available for playback here.")
                )
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

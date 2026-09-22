import SwiftUI

struct PlaylistDetailView: View {
    private let artworkSize: CGFloat = 250

    let playlist: SoundCloudPlaylist
    @ObservedObject var model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    let onDeletePlaylist: (SoundCloudPlaylist) -> Void

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
    @State private var playlistDeletion = PlaylistDeletionState()
    @State private var removeTrackErrorMessage: String?

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
                            .foregroundStyle(Color.accentColor)
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
                        DeletePlaylistButton(playlist: displayedPlaylist, state: $playlistDeletion)
                    } label: {
                        Label("Playlist actions", systemImage: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                    .disabled(playlistDeletion.deletingURNs.contains(playlist.urn))
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

    private var artworkBackdrop: some View {
        TrackCollectionBackdrop(artworkURL: artworkURL, loader: model.artworkLoader)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            playlistArtwork
            VStack(alignment: .leading, spacing: 10) {
                Text("\(Text(Image(systemName: "music.note.list")).foregroundStyle(.primary.opacity(0.7))) \(displayedPlaylist.title)")
                    .font(.system(size: 28, weight: .semibold))
                    .textSelection(.enabled)
                    .accessibilityLabel("Playlist, \(displayedPlaylist.title)")
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
                        Label {
                            Text("Private")
                        } icon: {
                            Image(systemName: "lock.fill")
                                .opacity(0.7)
                        }
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

                NowPlayingTrackRow(
                    track: currentPlaylistTrack,
                    isPlaying: model.playback.isPlaying,
                    isLoading: model.playback.isLoading,
                    analyzer: model.analyzer,
                    onSelectTrack: onSelectTrack,
                    onSelectArtist: onSelectArtist,
                    appearanceDelay: .milliseconds(350)
                )
                .offset(y: 8)

                Spacer(minLength: 6)
                TrackWaveformView(
                    track: currentPlaylistTrack,
                    model: model,
                    invertsBarsOnTrackChange: true,
                    collapsesBarsWhenPaused: true,
                    keepsBarsVisible: true
                )
                .offset(y: -2)
            }
            // Match the track detail header's waveform ground and reflection.
            .frame(
                maxWidth: .infinity,
                minHeight: artworkSize + TrackWaveformView.Layout.detail.reflectionHeight,
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
            cornerRadius: 12,
            onShowArtwork: { isShowingArtwork = true }
        )
    }

    private var playButton: some View {
        let isPlaying = currentPlaylistTrack != nil && model.playback.isPlaybackActive
        return Button {
            if currentPlaylistTrack != nil {
                model.playback.togglePlayPause()
            } else if let track = model.playback.isShuffleEnabled ? tracks.randomElement() : tracks.first {
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
                ProgressView()
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

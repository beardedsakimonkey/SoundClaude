import SwiftUI

struct PlaylistDetailView: View {
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
    @State private var isShowingArtwork = false
    @State private var isHoveringArtwork = false
    @State private var cachedFullSizeArtwork: CachedFullSizeArtwork?
    @State private var likeErrorMessage: String?

    private var displayedPlaylist: SoundCloudPlaylist { contents?.playlist ?? playlist }
    private var currentPlaylistTrack: SoundCloudTrack? {
        guard let track = model.playback.currentTrack,
              model.queue.source == .playlist(playlist.urn)
                || tracks.contains(where: { $0.urn == track.urn }) else { return nil }
        return track
    }

    private var artworkURL: URL? {
        if let track = currentPlaylistTrack {
            return track.artworkURL
        }
        return displayedPlaylist.artworkURL ?? tracks.first(where: { $0.artworkURL != nil })?.artworkURL
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
                    CountedSectionHeader(
                        title: "Tracks",
                        count: displayedPlaylist.trackCount ?? tracks.count
                    )
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
            animatesChanges: true
        )
        .frame(height: 410)

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
                Label(
                    displayedPlaylist.isPrivate ? "Private playlist" : "Playlist",
                    systemImage: displayedPlaylist.isPrivate ? "lock" : "music.note.list"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                Text(displayedPlaylist.title)
                    .font(.system(size: 28, weight: .semibold))
                    .textSelection(.enabled)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ArtistLink(
                        artist: displayedPlaylist.owner,
                        artworkLoader: model.artworkLoader,
                        onSelect: onSelectArtist
                    )

                    RelativeTimestampView(
                        timestamp: displayedPlaylist.lastModified,
                        accessibilityPrefix: "Last updated"
                    )
                }
                .font(.title3)
                .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        playButton
                        if !displayedPlaylist.isPrivate { likeButton }
                    }
                    if !displayedPlaylist.isPrivate, let error = playlists.likesErrorMessage {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                        Button("Retry likes") { Task { await playlists.loadLikes() } }
                    }
                    if let track = currentPlaylistTrack {
                        TrackWaveformView(
                            track: track,
                            model: model,
                            collapsesBarsWhenPaused: true
                        )
                    }
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var playlistArtwork: some View {
        let thumbnail = TrackArtworkView(
            artworkURL: artworkURL,
            loader: model.artworkLoader,
            size: 250,
            rendition: .square500,
            shape: RoundedRectangle(cornerRadius: 6),
            animatesChanges: true
        )
        return Button {
            isShowingArtwork = true
        } label: {
            thumbnail.artworkExpandIndicator(isHovering: isHoveringArtwork && artworkURL != nil)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(artworkURL == nil)
        .onContentHover { isHoveringArtwork = $0 }
        .help("View full-size artwork")
        .accessibilityLabel("View full-size artwork for \(artworkTitle)")
        .accessibilityHidden(artworkURL == nil)
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
        .modifier(SpringPressEffect())
        .disabled(currentPlaylistTrack == nil && tracks.isEmpty)
        .help(isPlaying ? "Pause playlist" : "Play playlist")
        .accessibilityLabel(isPlaying ? "Pause playlist" : "Play playlist")
    }

    private var likeButton: some View {
        let isLiked = playlists.likedPlaylistURNs.contains(playlist.urn)
        return Button {
            Task {
                do {
                    try await playlists.toggleLike(displayedPlaylist)
                } catch {
                    likeErrorMessage = error.localizedDescription
                }
            }
        } label: {
            ZStack {
                Label("Like", systemImage: "heart")
                    .opacity(isLiked ? 0 : 1)
                    .accessibilityHidden(isLiked)
                Label("Unlike", systemImage: "heart.fill")
                    .foregroundStyle(.orange)
                    .opacity(isLiked ? 1 : 0)
                    .accessibilityHidden(!isLiked)
            }
            .labelStyle(.titleAndIcon)
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 24)
            .frame(minHeight: 24)
        }
        .buttonStyle(TrackActionButtonStyle(
            fill: isLiked ? .accentColor.opacity(0.12) : .primary.opacity(0.12)
        ))
        .modifier(SpringPressEffect())
        .disabled(!playlists.hasLoadedLikes || playlists.updatingLikeURNs.contains(playlist.urn))
        .help(isLiked ? "Unlike playlist" : "Like playlist")
        .accessibilityLabel(isLiked ? "Unlike playlist" : "Like playlist")
        .accessibilityValue(isLiked ? "Liked" : "Not liked")
    }

    private var trackList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(tracks) { track in
                TrackListRow(
                    track: track,
                    playback: model.playback,
                    artworkLoader: model.artworkLoader,
                    likes: model.likes,
                    onSelectTrack: onSelectTrack,
                    onSelectArtist: onSelectArtist,
                    onPlayTrack: { selected in
                        await model.play(selected, queue: TrackQueue(
                            source: .playlist(playlist.urn),
                            tracks: tracks,
                            nextPageURL: nextPageURL
                        ))
                    }
                )
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

    private func load() async {
        await playlists.loadPlaylist(playlist)
    }
}

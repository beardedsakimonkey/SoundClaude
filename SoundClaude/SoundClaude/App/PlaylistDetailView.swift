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

    private var displayedPlaylist: SoundCloudPlaylist { contents?.playlist ?? playlist }
    private var artworkURL: URL? {
        displayedPlaylist.artworkURL ?? tracks.first(where: { $0.artworkURL != nil })?.artworkURL
    }

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
        .task(id: playlist.urn) {
            await load()
        }
        .sheet(isPresented: $isShowingArtwork) {
            FullSizeArtworkView(
                title: displayedPlaylist.title,
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
            loader: model.artworkLoader
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
                    .font(.system(size: 36, weight: .semibold))
                    .textSelection(.enabled)
                ArtistLink(
                    artist: displayedPlaylist.owner,
                    artworkLoader: model.artworkLoader,
                    onSelect: onSelectArtist
                )
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Link(destination: displayedPlaylist.permalinkURL) {
                    Label("Open in SoundCloud", systemImage: "arrow.up.right.square")
                }
                .help("Open this playlist in your web browser")
            }
        }
    }

    @ViewBuilder
    private var playlistArtwork: some View {
        let thumbnail = TrackArtworkView(
            artworkURL: artworkURL,
            loader: model.artworkLoader,
            size: 250,
            rendition: .square500
        )
        if artworkURL != nil {
            Button {
                isShowingArtwork = true
            } label: {
                thumbnail.artworkExpandIndicator(isHovering: isHoveringArtwork)
            }
            .buttonStyle(.plain)
            .onContentHover { isHoveringArtwork = $0 }
            .help("View full-size playlist artwork")
            .accessibilityLabel("View full-size artwork for \(displayedPlaylist.title)")
        } else {
            thumbnail
        }
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

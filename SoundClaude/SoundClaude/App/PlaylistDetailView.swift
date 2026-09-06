import SwiftUI

struct PlaylistDetailView: View {
    let playlist: SoundCloudPlaylist
    @ObservedObject var model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void

    @State private var details: SoundCloudPlaylist?
    @State private var tracks: [SoundCloudTrack] = []
    @State private var nextPageURL: URL?
    @State private var loadedPageURLs: Set<URL> = []
    @State private var hasLoadedTracks = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isShowingArtwork = false
    @State private var isHoveringArtwork = false
    @State private var cachedFullSizeArtwork: CachedFullSizeArtwork?

    private var displayedPlaylist: SoundCloudPlaylist { details ?? playlist }
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
                    Divider()
                    Text("Tracks").font(.headline)
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
            if !hasLoadedTracks { await load() }
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
        .frame(height: 340)

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
                ArtistLink(artist: displayedPlaylist.owner, onSelect: onSelectArtist)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    if let count = displayedPlaylist.trackCount {
                        Text("\(count.formatted()) \(count == 1 ? "track" : "tracks")")
                    }
                    if let duration = displayedPlaylist.durationMilliseconds, duration > 0 {
                        Text(Duration.milliseconds(duration).formatted(.units(
                            allowed: [.hours, .minutes], width: .abbreviated
                        )))
                    }
                }
                .font(.callout)
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
            size: 180,
            rendition: .square500
        )
        if artworkURL != nil {
            Button {
                isShowingArtwork = true
            } label: {
                thumbnail.artworkExpandIndicator(isHovering: isHoveringArtwork)
            }
            .buttonStyle(.plain)
            .onHover { isHoveringArtwork = $0 }
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
            if isLoading || (nextPageURL != nil && errorMessage == nil) {
                ProgressView("Loading playlist")
                    .frame(maxWidth: .infinity)
                    .task(id: nextPageURL) {
                        guard nextPageURL != nil, errorMessage == nil else { return }
                        await load()
                    }
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
        guard !isLoading, !hasLoadedTracks || nextPageURL != nil else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            if details == nil {
                let loaded = try await model.playlistDetails(for: playlist)
                try Task.checkCancellation()
                details = loaded
            }
            let pageURL = nextPageURL
            let page = try await model.playlistTracks(for: displayedPlaylist, pageURL: pageURL)
            try Task.checkCancellation()
            if let nextURL = page.nextURL,
               nextURL == pageURL || loadedPageURLs.contains(nextURL) {
                throw SoundCloudError.invalidData
            }
            var knownURNs = Set(tracks.map(\.urn))
            tracks.append(contentsOf: page.tracks.filter { knownURNs.insert($0.urn).inserted })
            if let pageURL { loadedPageURLs.insert(pageURL) }
            nextPageURL = page.nextURL
            hasLoadedTracks = true
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}

import SwiftUI

/// Every track related to a track, opened from "View all" on the track's page.
struct RelatedTracksView: View {
    let track: SoundCloudTrack
    let model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void

    @State private var tracks: [SoundCloudTrack]
    @State private var pages: TrackListPages
    @AppStorage("relatedTracksTrackLayout") private var trackLayout = TrackLayout.list

    init(
        track: SoundCloudTrack,
        model: AppModel,
        onSelectTrack: @escaping (SoundCloudTrack) -> Void,
        onSelectArtist: @escaping (SoundCloudUser) -> Void
    ) {
        self.track = track
        self.model = model
        self.onSelectTrack = onSelectTrack
        self.onSelectArtist = onSelectArtist

        // The track's page has usually fetched the first page already.
        let cached = model.cachedRelatedTracks(for: track)
        var knownURNs: Set = [track.urn]
        _tracks = State(initialValue: cached?.tracks.filter { knownURNs.insert($0.urn).inserted } ?? [])
        _pages = State(initialValue: TrackListPages(firstPageNextURL: cached.map(\.nextURL)))
    }

    var body: some View {
        TrackListPage(
            title: "Tracks related to", track: track,
            artworkLoader: model.artworkLoader, onSelectTrack: onSelectTrack,
            pages: pages, isEmpty: tracks.isEmpty, subject: "related tracks",
            trackLayout: $trackLayout, loadPage: loadPage
        ) {
            if trackLayout == .grid {
                TrackArtworkGrid(tracks: tracks, loader: model.artworkLoader) { relatedTrack in
                    TrackGridTile(
                        track: relatedTrack,
                        playback: model.playback,
                        analyzer: model.analyzer,
                        artworkLoader: model.artworkLoader,
                        likes: model.likes,
                        onAddToQueue: model.addToQueue,
                        onSelectTrack: onSelectTrack,
                        onSelectArtist: onSelectArtist,
                        onPlayTrack: play
                    )
                    .modifier(FadeInOnAppear())
                }
            } else {
                TrackArtworkList(tracks: tracks, loader: model.artworkLoader) { relatedTrack in
                    TrackListRow(
                        track: relatedTrack,
                        playback: model.playback,
                        analyzer: model.analyzer,
                        artworkLoader: model.artworkLoader,
                        likes: model.likes,
                        onAddToQueue: model.addToQueue,
                        onSelectTrack: onSelectTrack,
                        onSelectArtist: onSelectArtist,
                        onPlayTrack: play
                    )
                    .modifier(FadeInOnAppear())
                }
            }
        }
        .navigationTitle("Tracks related to \(track.title)")
    }

    private func play(_ selected: SoundCloudTrack) async {
        await model.play(selected, queue: TrackQueue(
            source: .related(track.urn),
            tracks: tracks,
            nextPageURL: pages.nextPageURL,
            sourceTrack: track
        ))
    }

    private func loadPage() async {
        await pages.load { pageURL in
            let page = try await model.relatedTracks(for: track, pageURL: pageURL)
            return (page.nextURL, {
                var knownURNs = Set(tracks.map(\.urn))
                knownURNs.insert(track.urn)
                tracks.append(contentsOf: page.tracks.filter { knownURNs.insert($0.urn).inserted })
            })
        }
    }
}

/// Every public playlist that includes a track, opened from "View all" on the track's page.
struct TrackPlaylistsView: View {
    let track: SoundCloudTrack
    let model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    let onSelectPlaylist: (SoundCloudPlaylist) -> Void

    @State private var playlists: [SoundCloudPlaylist]
    @State private var pages: TrackListPages

    init(
        track: SoundCloudTrack,
        model: AppModel,
        onSelectTrack: @escaping (SoundCloudTrack) -> Void,
        onSelectArtist: @escaping (SoundCloudUser) -> Void,
        onSelectPlaylist: @escaping (SoundCloudPlaylist) -> Void
    ) {
        self.track = track
        self.model = model
        self.onSelectTrack = onSelectTrack
        self.onSelectArtist = onSelectArtist
        self.onSelectPlaylist = onSelectPlaylist

        let cached = model.cachedPlaylistsContaining(track)
        var knownURNs = Set<String>()
        _playlists = State(initialValue: cached?.playlists.filter { knownURNs.insert($0.urn).inserted } ?? [])
        _pages = State(initialValue: TrackListPages(firstPageNextURL: cached.map(\.nextURL)))
    }

    var body: some View {
        TrackListPage(
            title: "Playlists with", track: track,
            artworkLoader: model.artworkLoader, onSelectTrack: onSelectTrack,
            pages: pages, isEmpty: playlists.isEmpty, subject: "playlists",
            loadPage: loadPage
        ) {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(playlists) { playlist in
                    PlaylistCardView(
                        playlist: playlist,
                        model: model,
                        playlists: model.playlists,
                        onSelectPlaylist: onSelectPlaylist,
                        onSelectTrack: onSelectTrack,
                        onSelectArtist: onSelectArtist
                    )
                    .modifier(FadeInOnAppear())
                }
            }
        }
        .navigationTitle("Playlists with \(track.title)")
    }

    private func loadPage() async {
        await pages.load { pageURL in
            let page = try await model.playlistsContaining(track, pageURL: pageURL)
            return (page.nextURL, {
                var knownURNs = Set(playlists.map(\.urn))
                playlists.append(contentsOf: page.playlists.filter { knownURNs.insert($0.urn).inserted })
            })
        }
    }
}

/// Paging state shared by the two lists.
@MainActor @Observable
private final class TrackListPages {
    var nextPageURL: URL?
    var loadedPageURLs: Set<URL> = []
    var hasLoaded: Bool
    var isLoading = false
    var errorMessage: String?

    /// Pass the cached first page's next URL to start after that page.
    init(firstPageNextURL: URL?? = nil) {
        hasLoaded = firstPageNextURL != nil
        nextPageURL = firstPageNextURL ?? nil
    }

    /// `fetch` returns the next page's URL and a closure that appends the page's items.
    func load(
        _ fetch: (URL?) async throws -> (nextURL: URL?, append: () -> Void)
    ) async {
        guard !isLoading, !hasLoaded || nextPageURL != nil else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let pageURL = nextPageURL
            let page = try await fetch(pageURL)
            try Task.checkCancellation()
            if let nextURL = page.nextURL,
               nextURL == pageURL || loadedPageURLs.contains(nextURL) {
                throw SoundCloudError.invalidData
            }
            page.append()
            if let pageURL { loadedPageURLs.insert(pageURL) }
            nextPageURL = page.nextURL
            hasLoaded = true
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}

private struct TrackListPage<Content: View>: View {
    let title: String
    let track: SoundCloudTrack
    let artworkLoader: ArtworkLoader
    let onSelectTrack: (SoundCloudTrack) -> Void
    let pages: TrackListPages
    let isEmpty: Bool
    let subject: String
    /// Shows the grid and list buttons when the list holds tracks.
    var trackLayout: Binding<TrackLayout>? = nil
    let loadPage: () async -> Void
    @ViewBuilder let content: Content

    @State private var isHoveringTitle = false

    var body: some View {
        ScrollbarReservedScrollView { _ in
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 8) {
                    // A long track title truncates before this does.
                    Text(title)
                        .layoutPriority(1)
                    Button {
                        onSelectTrack(track)
                    } label: {
                        HStack(spacing: 8) {
                            TrackArtworkView(
                                artworkURL: track.displayArtworkURL,
                                loader: artworkLoader,
                                size: 28,
                                shape: RoundedRectangle(cornerRadius: TrackListRow.artworkCornerRadius)
                            )
                            Text(track.title)
                                .fontWeight(.semibold)
                                .underline(isHoveringTitle)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .prefetch(.track(track)) { isHoveringTitle = $0 }
                    .contentHelp("View track")

                    if let trackLayout {
                        Spacer()
                        TrackLayoutPicker(trackLayout: trackLayout)
                            .font(.body)
                    }
                }
                .font(.title2)
                .lineLimit(1)

                LazyVStack(alignment: .leading, spacing: 16) {
                    content

                    if let errorMessage = pages.errorMessage {
                        VStack(spacing: 8) {
                            Text(errorMessage).foregroundStyle(.secondary)
                            Button("Try Again") { Task { await loadPage() } }
                                .disabled(pages.isLoading)
                        }
                        .frame(maxWidth: .infinity)
                    } else if !pages.hasLoaded || pages.nextPageURL != nil {
                        LoadingSpinner()
                            .accessibilityLabel("Loading \(subject)")
                            .frame(maxWidth: .infinity)
                            .task { await loadPage() }
                            // A new spinner per page, so an empty page moves on to the next.
                            .id(pages.nextPageURL)
                    } else if isEmpty {
                        EmptyStateView("No \(subject)")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            .remembersScrollPosition()
        }
        .preference(
            key: DetailBackdropPreferenceKey.self,
            value: .track(artworkURL: track.displayArtworkURL)
        )
    }
}

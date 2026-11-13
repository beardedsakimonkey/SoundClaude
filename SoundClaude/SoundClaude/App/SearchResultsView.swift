import SwiftUI

/// Results for a query. Without a category it shows the best matches of every kind;
/// with one, or for a genre or tag, it lists every match of that kind.
struct SearchResultsView: View {
    let query: String
    var category: SearchCategory? = nil
    var isGenreSearch = false
    var isTagSearch = false
    var contentPadding: CGFloat = 20
    let model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectPlaylist: (SoundCloudPlaylist) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    /// Opens every match of one kind, from a section of the overview.
    var onSelectCategory: (SearchCategory) -> Void = { _ in }

    @Environment(\.searchViewportHeight) private var searchViewportHeight

    private var listedCategory: SearchCategory? {
        isGenreSearch || isTagSearch ? .tracks : category
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // The toolbar's search field already shows the query.
            if isTagSearch || isGenreSearch {
                let title = isTagSearch ? "Tracks tagged" : "Tracks in"
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    PillLabel(text: query, size: .large)
                        .fixedSize()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(title) \(query)")
                .modifier(FadeInOnAppear())
            } else if let category {
                Text(category.rawValue)
                    .font(.title2.weight(.semibold))
                    .modifier(FadeInOnAppear())
            }

            Group {
                if let listedCategory {
                    SearchResultList(
                        query: query, isGenreSearch: isGenreSearch, isTagSearch: isTagSearch,
                        category: listedCategory,
                        model: model,
                        onSelectTrack: onSelectTrack,
                        onSelectPlaylist: onSelectPlaylist,
                        onSelectArtist: onSelectArtist
                    )
                } else {
                    SearchOverview(
                        query: query,
                        model: model,
                        onSelectTrack: onSelectTrack,
                        onSelectPlaylist: onSelectPlaylist,
                        onSelectArtist: onSelectArtist,
                        onSelectCategory: onSelectCategory
                    )
                }
            }
            // Keep enough scroll space while results load or are short.
            .frame(minHeight: searchViewportHeight, alignment: .topLeading)
        }
        .padding(contentPadding)
        .navigationTitle(isGenreSearch || isTagSearch ? "Search" : query)
        #if DEBUG
        .debugViewUpdates("SearchResultsView")
        #endif
    }
}

private struct SearchResultList: View {
    let query: String
    let isGenreSearch: Bool
    let isTagSearch: Bool
    let category: SearchCategory
    let model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectPlaylist: (SoundCloudPlaylist) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void

    @State private var tracks: [SoundCloudTrack] = []
    @State private var playlists: [SoundCloudPlaylist] = []
    @State private var users: [SoundCloudUser] = []
    @State private var results: [SoundCloudSearchResult] = []
    @State private var nextPageURL: URL?
    @State private var loadedPageURLs: Set<URL> = []
    @State private var hasLoaded = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    /// nil until a page is requested after the first, which loads on appear.
    @State private var requestID: UUID?

    init(
        query: String,
        isGenreSearch: Bool,
        isTagSearch: Bool,
        category: SearchCategory,
        model: AppModel,
        onSelectTrack: @escaping (SoundCloudTrack) -> Void,
        onSelectPlaylist: @escaping (SoundCloudPlaylist) -> Void,
        onSelectArtist: @escaping (SoundCloudUser) -> Void
    ) {
        self.query = query
        self.isGenreSearch = isGenreSearch
        self.isTagSearch = isTagSearch
        self.category = category
        self.model = model
        self.onSelectTrack = onSelectTrack
        self.onSelectPlaylist = onSelectPlaylist
        self.onSelectArtist = onSelectArtist
        // Show a revisited or prefetched first page without waiting a frame for loadPage().
        let nextURL: URL?
        switch category {
        case .top:
            guard let page = model.cachedFirstSearchResultPage(query: query) else { return }
            var known = Set<String>()
            _results = State(initialValue: page.results.filter { known.insert($0.id).inserted })
            nextURL = page.nextURL
        case .tracks:
            let search = Self.trackSearch(query: query, isGenreSearch: isGenreSearch, isTagSearch: isTagSearch)
            guard let page = model.cachedFirstSearchTrackPage(
                query: search.query, genres: search.genres, tags: search.tags
            ) else { return }
            var known = Set<String>()
            _tracks = State(initialValue: page.tracks.filter { known.insert($0.urn).inserted })
            nextURL = page.nextURL
        case .playlists, .albums:
            guard let page = category == .albums
                ? model.cachedFirstSearchAlbumPage(query: query)
                : model.cachedFirstSearchPlaylistPage(query: query) else { return }
            var known = Set<String>()
            _playlists = State(initialValue: page.playlists.filter { known.insert($0.urn).inserted })
            nextURL = page.nextURL
        case .users:
            guard let page = model.cachedFirstSearchUserPage(query: query) else { return }
            var known = Set<URL>()
            _users = State(initialValue: page.users.filter { known.insert($0.permalinkURL).inserted })
            nextURL = page.nextURL
        }
        _nextPageURL = State(initialValue: nextURL)
        _hasLoaded = State(initialValue: true)
    }

    private static func trackSearch(query: String, isGenreSearch: Bool, isTagSearch: Bool)
        -> (query: String?, genres: String?, tags: String?) {
        (
            query: isGenreSearch || isTagSearch ? nil : query,
            genres: isGenreSearch ? query : nil,
            tags: isTagSearch ? query : nil
        )
    }

    private var isEmpty: Bool { tracks.isEmpty && playlists.isEmpty && users.isEmpty && results.isEmpty }
    /// Whether the results are in a grid whose last cell loads the next page. Its parent
    /// is eager, so a footer spinner would appear, and page, right away.
    private var pagesFromLastCell: Bool {
        category == .users ? !users.isEmpty : category == .top && !results.isEmpty
    }

    var body: some View {
        Group {
            if category == .top {
                VStack(alignment: .leading, spacing: 20) {
                    if !results.isEmpty {
                        LazyVGrid(columns: SearchTopResultCard.gridColumns, spacing: SearchTopResultCard.gridSpacing) {
                            ForEach(results) { result in
                                let nextPage = results.last?.id == result.id ? nextPageURL : nil
                                SearchTopResultCard(
                                    result: result,
                                    model: model,
                                    onSelectTrack: onSelectTrack,
                                    onSelectPlaylist: onSelectPlaylist,
                                    onSelectArtist: onSelectArtist
                                )
                                // Keyed by URL so that a page of only duplicates still loads the next one.
                                .task(id: nextPage) {
                                    if nextPage != nil, !isLoading, errorMessage == nil { requestID = UUID() }
                                }
                            }
                        }
                    }
                    footer
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if category == .users {
                VStack(alignment: .leading, spacing: 20) {
                    if !users.isEmpty {
                        UserGridView(
                            users: users,
                            artworkLoader: model.artworkLoader,
                            onSelectArtist: onSelectArtist,
                            nextPageURL: nextPageURL,
                            onReachEnd: {
                                if !isLoading, errorMessage == nil { requestID = UUID() }
                            }
                        )
                    }
                    footer
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if category == .tracks {
                        ForEach(tracks) { track in
                            TrackCardView(
                                track: track, model: model,
                                onSelectTrack: onSelectTrack,
                                onSelectArtist: onSelectArtist,
                                onPlayTrack: { track in
                                    await model.play(track, queue: TrackQueue(
                                        source: isTagSearch ? .tag(query) : isGenreSearch ? .genre(query) : .search(query),
                                        tracks: tracks, nextPageURL: nextPageURL
                                    ))
                                }
                            )
                        }
                    } else {
                        ForEach(playlists) { playlist in
                            PlaylistCardView(
                                playlist: playlist, model: model,
                                playlists: model.playlists,
                                onSelectPlaylist: onSelectPlaylist,
                                onSelectTrack: onSelectTrack,
                                onSelectArtist: onSelectArtist
                            )
                        }
                    }
                    footer
                }
            }
        }
        .padding(.bottom, 20)
        .task(id: requestID) {
            // A seeded first page waits for the list's end before loading the next.
            guard requestID != nil || !hasLoaded else { return }
            await loadPage()
        }
    }

    private var footer: some View {
        Group {
            if isLoading || (!hasLoaded && errorMessage == nil) {
                LoadingSpinner()
                    .accessibilityLabel("Searching \(category.rawValue.lowercased())")
            } else if let errorMessage {
                VStack(spacing: 8) {
                    Text(errorMessage).foregroundStyle(.secondary)
                    Button("Try Again") { requestID = UUID() }
                }
            } else if nextPageURL != nil {
                LoadingSpinner()
                    .accessibilityLabel("Loading more \(category.rawValue.lowercased())")
                    // Keep the request on the list so replacing this footer
                    // with the loading state does not cancel the request.
                    .onAppear {
                        if !pagesFromLastCell { requestID = UUID() }
                    }
            } else if isEmpty {
                EmptyStateView("No \(category.rawValue.lowercased()) found")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func loadPage() async {
        guard !isLoading, !hasLoaded || nextPageURL != nil else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let pageURL = nextPageURL
        do {
            let nextURL: URL?
            switch category {
            case .top:
                let page = try await model.searchResults(query: query, pageURL: pageURL)
                try Task.checkCancellation()
                try validateNextPage(page.nextURL, requestedURL: pageURL)
                var known = Set(results.map(\.id))
                results.append(contentsOf: page.results.filter { known.insert($0.id).inserted })
                nextURL = page.nextURL
            case .tracks:
                let search = Self.trackSearch(query: query, isGenreSearch: isGenreSearch, isTagSearch: isTagSearch)
                let page = try await model.searchTracks(
                    query: search.query, genres: search.genres, tags: search.tags, pageURL: pageURL
                )
                try Task.checkCancellation()
                try validateNextPage(page.nextURL, requestedURL: pageURL)
                var known = Set(tracks.map(\.urn))
                tracks.append(contentsOf: page.tracks.filter { known.insert($0.urn).inserted })
                nextURL = page.nextURL
            case .playlists, .albums:
                let page = category == .albums
                    ? try await model.searchAlbums(query: query, pageURL: pageURL)
                    : try await model.searchPlaylists(query: query, pageURL: pageURL)
                try Task.checkCancellation()
                try validateNextPage(page.nextURL, requestedURL: pageURL)
                var known = Set(playlists.map(\.urn))
                playlists.append(contentsOf: page.playlists.filter { known.insert($0.urn).inserted })
                nextURL = page.nextURL
            case .users:
                let page = try await model.searchUsers(query: query, pageURL: pageURL)
                try Task.checkCancellation()
                try validateNextPage(page.nextURL, requestedURL: pageURL)
                var known = Set(users.map(\.permalinkURL))
                users.append(contentsOf: page.users.filter { known.insert($0.permalinkURL).inserted })
                nextURL = page.nextURL
            }
            if let pageURL { loadedPageURLs.insert(pageURL) }
            nextPageURL = nextURL
            hasLoaded = true
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func validateNextPage(_ nextURL: URL?, requestedURL: URL?) throws {
        if let nextURL, nextURL == requestedURL || loadedPageURLs.contains(nextURL) {
            throw SoundCloudError.invalidData
        }
    }
}

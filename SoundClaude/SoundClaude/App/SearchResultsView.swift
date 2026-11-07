import Observation
import SwiftUI

struct SearchResultsView: View {
    let query: String
    var isGenreSearch = false
    var isTagSearch = false
    var contentPadding: CGFloat = 20
    let model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectPlaylist: (SoundCloudPlaylist) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    var onSelectCategory: (SearchCategory) -> Void = { _ in }

    @Environment(\.searchViewportHeight) private var searchViewportHeight

    @State private var tabSelection: SearchTabSelection

    init(
        query: String,
        isGenreSearch: Bool = false,
        isTagSearch: Bool = false,
        contentPadding: CGFloat = 20,
        model: AppModel,
        onSelectTrack: @escaping (SoundCloudTrack) -> Void,
        onSelectPlaylist: @escaping (SoundCloudPlaylist) -> Void,
        onSelectArtist: @escaping (SoundCloudUser) -> Void,
        onSelectCategory: @escaping (SearchCategory) -> Void = { _ in }
    ) {
        self.query = query
        self.isGenreSearch = isGenreSearch
        self.isTagSearch = isTagSearch
        self.contentPadding = contentPadding
        self.model = model
        self.onSelectTrack = onSelectTrack
        self.onSelectPlaylist = onSelectPlaylist
        self.onSelectArtist = onSelectArtist
        self.onSelectCategory = onSelectCategory
        let category: SearchCategory = isGenreSearch || isTagSearch ? .tracks : model.searchCategory(for: query)
        _tabSelection = State(initialValue: SearchTabSelection(category: category))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Group {
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
                } else {
                    Text("Results for “\(query)”")
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                }
            }
            .modifier(FadeInOnAppear())
            if !isGenreSearch && !isTagSearch {
                SearchTabs(query: query, selection: tabSelection) { category in
                    model.rememberSearchCategory(category, for: query)
                    onSelectCategory(category)
                }
                .modifier(FadeInOnAppear())
            }

            SearchTabContent(selection: tabSelection) { category, isActive in
                SearchResultList(
                    query: query, isGenreSearch: isGenreSearch, isTagSearch: isTagSearch,
                    category: category, isActive: isActive,
                    model: model,
                    onSelectTrack: onSelectTrack,
                    onSelectPlaylist: onSelectPlaylist,
                    onSelectArtist: onSelectArtist
                )
            }
            // Keep enough scroll space below the tabs while results load or are short.
            .frame(minHeight: searchViewportHeight, alignment: .topLeading)
        }
        .padding(contentPadding)
        .navigationTitle(isGenreSearch || isTagSearch ? "Search" : query)
        #if DEBUG
        .debugViewUpdates("SearchResultsView")
        #endif
    }
}

// Keep tab changes local to the picker and results, without updating the page.
@Observable
private final class SearchTabSelection {
    var category: SearchCategory
    var visitedCategories: Set<SearchCategory>

    init(category: SearchCategory) {
        self.category = category
        visitedCategories = [category]
    }
}

private struct SearchTabs: View {
    let query: String
    let selection: SearchTabSelection
    let onSelect: (SearchCategory) -> Void

    var body: some View {
        TabPicker(
            title: "Search type",
            options: SearchCategory.allCases,
            selection: Binding(
                get: { selection.category },
                set: {
                    selection.visitedCategories.insert($0)
                    selection.category = $0
                    onSelect($0)
                }
            ),
            optionSystemImage: { $0.systemImage },
            prefetch: { [query] in .searchTab(query, $0) }
        )
    }
}

private struct SearchTabContent<Content: View>: View {
    let selection: SearchTabSelection
    @ViewBuilder let content: (SearchCategory, Bool) -> Content

    var body: some View {
        // Keep visited lists mounted to retain results and pagination.
        ZStack(alignment: .topLeading) {
            ForEach(SearchCategory.allCases, id: \.self) { category in
                if selection.visitedCategories.contains(category) {
                    content(category, selection.category == category)
                }
            }
        }
        #if DEBUG
        .debugViewUpdates("SearchTabContent")
        #endif
    }
}

private struct SearchResultList: View {
    let query: String
    let isGenreSearch: Bool
    let isTagSearch: Bool
    let category: SearchCategory
    let isActive: Bool
    let model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectPlaylist: (SoundCloudPlaylist) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void

    @State private var tracks: [SoundCloudTrack] = []
    @State private var playlists: [SoundCloudPlaylist] = []
    @State private var users: [SoundCloudUser] = []
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
        isActive: Bool,
        model: AppModel,
        onSelectTrack: @escaping (SoundCloudTrack) -> Void,
        onSelectPlaylist: @escaping (SoundCloudPlaylist) -> Void,
        onSelectArtist: @escaping (SoundCloudUser) -> Void
    ) {
        self.query = query
        self.isGenreSearch = isGenreSearch
        self.isTagSearch = isTagSearch
        self.category = category
        self.isActive = isActive
        self.model = model
        self.onSelectTrack = onSelectTrack
        self.onSelectPlaylist = onSelectPlaylist
        self.onSelectArtist = onSelectArtist
        // Show a revisited or prefetched first page without waiting a frame for loadPage().
        let nextURL: URL?
        switch category {
        case .tracks:
            let search = Self.trackSearch(query: query, isGenreSearch: isGenreSearch, isTagSearch: isTagSearch)
            guard let page = model.cachedFirstSearchTrackPage(
                query: search.query, genres: search.genres, tags: search.tags
            ) else { return }
            var known = Set<String>()
            _tracks = State(initialValue: page.tracks.filter { known.insert($0.urn).inserted })
            nextURL = page.nextURL
        case .playlists:
            guard let page = model.cachedFirstSearchPlaylistPage(query: query) else { return }
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

    private var isEmpty: Bool { tracks.isEmpty && playlists.isEmpty && users.isEmpty }

    var body: some View {
        Group {
            if isActive {
                Group {
                    if category == .users {
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
            }
        }
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
                        // The user grid's parent is eager, so its last card pages instead.
                        if category != .users || users.isEmpty { requestID = UUID() }
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
            case .playlists:
                let page = try await model.searchPlaylists(query: query, pageURL: pageURL)
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

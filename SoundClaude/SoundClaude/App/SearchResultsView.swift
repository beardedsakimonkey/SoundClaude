import SwiftUI

struct SearchResultsView: View {
    let query: String
    var isGenreSearch = false
    var isTagSearch = false
    var contentPadding: CGFloat = 20
    @ObservedObject var model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectPlaylist: (SoundCloudPlaylist) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void

    @Environment(\.searchViewportHeight) private var searchViewportHeight

    @State private var category: SearchCategory = .tracks
    @State private var visitedCategories: Set<SearchCategory> = [.tracks]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isTagSearch ? "Tracks tagged “\(query)”" : isGenreSearch ? "Tracks in “\(query)”" : "Results for “\(query)”")
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
            if !isGenreSearch && !isTagSearch {
                TabPicker(
                    title: "Search type",
                    options: SearchCategory.allCases,
                    selection: Binding(
                        get: { category },
                        set: {
                            visitedCategories.insert($0)
                            category = $0
                        }
                    ),
                    optionSystemImage: { $0.systemImage }
                )
            }

            // Keep visited lists mounted to retain results and pagination.
            ZStack(alignment: .topLeading) {
                ForEach(SearchCategory.allCases, id: \.self) { resultCategory in
                    if visitedCategories.contains(resultCategory) {
                        SearchResultList(
                            query: query, isGenreSearch: isGenreSearch, isTagSearch: isTagSearch,
                            category: resultCategory, isActive: category == resultCategory,
                            model: model,
                            onSelectTrack: onSelectTrack,
                            onSelectPlaylist: onSelectPlaylist,
                            onSelectArtist: onSelectArtist
                        )
                    }
                }
            }
            // Keep enough scroll space below the tabs while results load or are short.
            .frame(minHeight: searchViewportHeight, alignment: .topLeading)
        }
        .padding(contentPadding)
        .navigationTitle("Search")
    }
}

private enum SearchCategory: String, CaseIterable {
    case tracks = "Tracks"
    case playlists = "Playlists"
    case users = "Users"

    var systemImage: String {
        switch self {
        case .tracks: "music.note"
        case .playlists: "music.note.list"
        case .users: "person"
        }
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
    @State private var requestID = UUID()

    private var isEmpty: Bool { tracks.isEmpty && playlists.isEmpty && users.isEmpty }

    var body: some View {
        Group {
            if isActive {
                LazyVStack(alignment: .leading, spacing: 20) {
                    switch category {
                    case .tracks:
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
                    case .playlists:
                        ForEach(playlists) { playlist in
                            PlaylistCardView(
                                playlist: playlist, model: model,
                                playlists: model.playlists,
                                onSelectPlaylist: onSelectPlaylist,
                                onSelectTrack: onSelectTrack,
                                onSelectArtist: onSelectArtist
                            )
                        }
                    case .users:
                        UserGridView(
                            users: users,
                            artworkLoader: model.artworkLoader,
                            showsAvatarGlass: true,
                            onSelectArtist: onSelectArtist
                        )
                    }

                    Group {
                        if isLoading || (!hasLoaded && errorMessage == nil) {
                            ProgressView()
                                .accessibilityLabel("Searching \(category.rawValue.lowercased())")
                        } else if let errorMessage {
                            VStack(spacing: 8) {
                                Text(errorMessage).foregroundStyle(.secondary)
                                Button("Try Again") { requestID = UUID() }
                            }
                        } else if nextPageURL != nil {
                            Button("Load More") { requestID = UUID() }
                        } else if isEmpty {
                            EmptyStateView("No \(category.rawValue.lowercased()) found")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.bottom, 20)
            }
        }
        .task(id: requestID) { await loadPage() }
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
                let page = try await model.searchTracks(
                    query: isGenreSearch || isTagSearch ? nil : query,
                    genres: isGenreSearch ? query : nil,
                    tags: isTagSearch ? query : nil,
                    pageURL: pageURL
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

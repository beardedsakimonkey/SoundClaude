import SwiftUI

struct SearchResultsView: View {
    let query: String
    @ObservedObject var model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectPlaylist: (SoundCloudPlaylist) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void

    @State private var category: SearchCategory = .tracks

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Search results for “\(query)”")
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
            Picker("Search type", selection: $category) {
                ForEach(SearchCategory.allCases, id: \.self) { category in
                    Text(category.rawValue).tag(category)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)

            SearchResultList(
                query: query, category: category, model: model,
                onSelectTrack: onSelectTrack,
                onSelectPlaylist: onSelectPlaylist,
                onSelectArtist: onSelectArtist
            )
            // A new type owns new state and cancels the previous request.
            .id(category)
        }
        .padding(20)
        .navigationTitle("Search")
    }
}

private enum SearchCategory: String, CaseIterable {
    case tracks = "Tracks"
    case playlists = "Playlists"
    case users = "Users"
}

private struct SearchResultList: View {
    let query: String
    let category: SearchCategory
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
        ScrollView {
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
                                    source: .search(query), tracks: tracks, nextPageURL: nextPageURL
                                ))
                            }
                        )
                    }
                case .playlists:
                    ForEach(playlists) { playlist in
                        HStack(spacing: 16) {
                            Button { onSelectPlaylist(playlist) } label: {
                                TrackArtworkView(
                                    artworkURL: playlist.artworkURL,
                                    loader: model.artworkLoader, size: 80
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open playlist: \(playlist.title)")
                            VStack(alignment: .leading, spacing: 6) {
                                Button(playlist.title) { onSelectPlaylist(playlist) }
                                    .buttonStyle(.plain)
                                    .font(.headline)
                                ArtistLink(artist: playlist.owner, onSelect: onSelectArtist)
                                    .foregroundStyle(.secondary)
                                if let count = playlist.trackCount {
                                    Text("\(count.formatted()) \(count == 1 ? "track" : "tracks")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                case .users:
                    ForEach(users, id: \.permalinkURL) { user in
                        Button { onSelectArtist(user) } label: {
                            HStack(spacing: 16) {
                                TrackArtworkView(
                                    artworkURL: user.avatarURL,
                                    loader: model.artworkLoader, size: 64
                                )
                                .clipShape(Circle())
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(user.username).font(.headline)
                                    if let count = user.followersCount {
                                        Text("\(count.formatted()) \(count == 1 ? "follower" : "followers")")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("View profile: \(user.username)")
                    }
                }

                Group {
                    if isLoading || (!hasLoaded && errorMessage == nil) {
                        ProgressView("Searching \(category.rawValue.lowercased())")
                    } else if let errorMessage {
                        VStack(spacing: 8) {
                            Text(errorMessage).foregroundStyle(.secondary)
                            Button("Try Again") { requestID = UUID() }
                        }
                    } else if nextPageURL != nil {
                        Button("Load More") { requestID = UUID() }
                    } else if isEmpty {
                        ContentUnavailableView(
                            "No \(category.rawValue.lowercased()) found",
                            systemImage: "magnifyingglass",
                            description: Text("Try another search or result type.")
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.bottom, 20)
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
                let page = try await model.searchTracks(query: query, pageURL: pageURL)
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

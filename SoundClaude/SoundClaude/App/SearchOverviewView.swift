import SwiftUI

/// The first matches of every kind for a query, sorted into the sections of its search page.
struct SearchOverviewSections {
    static let topResultCount = 2 * SearchTopResultCard.gridColumns.count
    static let trackCount = 5

    /// The first results of any kind, in ranked order. The sections below list them again.
    let topResults: [SoundCloudSearchResult]
    /// Every track in ranked order. Playback queues these.
    let tracks: [SoundCloudTrack]
    let users: [SoundCloudUser]
    let playlists: [SoundCloudPlaylist]
    let albums: [SoundCloudPlaylist]

    var isEmpty: Bool { topResults.isEmpty }

    init(_ results: [SoundCloudSearchResult]) {
        var known = Set<String>()
        var tracks: [SoundCloudTrack] = []
        var users: [SoundCloudUser] = []
        var playlists: [SoundCloudPlaylist] = []
        var albums: [SoundCloudPlaylist] = []
        let ranked = results.filter { known.insert($0.id).inserted }
        for result in ranked {
            switch result {
            case let .track(track): tracks.append(track)
            case let .user(user): users.append(user)
            case let .playlist(playlist):
                if playlist.isAlbum == true { albums.append(playlist) } else { playlists.append(playlist) }
            }
        }
        topResults = Array(ranked.prefix(Self.topResultCount))
        self.tracks = tracks
        self.users = users
        self.playlists = playlists
        self.albums = albums
    }
}

struct SearchOverview: View {
    let query: String
    let model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectPlaylist: (SoundCloudPlaylist) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    let onSelectCategory: (SearchCategory) -> Void

    @State private var sections: SearchOverviewSections?
    @State private var errorMessage: String?
    @State private var retryID: UUID?

    private static let sectionSpacing: CGFloat = 32

    init(
        query: String,
        model: AppModel,
        onSelectTrack: @escaping (SoundCloudTrack) -> Void,
        onSelectPlaylist: @escaping (SoundCloudPlaylist) -> Void,
        onSelectArtist: @escaping (SoundCloudUser) -> Void,
        onSelectCategory: @escaping (SearchCategory) -> Void
    ) {
        self.query = query
        self.model = model
        self.onSelectTrack = onSelectTrack
        self.onSelectPlaylist = onSelectPlaylist
        self.onSelectArtist = onSelectArtist
        self.onSelectCategory = onSelectCategory
        // Show a revisited or prefetched overview without waiting a frame for load().
        _sections = State(initialValue: model.cachedFirstSearchResultPage(query: query).map {
            SearchOverviewSections($0.results)
        })
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 20)
            .task(id: retryID) {
                if sections == nil { await load() }
            }
        #if DEBUG
            .debugViewUpdates("SearchOverview")
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if let sections {
            if sections.isEmpty {
                EmptyStateView("No results for “\(query)”. Check the spelling or try different keywords.")
                    .frame(maxWidth: .infinity)
            } else {
                VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                    section("Top results", category: .top) {
                        LazyVGrid(
                            columns: SearchTopResultCard.gridColumns, spacing: SearchTopResultCard.gridSpacing
                        ) {
                            ForEach(sections.topResults) { result in
                                SearchTopResultCard(
                                    result: result,
                                    model: model,
                                    onSelectTrack: onSelectTrack,
                                    onSelectPlaylist: onSelectPlaylist,
                                    onSelectArtist: onSelectArtist
                                )
                            }
                        }
                        .modifier(FadeInOnAppear())
                    }
                    if !sections.users.isEmpty {
                        section("Users", category: .users) {
                            SearchShelf {
                                ForEach(sections.users, id: \.permalinkURL) { user in
                                    UserGridCard(
                                        user: user,
                                        artworkLoader: model.artworkLoader,
                                        onSelectArtist: onSelectArtist
                                    )
                                    .frame(width: UserGridCard.minimumWidth)
                                }
                            }
                            // Line the first avatar up with the section's heading.
                            .padding(.leading, -UserGridCard.avatarInset)
                        }
                    }
                    if !sections.tracks.isEmpty {
                        section("Tracks", category: .tracks) {
                            trackRows(Array(sections.tracks.prefix(SearchOverviewSections.trackCount)), in: sections)
                        }
                    }
                    if !sections.albums.isEmpty {
                        playlistSection("Albums", category: .albums, playlists: sections.albums)
                    }
                    if !sections.playlists.isEmpty {
                        playlistSection("Playlists", category: .playlists, playlists: sections.playlists)
                    }
                }
            }
        } else if let errorMessage {
            VStack(spacing: 8) {
                Text(errorMessage).foregroundStyle(.secondary)
                Button("Try Again") { retryID = UUID() }
            }
            .frame(maxWidth: .infinity)
        } else {
            LoadingSpinner()
                .accessibilityLabel("Searching")
                .frame(maxWidth: .infinity)
        }
    }

    private func section<Content: View>(
        _ title: LocalizedStringKey, category: SearchCategory,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SearchSectionHeading(
                title: title,
                help: "View all \(category.rawValue.lowercased())",
                prefetch: .searchCategory(query, category)
            ) {
                onSelectCategory(category)
            }
            .modifier(FadeInOnAppear())
            content()
        }
    }

    private func playlistSection(
        _ title: LocalizedStringKey, category: SearchCategory, playlists: [SoundCloudPlaylist]
    ) -> some View {
        section(title, category: category) {
            SearchShelf {
                ForEach(playlists) { playlist in
                    SearchPlaylistCard(playlist: playlist, artworkLoader: model.artworkLoader) {
                        onSelectPlaylist(playlist)
                    }
                }
            }
            // Line the first cover up with the section's heading.
            .padding(.leading, -SearchPlaylistCard.inset)
        }
    }

    private func trackRows(_ tracks: [SoundCloudTrack], in sections: SearchOverviewSections) -> some View {
        VStack(alignment: .leading, spacing: 0) {
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
                    onPlayTrack: { selected in await play(selected, in: sections) }
                )
                .modifier(FadeInOnAppear())
            }
        }
        // Line the artwork up with the section's heading.
        .padding(.horizontal, -8)
    }

    private func play(_ track: SoundCloudTrack, in sections: SearchOverviewSections) async {
        await model.play(track, queue: TrackQueue(
            source: .search(query), tracks: sections.tracks, nextPageURL: nil
        ))
    }

    private func load() async {
        errorMessage = nil
        do {
            let page = try await model.searchResults(query: query)
            try Task.checkCancellation()
            sections = SearchOverviewSections(page.results)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            errorMessage = error.localizedDescription
        }
    }
}

/// A section's title, which opens every match of the section's kind.
private struct SearchSectionHeading: View {
    let title: LocalizedStringKey
    let help: String
    let prefetch: PrefetchTarget
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.sectionHeading)
                    .opacity(0.96)
                Image(systemName: "chevron.right")
                    .font(.body.weight(.bold))
                    .foregroundStyle(isHovering ? .primary : .secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .prefetch(prefetch) { isHovering = $0 }
        .contentHelp(help)
        .accessibilityLabel(help)
    }
}

/// One row of cards that scrolls sideways when the page is too narrow for all of them.
private struct SearchShelf<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 0) {
                content()
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A match of any kind, as a cell of a grid of top results.
struct SearchTopResultCard: View {
    static let gridSpacing: CGFloat = 12
    /// Equal columns, so a narrow page truncates the titles rather than reflowing the cards.
    static let gridColumns = Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: 3)

    let result: SoundCloudSearchResult
    let model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectPlaylist: (SoundCloudPlaylist) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void

    @State private var isHovering = false

    private static let artworkSize: CGFloat = 48
    private static let padding: CGFloat = 14

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                if case .playlist = result {
                    PlaylistStackArtwork(
                        artworkURL: result.artworkURL,
                        loader: model.artworkLoader,
                        size: Self.artworkSize,
                        cornerRadius: 5
                    )
                } else {
                    TrackArtworkView(
                        artworkURL: result.artworkURL,
                        loader: model.artworkLoader,
                        size: Self.artworkSize,
                        shape: RoundedRectangle(cornerRadius: result.isUser ? Self.artworkSize / 2 : 5)
                    )
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(result.title)
                        if case let .user(user) = result, user.isVerified == true {
                            VerifiedBadge()
                        }
                    }
                    .font(.headline)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: kindSystemImage)
                            .imageScale(.small)
                            .accessibilityHidden(true)
                        Text(subtitle)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(Self.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.primary.opacity(isHovering ? 0.09 : 0.05))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The pointer crosses the card on its way elsewhere.
        .prefetch(prefetchTarget, .pressOnly) { isHovering = $0 }
        .contentHelp(helpTitle)
        .accessibilityLabel("\(helpTitle), \(subtitle)")
    }

    private func open() {
        switch result {
        case let .user(user): onSelectArtist(user)
        case let .track(track): onSelectTrack(track)
        case let .playlist(playlist): onSelectPlaylist(playlist)
        }
    }

    private var kindSystemImage: String {
        switch result {
        case .user: "person.fill"
        case .track: "music.note"
        case let .playlist(playlist): playlist.isAlbum == true ? "square.stack" : "music.note.list"
        }
    }

    private var prefetchTarget: PrefetchTarget {
        switch result {
        case let .user(user): .artist(user)
        case let .track(track): .track(track)
        case let .playlist(playlist): .playlist(playlist)
        }
    }

    private var subtitle: String {
        switch result {
        case let .user(user):
            guard let count = user.followersCount else { return "Artist" }
            return "Artist · \(count.formatted()) \(count == 1 ? "follower" : "followers")"
        case let .track(track):
            return "Track · \(track.uploader)"
        case let .playlist(playlist):
            return "\(playlist.isAlbum == true ? "Album" : "Playlist") · \(playlist.owner.username)"
        }
    }

    private var helpTitle: String {
        switch result {
        case let .user(user): "View profile: \(user.username)"
        case let .track(track): "Open track: \(track.title)"
        case let .playlist(playlist): "Open playlist: \(playlist.title)"
        }
    }
}

/// A playlist or album as a cover with its title and owner below.
private struct SearchPlaylistCard: View {
    let playlist: SoundCloudPlaylist
    let artworkLoader: ArtworkLoader
    let onSelect: () -> Void

    static let artworkSize: CGFloat = 148
    /// The space between the card's edge and its cover.
    static let inset: CGFloat = 10

    @State private var isHovering = false

    private var subtitle: String {
        guard let count = playlist.trackCount else { return playlist.owner.username }
        return "\(playlist.owner.username) · \(count.formatted()) \(count == 1 ? "track" : "tracks")"
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                TrackArtworkView(
                    artworkURL: playlist.artworkURL ?? playlist.owner.avatarURL,
                    loader: artworkLoader,
                    size: Self.artworkSize,
                    rendition: .square500,
                    shape: RoundedRectangle(cornerRadius: 6)
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(playlist.title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
            }
            .frame(width: Self.artworkSize, alignment: .leading)
            .padding(Self.inset)
            .background {
                RoundedRectangle(cornerRadius: 6 + Self.inset)
                    .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The pointer sweeps across cards in the shelf, so only a press prefetches.
        .prefetch(.playlist(playlist), .pressOnly) { isHovering = $0 }
        .contentHelp("Open playlist: \(playlist.title)")
        .accessibilityLabel("Open playlist: \(playlist.title), \(subtitle)")
        .modifier(FadeInOnAppear())
    }
}

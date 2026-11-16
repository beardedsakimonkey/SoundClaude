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
                            SearchShelf(
                                itemWidth: UserGridCard.minimumWidth,
                                artworkCenterY: UserGridCard.avatarInset + UserGridCard.avatarSize / 2
                            ) {
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
            SearchShelf(
                itemWidth: SearchPlaylistCard.width, artworkCenterY: SearchPlaylistCard.artworkCenterY
            ) {
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
/// Arrows over its ends page through the cards that are off to the side.
struct SearchShelf<Content: View>: View {
    /// The width of one card. Paging moves by whole cards so that they stay lined up with the edge.
    let itemWidth: CGFloat
    /// How far below the shelf's top the cards' artwork is centered, which is where the arrows sit.
    let artworkCenterY: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(macOS 15.0, *) {
            PagedSearchShelf(itemWidth: itemWidth, artworkCenterY: artworkCenterY, content: content)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                SearchShelfRow(content: content)
            }
        }
    }
}

private struct SearchShelfRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            content()
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Where a shelf is scrolled to. The arrows observe it, so that scrolling and hovering
/// leave the shelf's cards alone.
@Observable
private final class SearchShelfPaging {
    private(set) var canPageBack = false
    private(set) var canPageForward = false
    var isHovering = false

    @ObservationIgnored private var extent = SearchShelfExtent(offset: 0, viewport: 0, content: 0)

    func update(_ extent: SearchShelfExtent) {
        self.extent = extent
        // Assign only on a change: this runs on every frame of a scroll.
        let back = extent.offset > 0.5
        let forward = extent.offset < extent.maxOffset - 0.5
        if back != canPageBack { canPageBack = back }
        if forward != canPageForward { canPageForward = forward }
    }

    /// The offset one page of whole cards away, with a card's edge at the shelf's edge.
    func offset(paging direction: SearchShelfArrow.Direction, itemWidth: CGFloat) -> CGFloat {
        let page = max(1, (extent.viewport / itemWidth).rounded(.down)) * itemWidth
        let target = extent.offset + (direction == .forward ? page : -page)
        return min(max((target / itemWidth).rounded() * itemWidth, 0), extent.maxOffset)
    }
}

private struct SearchShelfExtent: Equatable {
    let offset: CGFloat
    let viewport: CGFloat
    let content: CGFloat

    var maxOffset: CGFloat { max(content - viewport, 0) }
}

@available(macOS 15.0, *)
private struct PagedSearchShelf<Content: View>: View {
    let itemWidth: CGFloat
    let artworkCenterY: CGFloat
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position = ScrollPosition()
    @State private var paging = SearchShelfPaging()

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            SearchShelfRow(content: content)
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: SearchShelfExtent.self) { geometry in
            SearchShelfExtent(
                offset: geometry.contentOffset.x,
                viewport: geometry.containerSize.width,
                content: geometry.contentSize.width
            )
        } action: { _, extent in
            paging.update(extent)
        }
        .overlay(alignment: .topLeading) { arrow(.back) }
        .overlay(alignment: .topTrailing) { arrow(.forward) }
        .onHover { paging.isHovering = $0 }
    }

    private func arrow(_ direction: SearchShelfArrow.Direction) -> some View {
        SearchShelfArrow(direction: direction, paging: paging) {
            let target = paging.offset(paging: direction, itemWidth: itemWidth)
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.45)) {
                position.scrollTo(x: target)
            }
        }
        .padding(.top, artworkCenterY - SearchShelfArrow.size.height / 2)
        .padding(.horizontal, 6)
    }
}

/// A button over one end of a shelf, shown while the pointer is over the shelf and there
/// are more cards that way.
private struct SearchShelfArrow: View {
    enum Direction {
        case back, forward
    }

    static let size = CGSize(width: 32, height: 64)

    let direction: Direction
    let paging: SearchShelfPaging
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    private var fill: Color {
        if colorScheme == .dark {
            Color(white: isHovering ? 0.42 : 0.32)
        } else {
            Color(white: isHovering ? 0.86 : 0.96)
        }
    }

    private var isVisible: Bool {
        paging.isHovering && (direction == .back ? paging.canPageBack : paging.canPageForward)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: action) {
            Image(systemName: direction == .back ? "chevron.left" : "chevron.right")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: Self.size.width, height: Self.size.height)
                .background {
                    // Nearly opaque, so the arrow reads over a cover of any color.
                    shape.fill(fill.opacity(0.92))
                    shape.strokeBorder(.primary.opacity(0.12), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(direction == .back ? "Scroll back" : "Scroll forward")
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .animation(.easeInOut(duration: 0.35), value: isVisible)
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
    private static let padding: CGFloat = 10

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
                    Text(subtitle)
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
            return "Artist · \(count.formatted(.number.notation(.compactName))) \(count == 1 ? "follower" : "followers")"
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

/// A playlist, album, or station as a cover with its title and owner below.
struct SearchPlaylistCard: View {
    let playlist: SoundCloudPlaylist
    /// Shown in place of the playlist's own title.
    var shortTitle: String? = nil
    /// Shown in place of the owner and track count.
    var summary: String? = nil
    let artworkLoader: ArtworkLoader
    let onSelect: () -> Void

    static let artworkSize: CGFloat = 148
    /// The space between the card's edge and its cover.
    static let inset: CGFloat = 10
    static let width = artworkSize + 2 * inset
    /// How far below the card's top its cover is centered.
    static let artworkCenterY = inset + artworkSize / 2

    @State private var isHovering = false

    private var title: String { shortTitle ?? playlist.title }

    private var subtitle: String {
        if let summary { return summary }
        guard let count = playlist.trackCount else { return playlist.owner.username }
        return "\(playlist.owner.username) · \(count.formatted()) \(count == 1 ? "track" : "tracks")"
    }

    private var help: String { playlist.isStation ? "Open station" : "Open playlist" }

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
                    Text(title)
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
        .prefetch(playlist.isStation ? .station(playlist.urn) : .playlist(playlist), .pressOnly) {
            isHovering = $0
        }
        .contentHelp("\(help): \(title)")
        .accessibilityLabel("\(help): \(title), \(subtitle)")
        .modifier(FadeInOnAppear())
    }
}

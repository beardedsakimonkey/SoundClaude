import SwiftUI

struct SignedInView: View {
    let user: SoundCloudUser

    @ObservedObject private var model: AppModel
    @State private var selectedDestination: SidebarDestination?
    private let selectionStore = SidebarSelectionStore()
    @State private var navigationHistories: [SidebarDestination.ID: NavigationHistory] = [:]
    @State private var playlistTrack: SoundCloudTrack?
    @State private var searchText = ""
    @State private var likesSearchText = ""
    @State private var searchFocusRequest = UUID()
    @State private var isShowingVisualizer = false
    @State private var isShowingQueue = false
    @State private var isHoveringQueue = false
    @State private var footerHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    init(user: SoundCloudUser, model: AppModel) {
        self.user = user
        _model = ObservedObject(wrappedValue: model)
        _selectedDestination = State(initialValue: SidebarSelectionStore().restore(for: user))
    }

    private var destinationID: SidebarDestination.ID {
        (selectedDestination ?? .liked).id
    }

    private var path: [Route] {
        get { navigationHistories[destinationID, default: NavigationHistory()].path }
        nonmutating set { navigationHistories[destinationID, default: NavigationHistory()].path = newValue }
    }

    private var forwardPath: [Route] {
        get { navigationHistories[destinationID, default: NavigationHistory()].forwardPath }
        nonmutating set { navigationHistories[destinationID, default: NavigationHistory()].forwardPath = newValue }
    }

    var body: some View {
        // Keep overlays anchored to the window when a pushed page changes the split view's layout.
        GeometryReader { geometry in
            navigationView
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        // Preserve page and scroll state, but suppress page drawing and frame timelines.
        .opacity(isShowingVisualizer ? 0 : 1)
        .environment(\.contentAnimationsPaused, isShowingVisualizer)
        .toolbar(isShowingVisualizer ? .hidden : .automatic, for: .windowToolbar)
        .allowsHitTesting(!isShowingVisualizer)
        .accessibilityHidden(isShowingVisualizer)
        .environment(\.contentHoverEnabled, !isShowingQueue || !isHoveringQueue)
        .overlay {
            if isShowingVisualizer {
                VisualizerView(
                    playback: model.playback,
                    spectrumBuffer: model.analyzer.spectrumBuffer,
                    artworkLoader: model.artworkLoader
                )
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    isShowingVisualizer = false
                }
                .accessibilityAction(named: "Close visualizer") {
                    isShowingVisualizer = false
                }
                .background { visualizerShortcuts }
            }
        }
        .overlay {
            GeometryReader { geometry in
                let availableHeight = max(0, geometry.size.height - footerHeight)

                ZStack(alignment: .bottomTrailing) {
                    if isShowingQueue && !isShowingVisualizer {
                        TrackQueueView(
                            model: model,
                            onSelectTrack: showTrack,
                            onSelectArtist: showArtist,
                            onDismiss: { isShowingQueue = false }
                        )
                        .frame(
                            width: max(0, min(560, geometry.size.width - 28)),
                            height: max(0, min(520, availableHeight - 28))
                        )
                        .background {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color(white: colorScheme == .dark ? 0.20 : 0.94))
                                .shadow(color: .black, radius: 12, y: 4)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 16))
                        .onHover { isHoveringQueue = $0 }
                        .onDisappear { isHoveringQueue = false }
                        .padding(14)
                        .transition(
                            .move(edge: .bottom)
                                .combined(with: .opacity)
                        )
                    }
                }
                .frame(width: geometry.size.width, height: availableHeight, alignment: .bottomTrailing)
                .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: isShowingQueue)
            }
            .clipped()
        }
        .overlay(alignment: .bottom) {
            if !isShowingVisualizer {
                PlayerFooterView(
                    model: model,
                    isShowingQueue: $isShowingQueue,
                    isShowingVisualizer: $isShowingVisualizer,
                    onSelectTrack: showTrack,
                    onSelectArtist: showArtist,
                    onSelectPlaylist: { playlist in
                        isShowingQueue = false
                        showPlaylist(playlist)
                    },
                    onSelectStation: { urn, title in
                        isShowingQueue = false
                        if case let .station(currentURN, _, _) = path.last,
                           currentURN == urn { return }
                        showStation(urn, seedArtistName: title)
                    }
                )
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height
                } action: { height in
                    footerHeight = height
                }
            }
        }
        .environment(\.addToPlaylist, { playlistTrack = $0 })
        .sheet(item: $playlistTrack) { track in
            AddToPlaylistView(track: track, user: user, playlists: model.playlists)
        }
        .environment(\.searchGenre, showGenreSearch)
        .environment(\.searchTag, showTagSearch)
        .background {
            NavigationBackEventView(
                onBack: navigateBack,
                onForward: navigateForward
            )
        }
    }

    // The footer owns these shortcuts in normal mode. Keep them available when it is absent.
    private var visualizerShortcuts: some View {
        Group {
            Button("Close visualizer") { isShowingVisualizer = false }
                .keyboardShortcut("v", modifiers: [])
            Button("Close visualizer") { isShowingVisualizer = false }
                .keyboardShortcut(.cancelAction)
            Button("Play or Pause", action: model.playback.togglePlayPause)
                .keyboardShortcut(.space, modifiers: [])
            Button("Focus current track") {
                if let track = model.playback.currentTrack { showTrack(track) }
            }
            .keyboardShortcut("f", modifiers: [])
            Button("Focus current artist") {
                if let track = model.playback.currentTrack { showArtist(track.artist) }
            }
            .keyboardShortcut("a", modifiers: [])
            Button("Show track queue") {
                isShowingVisualizer = false
                isShowingQueue = true
            }
            .keyboardShortcut("q", modifiers: [])
        }
        .hidden()
        .accessibilityHidden(true)
    }

    private var navigationView: some View {
        NavigationSplitView {
            SidebarView(
                selection: sidebarSelection,
                playlists: model.playlists,
                user: user,
                artworkLoader: model.artworkLoader,
                onSelectPlaylist: showPlaylist,
                onSelectProfile: showArtist,
                onReselect: {
                    navigationHistories[destinationID] = NavigationHistory()
                    if selectedDestination == .search { searchFocusRequest = UUID() }
                },
                onSignOut: model.signOut
            )
                .safeAreaPadding(.bottom, max(0, footerHeight - 20))
                .navigationSplitViewColumnWidth(
                    min: 180,
                    ideal: 220,
                    max: 280
                )
        } detail: {
            selectedView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            Group {
                Button("Open search", action: openSearch)
                    .keyboardShortcut("/", modifiers: [])
                Button("Open search") { openDestination(.search) }
                    .keyboardShortcut("1", modifiers: [])
                Button("Open feed") { openDestination(.feed) }
                    .keyboardShortcut("2", modifiers: [])
                Button("Open likes") { openDestination(.liked) }
                    .keyboardShortcut("3", modifiers: [])
                Button("Open history") { openDestination(.history) }
                    .keyboardShortcut("4", modifiers: [])
            }
            .hidden()
            .accessibilityHidden(true)
        }
    }

    private func openDestination(_ destination: SidebarDestination) {
        isShowingVisualizer = false
        isShowingQueue = false
        if selectedDestination == destination {
            navigationHistories[destination.id] = NavigationHistory()
        }
        sidebarSelection.wrappedValue = destination
    }

    private func openSearch() {
        sidebarSelection.wrappedValue = .search
    }

    // Keep browser history as data. Rendering a native stack of all visited pages
    // makes layout and row updates grow with browsing depth, even when pages hide.
    // Retain visited top-level pages to preserve their content and scroll position.
    private var selectedView: some View {
        NavigationStack {
            CurrentNavigationPage(route: path.last, retainsRoot: true) {
                RetainedRootPages(
                    selections: SidebarDestination.libraryDestinations,
                    selection: selectedDestination ?? .liked,
                    isActive: path.isEmpty
                ) { destination, active in
                    rootView(destination, isActive: active)
                        .environment(\.contentAnimationsPaused, isShowingVisualizer || !active)
                        .environment(\.contentHoverEnabled, active && (!isShowingQueue || !isHoveringQueue))
                }
                .navigationTitle((selectedDestination ?? .liked).title)
            } destination: { route in
                routeView(route)
                    .id(destinationID)
            }
            .modifier(NavigationPageActivity())
            .safeAreaPadding(.bottom, footerHeight)
            .mask { bottomFade }
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .modifier(NavigationPageViewport())
            .toolbar { navigationToolbar }
        }
    }

    @ViewBuilder
    private func routeView(_ route: Route) -> some View {
        switch route {
        case let .tag(tag):
            ScrollView {
                SearchResultsView(
                    query: tag,
                    isTagSearch: true,
                    model: model,
                    onSelectTrack: showTrack,
                    onSelectPlaylist: showPlaylist,
                    onSelectArtist: showArtist
                )
            }
            .background(alignment: .top) {
                RouteGradientBackdrop()
            }
            .id(route)
        case let .genre(genre):
            ScrollView {
                SearchResultsView(
                    query: genre,
                    isGenreSearch: true,
                    model: model,
                    onSelectTrack: showTrack,
                    onSelectPlaylist: showPlaylist,
                    onSelectArtist: showArtist
                )
            }
            .background(alignment: .top) {
                RouteGradientBackdrop()
            }
            .id(route)
        case let .track(track):
            TrackDetailView(
                track: track,
                model: model,
                onSelectTrack: showTrack,
                onSelectArtist: showArtist,
                onSelectStation: { urn, seedTrack in
                    forwardPath.removeAll()
                    path.append(.station(
                        urn,
                        seedTrack: seedTrack
                    ))
                }
            )
            .id(track.urn)
        case let .playlist(playlist):
            PlaylistDetailView(
                playlist: playlist,
                model: model,
                onSelectTrack: showTrack,
                onSelectArtist: showArtist,
                onDeletePlaylist: removeDeletedPlaylist,
                playlists: model.playlists
            )
            .id(playlist.urn)
        case let .station(urn, seedTrack, seedArtistName):
            StationDetailView(
                urn: urn,
                seedTrack: seedTrack,
                seedArtistName: seedArtistName,
                model: model,
                onSelectTrack: showTrack,
                onSelectArtist: showArtist
            )
            .id(urn)
        case let .artist(artist):
            ArtistDetailView(
                artist: artist,
                model: model,
                selectedTab: artistTabSelection(for: artist),
                onSelectTrack: showTrack,
                onSelectArtist: showArtist,
                onSelectPlaylist: showPlaylist,
                onSelectUsers: showArtistUsers,
                onSelectStation: showStation
            )
            .id(artist.permalinkURL)
        case let .artistUsers(artist, list):
            ArtistUsersView(
                artist: artist, list: list, model: model,
                onSelectArtist: showArtist
            )
            .id(route)
        }
    }

    private func artistTabSelection(for artist: SoundCloudUser) -> Binding<ArtistDetailView.ContentTab> {
        let historyID = destinationID
        let artistURL = artist.permalinkURL
        return Binding(
            get: { navigationHistories[historyID]?.artistTabs[artistURL] ?? .tracks },
            set: { navigationHistories[historyID, default: NavigationHistory()].artistTabs[artistURL] = $0 }
        )
    }

    private var bottomFade: some View {
        VStack(spacing: 0) {
            Color.black
            LinearGradient(
                colors: [.black, .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 120)
        }
        // Preserve artwork that extends behind the toolbar and sidebar.
        .ignoresSafeArea(edges: [.top, .leading, .trailing])
    }

    @ViewBuilder
    private func rootView(_ destination: SidebarDestination, isActive: Bool) -> some View {
        switch destination {
        case .feed:
            FeedView(
                model: model,
                onSelectPlaylist: showPlaylist,
                onSelectTrack: showTrack,
                onSelectArtist: showArtist,
                feed: model.feed
            )
        case .search:
            SearchView(
                user: user,
                searchText: $searchText,
                focusRequest: searchFocusRequest,
                isActive: isActive
            ) { query in
                SearchResultsView(
                    query: query,
                    contentPadding: 0,
                    model: model,
                    onSelectTrack: showTrack,
                    onSelectPlaylist: showPlaylist,
                    onSelectArtist: showArtist
                )
            }
        case .history:
            HistoryView(
                model: model,
                onSelectTrack: showTrack,
                onSelectArtist: showArtist
            )
        case .liked:
            LikesView(
                user: user,
                searchText: $likesSearchText,
                isActive: isActive,
                likes: model.likes,
                playback: model.playback,
                analyzer: model.analyzer,
                artworkLoader: model.artworkLoader,
                appErrorMessage: model.errorMessage,
                onSelectArtist: showArtist,
                onSelectTrack: showTrack,
                onAddToQueue: model.addToQueue,
                onPlayTrack: model.playLikedTrack
            )
        }
    }

    // Only the current page contributes toolbar content.
    @ToolbarContentBuilder
    private var navigationToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            navigationButtons
        }
    }

    private var navigationButtons: some View {
        ControlGroup {
            Button {
                _ = navigateBack()
            } label: {
                Label("Back", systemImage: "chevron.left")
                    .frame(width: 16, height: 16)
            }
            .disabled(path.isEmpty)
            .help("Go back")

            Button {
                _ = navigateForward()
            } label: {
                Label("Forward", systemImage: "chevron.right")
                    .frame(width: 16, height: 16)
            }
            .disabled(forwardPath.isEmpty)
            .help("Go forward")
        }
        .labelStyle(.iconOnly)
    }

    private func showTagSearch(_ tag: String) {
        guard !tag.isEmpty else { return }
        forwardPath.removeAll()
        path.append(.tag(tag))
    }

    private func showGenreSearch(_ genre: String) {
        guard !genre.isEmpty else { return }
        forwardPath.removeAll()
        path.append(.genre(genre))
    }

    private func showTrack(_ track: SoundCloudTrack) {
        isShowingVisualizer = false
        isShowingQueue = false
        if case let .track(current) = path.last,
           current.urn == track.urn { return }
        forwardPath.removeAll()
        path.append(.track(track))
    }

    private func showPlaylist(_ playlist: SoundCloudPlaylist) {
        if case let .playlist(current) = path.last,
           current.urn == playlist.urn { return }
        forwardPath.removeAll()
        path.append(.playlist(playlist))
    }

    private func removeDeletedPlaylist(_ playlist: SoundCloudPlaylist) {
        // These pages use custom history, so SwiftUI's dismiss can close the window.
        // Remove all visits, including forward history, so deletion cannot be undone by navigation.
        navigationHistories = navigationHistories.mapValues { history in
            var history = history
            let isDeletedPlaylist: (Route) -> Bool = { route in
                guard case let .playlist(candidate) = route else { return false }
                return candidate.urn == playlist.urn
            }
            history.path.removeAll(where: isDeletedPlaylist)
            history.forwardPath.removeAll(where: isDeletedPlaylist)
            return history
        }
    }

    private func showStation(_ urn: String, seedArtistName: String) {
        forwardPath.removeAll()
        path.append(.station(urn, seedArtistName: seedArtistName))
    }

    private func showArtist(_ artist: SoundCloudUser) {
        isShowingVisualizer = false
        isShowingQueue = false
        if case let .artist(current) = path.last,
           current.permalinkURL == artist.permalinkURL { return }
        forwardPath.removeAll()
        path.append(.artist(artist))
    }

    private func showArtistUsers(_ artist: SoundCloudUser, list: ArtistUserList) {
        forwardPath.removeAll()
        path.append(.artistUsers(artist, list))
    }

    private func navigateBack() -> Bool {
        if isShowingVisualizer {
            isShowingVisualizer = false
            return true
        }

        guard let route = path.popLast() else {
            return false
        }

        forwardPath.append(route)
        return true
    }

    private func navigateForward() -> Bool {
        guard let route = forwardPath.popLast() else {
            return false
        }

        path.append(route)
        return true
    }

    private var sidebarSelection: Binding<SidebarDestination?> {
        Binding(
            get: { selectedDestination },
            set: { destination in
                guard let destination else { return }
                if destination == .search {
                    navigationHistories[destination.id] = NavigationHistory()
                    searchFocusRequest = UUID()
                }
                selectedDestination = destination
                selectionStore.save(destination, for: user)
            }
        )
    }

}

private struct NavigationPageActivity: ViewModifier {
    @Environment(\.contentAnimationsPaused) private var animationsPaused
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .environment(\.contentAnimationsPaused, animationsPaused || !isVisible)
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
    }
}

private struct NavigationHistory {
    var path: [Route] = []
    var forwardPath: [Route] = []
    // Page views are recreated on navigation, so keep each artist's tab with its history.
    var artistTabs: [URL: ArtistDetailView.ContentTab] = [:]
}

private struct QueueBlurModifier: AnimatableModifier {
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func body(content: Content) -> some View {
        content.blur(radius: max(0, radius))
    }
}

private enum Route: Hashable {
    case genre(String)
    case tag(String)
    case playlist(SoundCloudPlaylist)
    case station(String, seedTrack: SoundCloudTrack? = nil, seedArtistName: String? = nil)
    case track(SoundCloudTrack)
    case artist(SoundCloudUser)
    case artistUsers(SoundCloudUser, ArtistUserList)
}

// Hidden pages retain their state without running continuous animation timelines.
extension EnvironmentValues {
    @Entry var contentAnimationsPaused = false
}

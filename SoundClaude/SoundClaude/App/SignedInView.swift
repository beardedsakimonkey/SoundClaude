import SwiftUI

struct SignedInView: View {
    let user: SoundCloudUser

    private let model: AppModel
    @State private var selectedDestination: SidebarDestination?
    private let selectionStore = SidebarSelectionStore()
    @State private var artistTabSelections = ArtistTabSelections()
    @State private var navigationHistories: [SidebarDestination.ID: NavigationHistory] = [:]
    @State private var initialDetailArtworkRotation: Bool?
    @State private var playlistTrack: SoundCloudTrack?
    @State private var searchText = ""
    @State private var likesSearchText = ""
    @State private var historySearchText = ""
    // Restoring Search at launch must not request keyboard focus.
    @State private var searchFocusRequest: UUID?
    @State private var isShowingVisualizer = false
    @State private var queuePresentation = QueuePresentation()
    @State private var isOpeningCurrentTrackStation = false
    @State private var stationErrorMessage: String?
    @State private var queueHoverSuppression = ContentHoverSuppression()
    @State private var footerHeight: CGFloat = 0

    init(user: SoundCloudUser, model: AppModel) {
        self.user = user
        self.model = model
        let selection = SidebarSelectionStore().restoreNavigation(for: user)
        _selectedDestination = State(initialValue: selection.destination)
        _navigationHistories = State(initialValue: selection.navigationHistories)
    }

    private var navigationSelection: NavigationSelection {
        NavigationSelection(destination: selectedDestination ?? .liked, route: path.last)
    }

    private var destinationID: SidebarDestination.ID {
        (selectedDestination ?? .liked).id
    }

    private var path: [Route] {
        get { navigationHistories[destinationID, default: NavigationHistory()].path }
        nonmutating set {
            if path.last != newValue.last {
                // Capture the source pose before replacing the page, including Back/Forward.
                switch (path.last, newValue.last) {
                case (.track, .playlist), (.track, .station):
                    initialDetailArtworkRotation = false
                case (.playlist, .track), (.station, .track):
                    initialDetailArtworkRotation = true
                default:
                    initialDetailArtworkRotation = nil
                }
            }
            navigationHistories[destinationID, default: NavigationHistory()].path = newValue
        }
    }

    private var forwardPath: [Route] {
        get { navigationHistories[destinationID, default: NavigationHistory()].forwardPath }
        nonmutating set { navigationHistories[destinationID, default: NavigationHistory()].forwardPath = newValue }
    }

    private var currentPlaylistURN: String? {
        guard case let .playlist(playlist) = path.last else { return nil }
        return playlist.urn
    }

    private var currentStationURN: String? {
        guard case let .station(urn, _, _) = path.last else { return nil }
        return urn
    }

    var body: some View {
        #if DEBUG
        let _ = Self._printChanges()
        #endif
        // Keep overlays anchored to the window when a pushed page changes the split view's layout.
        GeometryReader { geometry in
            navigationView
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onChange(of: navigationSelection) { _, selection in
            selectionStore.save(selection, for: user)
        }
        // Preserve page and scroll state, but suppress page drawing and frame timelines.
        .opacity(isShowingVisualizer ? 0 : 1)
        .environment(\.contentAnimationsPaused, isShowingVisualizer)
        .environment(\.contentHoverEnabled, !isShowingVisualizer)
        .toolbar(isShowingVisualizer ? .hidden : .automatic, for: .windowToolbar)
        .allowsHitTesting(!isShowingVisualizer)
        .accessibilityHidden(isShowingVisualizer)
        .environment(\.contentHoverSuppression, queueHoverSuppression)
        .overlay {
            if isShowingVisualizer {
                VisualizerView(
                    playback: model.playback,
                    spectrumBuffer: model.analyzer.spectrumBuffer,
                    artworkLoader: model.artworkLoader,
                    onClose: { isShowingVisualizer = false }
                )
                .ignoresSafeArea()
                .accessibilityAction(named: "Close visualizer") {
                    isShowingVisualizer = false
                }
                .background { visualizerShortcuts }
            }
        }
        .overlay(alignment: .bottom) {
            if !isShowingVisualizer {
                QueuePresentationReader(presentation: queuePresentation) { isShowingQueue in
                    PlayerFooterView(
                        model: model,
                        isShowingQueue: isShowingQueue,
                        isShowingVisualizer: $isShowingVisualizer,
                        onSelectTrack: showTrack,
                        onSelectArtist: showArtist,
                        onSelectPlaylist: showPlaylist,
                        onSelectStation: { urn, title in
                            if case let .station(currentURN, _, _) = path.last,
                               currentURN == urn { return }
                            showStation(urn, seedArtistName: title)
                        }
                    )
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height
                } action: { height in
                    footerHeight = height
                }
            }
        }
        .overlay {
            TrackQueueOverlay(
                presentation: queuePresentation,
                isShowingVisualizer: isShowingVisualizer,
                footerHeight: footerHeight,
                hoverSuppression: queueHoverSuppression,
                content: TrackQueueView(
                    model: model,
                    onSelectTrack: showTrack,
                    onSelectArtist: showArtist,
                    onSelectSource: showQueueSource,
                    onDismiss: { queuePresentation.isVisible = false }
                )
            )
        }
        .environment(\.openTrackStation) { track in
            Task { await showTrackStation(track) }
        }
        .environment(\.openArtistStation) { artist in
            Task { await showArtistStation(artist) }
        }
        .environment(\.waveformCommentArtistAction, showArtist)
        .environment(\.addToPlaylist, { playlistTrack = $0 })
        .sheet(item: $playlistTrack) { track in
            AddToPlaylistView(
                track: track,
                user: user,
                playlists: model.playlists,
                artworkLoader: model.artworkLoader
            )
        }
        .environment(\.searchGenre, showGenreSearch)
        .environment(\.searchTag, showTagSearch)
        .background {
            CurrentStationShortcut(
                playback: model.playback,
                isOpeningStation: isOpeningCurrentTrackStation,
                action: showCurrentStation
            )
        }
        .task(id: isOpeningCurrentTrackStation) {
            guard isOpeningCurrentTrackStation else { return }
            defer { isOpeningCurrentTrackStation = false }
            await showCurrentTrackStation()
        }
        .alert("Could not open station", isPresented: Binding(
            get: { stationErrorMessage != nil },
            set: { if !$0 { stationErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { stationErrorMessage = nil }
        } message: {
            Text(stationErrorMessage ?? "Please try again.")
        }
        .background {
            NavigationBackEventView(
                onBack: navigateBack,
                onForward: navigateForward
            )
        }
        #if DEBUG
        .debugViewUpdates("SignedInView")
        #endif
    }

    // The footer owns these shortcuts in normal mode. Keep them available when it is absent.
    private var visualizerShortcuts: some View {
        Group {
            Button("Close visualizer") { isShowingVisualizer = false }
                .keyboardShortcut("v", modifiers: [])
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
                queuePresentation.isVisible = true
            }
            .keyboardShortcut("q", modifiers: [])
        }
        .hidden()
        .accessibilityHidden(true)
    }

    private var navigationView: some View {
        NavigationSplitView {
            SidebarView(
                selection: selectedDestination,
                onSelect: selectDestination,
                currentPlaylistURN: currentPlaylistURN,
                currentStationURN: currentStationURN,
                playbackSource: model.queue.source,
                playback: model.playback,
                playlists: model.playlists,
                likes: model.likes,
                user: user,
                artworkLoader: model.artworkLoader,
                onPlayLikes: playLikes,
                onShuffleLikes: shuffleLikes,
                onSelectStation: { station in
                    isShowingVisualizer = false
                    if station.isStation {
                        guard currentStationURN != station.urn else { return }
                        showStation(station.urn, seedArtistName: station.displayTitle)
                    } else {
                        showPlaylist(.systemPlaylist(urn: station.urn, title: station.displayTitle))
                    }
                },
                onPlayStation: { station in
                    let contents = try await model.station(urn: station.urn)
                    try Task.checkCancellation()
                    guard let track = contents.tracks.first else {
                        throw SoundCloudError.api("This station has no playable tracks.")
                    }
                    await model.play(track, queue: TrackQueue(
                        source: station.isStation ? .station(station.urn) : .playlist(station.urn),
                        tracks: contents.tracks,
                        sourceTitle: contents.title ?? station.displayTitle
                    ))
                },
                onSelectPlaylist: showPlaylist,
                onPlayPlaylist: { playlist, contents in
                    guard let track = model.playback.isShuffleEnabled
                        ? contents.tracks.randomElement() : contents.tracks.first else { return }
                    await model.play(track, queue: TrackQueue(
                        source: .playlist(playlist.urn),
                        tracks: contents.tracks,
                        nextPageURL: contents.nextPageURL, sourceTitle: contents.playlist.title
                    ))
                },
                onDeletePlaylist: removeDeletedPlaylist,
                onSelectProfile: showArtist,
                onReselect: {
                    navigationHistories[destinationID] = NavigationHistory()
                    artistTabSelections.tabs[destinationID] = nil
                    if selectedDestination == .search { searchFocusRequest = UUID() }
                },
                onSignOut: model.signOut
            )
                .safeAreaPadding(.bottom, max(0, footerHeight - 20))
                .toolbar(removing: .sidebarToggle)
                .background(NonCollapsingSidebar())
                .navigationSplitViewColumnWidth(
                    min: 180,
                    ideal: 220,
                    max: 480
                )
        } detail: {
            selectedView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                #if DEBUG
                .overlayPreferenceValue(TrackArtworkQueueDebugKey.self, alignment: .topTrailing) { queues in
                    if let prefetcher = queues.last {
                        TrackArtworkQueueDebugOverlay(prefetcher: prefetcher)
                    }
                }
                #endif
        }
        .background {
            Button("Open search", action: openSearch)
                .keyboardShortcut("/", modifiers: [])
                .hidden()
                .accessibilityHidden(true)
        }
    }

    private func openDestination(_ destination: SidebarDestination) {
        isShowingVisualizer = false
        if selectedDestination == destination {
            navigationHistories[destination.id] = NavigationHistory()
            artistTabSelections.tabs[destination.id] = nil
        }
        selectDestination(destination)
    }

    private func openSearch() {
        selectDestination(.search)
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
                        .environment(\.contentHoverEnabled, active && !isShowingVisualizer)
                }
                .navigationTitle((selectedDestination ?? .liked).title)
            } destination: { route in
                routeView(route)
                    .environment(\.initialDetailArtworkRotation, initialDetailArtworkRotation)
                    .id(destinationID)
            }
            .backgroundPreferenceValue(TrackDetailBackdropPreferenceKey.self) { source in
                if let source {
                    TrackDetailBackdrop(artworkURL: source.artworkURL, loader: model.artworkLoader)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .ignoresSafeArea(edges: .top)
                }
            }
            .modifier(DetailWaveformOverlay(model: model, routeID: AnyHashable(path.last)))
            .modifier(DetailTrackHeadingOverlay(
                artworkLoader: model.artworkLoader, routeID: AnyHashable(path.last)
            ))
            .modifier(DetailPlayButtonOverlay(routeID: AnyHashable(path.last)))
            .modifier(DetailLikeButtonOverlay(routeID: AnyHashable(path.last)))
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
        case let .search(query):
            ScrollbarReservedScrollView { contentSize in
                SearchResultsView(
                    query: query,
                    model: model,
                    onSelectTrack: showTrack,
                    onSelectPlaylist: showPlaylist,
                    onSelectArtist: showArtist
                )
                .environment(\.searchViewportHeight, contentSize.height)
            }
            .background(alignment: .top) {
                RouteGradientBackdrop()
            }
            .id(route)
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
                .scrollKeyNavigation()
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
                .scrollKeyNavigation()
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
                playlists: model.playlists,
                likes: model.likes
            )
            .id(playlist.urn)
        case let .station(urn, seedTrack, seedArtistName):
            StationDetailView(
                urn: urn,
                seedTrack: seedTrack,
                seedArtistName: seedArtistName,
                model: model,
                likes: model.likes,
                onSelectTrack: showTrack,
                onSelectArtist: showArtist
            )
            .id(urn)
        case let .artist(artist):
            ArtistDetailView(
                artist: artist,
                model: model,
                tabSelection: artistTabSelection(for: artist),
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

    private func artistTabSelection(for artist: SoundCloudUser) -> ArtistTabSelection {
        artistTabSelections.selection(for: artist.permalinkURL, in: destinationID)
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
                isActive: isActive,
                onSearch: { query in
                    forwardPath.removeAll()
                    path.append(.search(query))
                }
            )
        case .history:
            HistoryView(
                model: model,
                searchText: $historySearchText,
                isActive: isActive,
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
            .contentHelp("Go back")

            Button {
                _ = navigateForward()
            } label: {
                Label("Forward", systemImage: "chevron.right")
                    .frame(width: 16, height: 16)
            }
            .disabled(forwardPath.isEmpty)
            .contentHelp("Go forward")
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
        if case let .track(current) = path.last,
           current.urn == track.urn { return }
        forwardPath.removeAll()
        path.append(.track(track))
    }

    private func playLikes() async {
        guard !Task.isCancelled,
              let track = model.playback.isShuffleEnabled
                ? model.likes.tracks.randomElement() : model.likes.tracks.first else { return }
        await model.playLikedTrack(track)
    }

    private func shuffleLikes() async {
        guard !Task.isCancelled, let track = model.likes.tracks.randomElement() else { return }
        if !model.playback.isShuffleEnabled {
            model.toggleShuffle()
        }
        await model.playLikedTrack(track)
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

    private func showCurrentStation() {
        guard model.playback.currentTrack != nil else { return }
        switch model.queue.source {
        case let .station(urn):
            isShowingVisualizer = false
            if case let .station(currentURN, _, _) = path.last, currentURN == urn { return }
            showStation(urn, seedArtistName: model.queue.sourceTitle ?? "Station")
        default:
            isOpeningCurrentTrackStation = true
        }
    }

    private func showCurrentTrackStation() async {
        guard let track = model.playback.currentTrack else { return }
        await showTrackStation(track, requiresCurrentTrack: true)
    }

    private func showTrackStation(_ track: SoundCloudTrack, requiresCurrentTrack: Bool = false) async {
        let source = model.queue.source
        do {
            var seedTrack = track
            var urn = track.stationURN?.trimmingCharacters(in: .whitespacesAndNewlines)
            if urn?.isEmpty != false {
                seedTrack = try await model.trackDetails(for: track).track
                urn = seedTrack.stationURN?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            try Task.checkCancellation()
            if requiresCurrentTrack {
                guard model.playback.currentTrack?.urn == track.urn,
                      model.queue.source == source else { return }
            }
            guard let urn, !urn.isEmpty else {
                stationErrorMessage = "No station is available for this track."
                return
            }
            isShowingVisualizer = false
            if case let .station(currentURN, _, _) = path.last, currentURN == urn { return }
            forwardPath.removeAll()
            path.append(.station(urn, seedTrack: seedTrack))
        } catch {
            guard !Task.isCancelled else { return }
            if requiresCurrentTrack {
                guard model.playback.currentTrack?.urn == track.urn,
                      model.queue.source == source else { return }
            }
            stationErrorMessage = error.localizedDescription
        }
    }

    private func showArtistStation(_ artist: SoundCloudUser) async {
        do {
            var user = artist
            var urn = user.stationURN?.trimmingCharacters(in: .whitespacesAndNewlines)
            if urn?.isEmpty != false {
                user = try await model.artistDetails(for: artist).user
                urn = user.stationURN?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            try Task.checkCancellation()
            guard let urn, !urn.isEmpty else {
                stationErrorMessage = "No station is available for this artist."
                return
            }
            isShowingVisualizer = false
            if case let .station(currentURN, _, _) = path.last, currentURN == urn { return }
            showStation(urn, seedArtistName: user.username)
        } catch is CancellationError {
        } catch {
            stationErrorMessage = error.localizedDescription
        }
    }

    private func showQueueSource() {
        let queue = model.queue
        switch queue.source {
        case .single:
            return
        case .feed:
            openDestination(.feed)
        case .likes:
            openDestination(.liked)
        case .history:
            openDestination(.history)
        case let .search(query):
            showQueueSourceRoute(.search(query))
        case let .genre(genre):
            showQueueSourceRoute(.genre(genre))
        case let .tag(tag):
            showQueueSourceRoute(.tag(tag))
        case let .playlist(urn):
            let title = model.queuePlaylist?.title ?? "Playlist"
            Task {
                if let playlist = await model.playlistDetails(urn: urn, title: title) {
                    showPlaylist(playlist)
                }
            }
        case let .station(urn):
            if case let .station(currentURN, _, _) = path.last, currentURN == urn { return }
            showStation(urn, seedArtistName: queue.sourceTitle ?? "Station")
        case .related:
            if let track = queue.sourceTrack { showTrack(track) }
        case .artist:
            showQueueSourceArtist(queue.sourceArtist, tab: .tracks)
        case .artistReposts:
            showQueueSourceArtist(queue.sourceArtist, tab: .reposts)
        case .artistLikes:
            showQueueSourceArtist(queue.sourceArtist, tab: .likes)
        }
    }

    private func showQueueSourceRoute(_ route: Route) {
        guard path.last != route else { return }
        forwardPath.removeAll()
        path.append(route)
    }

    private func showQueueSourceArtist(_ artist: SoundCloudUser?, tab: ArtistDetailView.ContentTab) {
        guard let artist else { return }
        artistTabSelection(for: artist).tab = tab
        showArtist(artist)
    }

    private func showStation(_ urn: String, seedArtistName: String) {
        forwardPath.removeAll()
        path.append(.station(urn, seedArtistName: seedArtistName))
    }

    private func showArtist(_ artist: SoundCloudUser) {
        isShowingVisualizer = false
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

    // Pass the selection as a value. SwiftUI cannot compare a computed Binding,
    // so it would invalidate the sidebar on unrelated graph updates such as scrolling.
    private func selectDestination(_ destination: SidebarDestination) {
        if destination == .search {
            navigationHistories[destination.id] = NavigationHistory()
            artistTabSelections.tabs[destination.id] = nil
            searchFocusRequest = UUID()
        }
        initialDetailArtworkRotation = nil
        selectedDestination = destination
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

// Hidden pages retain their state without running continuous animation timelines.
extension EnvironmentValues {
    @Entry var contentAnimationsPaused = false
}

// Observe track availability here, outside the navigation view's body.
private struct CurrentStationShortcut: View {
    let playback: PlaybackController
    let isOpeningStation: Bool
    let action: () -> Void

    var body: some View {
        Button("Open Active Station or Current Track Station", action: action)
            .keyboardShortcut("s", modifiers: [])
            .disabled(playback.currentTrack == nil || isOpeningStation)
            .hidden()
            .accessibilityHidden(true)
    }
}

// Preserve tab choices across navigation without invalidating the navigation tree.
private final class ArtistTabSelections {
    var tabs: [SidebarDestination.ID: [URL: ArtistTabSelection]] = [:]

    func selection(for artistURL: URL, in historyID: SidebarDestination.ID) -> ArtistTabSelection {
        if let selection = tabs[historyID]?[artistURL] { return selection }
        let selection = ArtistTabSelection()
        tabs[historyID, default: [:]][artistURL] = selection
        return selection
    }
}

private struct TrackQueueOverlay<Content: View>: View {
    let presentation: QueuePresentation
    let isShowingVisualizer: Bool
    let footerHeight: CGFloat
    let hoverSuppression: ContentHoverSuppression
    let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGSize(
                width: geometry.size.width,
                height: max(0, geometry.size.height - footerHeight)
            )
            QueuePanel(
                bounds: bounds,
                isVisible: presentation.isVisible && !isShowingVisualizer,
                hoverSuppression: hoverSuppression,
                content: content
            )
            .animation(
                reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85),
                value: presentation.isVisible
            )
        }
        .clipped()
    }
}

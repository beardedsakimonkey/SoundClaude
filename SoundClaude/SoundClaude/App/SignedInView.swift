import SwiftUI

struct SignedInView: View {
    let user: SoundCloudUser

    @ObservedObject private var model: AppModel
    @State private var selectedDestination: SidebarDestination?
    private let selectionStore = SidebarSelectionStore()
    @State private var navigationHistories: [SidebarDestination.ID: NavigationHistory] = [:]
    @State private var isShowingQueue = false
    @State private var isHoveringQueue = false
    @State private var footerHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        NavigationSplitView {
            SidebarView(
                selection: sidebarSelection,
                playlists: model.playlists,
                user: user,
                artworkLoader: model.artworkLoader,
                onSearch: showSearch,
                onSelectProfile: showArtist,
                onSignOut: model.signOut
            )
                .safeAreaPadding(.bottom, footerHeight)
                .navigationSplitViewColumnWidth(
                    min: 180,
                    ideal: 220,
                    max: 280
                )
        } detail: {
            selectedView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(\.contentHoverEnabled, !isShowingQueue || !isHoveringQueue)
        .overlay {
            GeometryReader { geometry in
                let availableHeight = max(0, geometry.size.height - footerHeight)

                ZStack(alignment: .bottomTrailing) {
                    if isShowingQueue {
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
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 16))
                        .onHover { isHoveringQueue = $0 }
                        .onDisappear { isHoveringQueue = false }
                        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
                        .padding(14)
                        .transition(
                            .move(edge: .bottom)
                                .combined(with: .opacity)
                                .combined(with: .modifier(
                                    active: QueueBlurModifier(radius: 12),
                                    identity: QueueBlurModifier(radius: 0)
                                ))
                        )
                    }
                }
                .frame(width: geometry.size.width, height: availableHeight, alignment: .bottomTrailing)
                .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: isShowingQueue)
            }
            .clipped()
        }
        .overlay(alignment: .bottom) {
            PlayerFooterView(
                model: model,
                isShowingQueue: $isShowingQueue,
                onSelectTrack: showTrack,
                onSelectArtist: showArtist
            )
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { height in
                footerHeight = height
            }
        }
        .environment(\.searchGenre, showGenreSearch)
        .background {
            NavigationBackEventView(
                onBack: navigateBack,
                onForward: navigateForward
            )
        }
    }

    // Apply the clearance and fade to each page inside the navigation stack.
    // The scroll views still draw behind the footer, but can scroll their last row above it.
    private var selectedView: some View {
        NavigationStack(path: navigationPath) {
            rootView
                .safeAreaPadding(.bottom, footerHeight)
                .mask { bottomFade }
                .toolbar { navigationToolbar }
                .navigationDestination(for: Route.self) { route in
                    Group {
                        switch route {
                        case let .search(query):
                            SearchResultsView(
                                query: query,
                                model: model,
                                onSelectTrack: showTrack,
                                onSelectPlaylist: showPlaylist,
                                onSelectArtist: showArtist
                            )
                            .id(query)
                            .navigationBarBackButtonHidden(true)
                            .toolbar { navigationToolbar }
                        case let .genre(genre):
                            SearchResultsView(
                                query: genre,
                                isGenreSearch: true,
                                model: model,
                                onSelectTrack: showTrack,
                                onSelectPlaylist: showPlaylist,
                                onSelectArtist: showArtist
                            )
                            .id(route)
                            .navigationBarBackButtonHidden(true)
                            .toolbar { navigationToolbar }
                        case let .track(track):
                            TrackDetailView(
                                track: track,
                                model: model,
                                onSelectTrack: showTrack,
                                onSelectArtist: showArtist
                            )
                            .id(track.urn)
                            .navigationBarBackButtonHidden(true)
                            .toolbar { navigationToolbar }
                        case let .playlist(playlist):
                            PlaylistDetailView(
                                playlist: playlist,
                                model: model,
                                onSelectTrack: showTrack,
                                onSelectArtist: showArtist,
                                playlists: model.playlists
                            )
                            .id(playlist.urn)
                            .navigationBarBackButtonHidden(true)
                            .toolbar { navigationToolbar }
                        case let .artist(artist):
                            ArtistDetailView(
                                artist: artist,
                                model: model,
                                onSelectTrack: showTrack,
                                onSelectArtist: showArtist,
                                onSelectPlaylist: showPlaylist,
                                onSelectUsers: showArtistUsers
                            )
                            .id(artist.permalinkURL)
                            .navigationBarBackButtonHidden(true)
                            .toolbar { navigationToolbar }
                        case let .artistUsers(artist, list):
                            ArtistUsersView(
                                artist: artist, list: list, model: model,
                                onSelectArtist: showArtist
                            )
                            .id(route)
                            .navigationBarBackButtonHidden(true)
                            .toolbar { navigationToolbar }
                        }
                    }
                    .safeAreaPadding(.bottom, footerHeight)
                    .mask { bottomFade }
                }
        }
        .id(destinationID)
    }

    private var bottomFade: some View {
        VStack(spacing: 0) {
            Color.black
            LinearGradient(
                colors: [.black, .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 80)
        }
        // Preserve artwork that extends behind the toolbar and sidebar.
        .ignoresSafeArea(edges: [.top, .leading, .trailing])
    }

    @ViewBuilder
    private var rootView: some View {
        switch selectedDestination {
        case .feed:
            FeedView(
                model: model,
                onSelectPlaylist: showPlaylist,
                onSelectTrack: showTrack,
                onSelectArtist: showArtist,
                feed: model.feed
            )
        case .history:
            HistoryView(
                model: model,
                onSelectTrack: showTrack,
                onSelectArtist: showArtist
            )
        case let .playlist(playlist):
            PlaylistDetailView(
                playlist: playlist,
                model: model,
                onSelectTrack: showTrack,
                onSelectArtist: showArtist,
                playlists: model.playlists
            )
            .id(playlist.urn)
        case .liked, .none:
            LikesView(
                user: user,
                likes: model.likes,
                playback: model.playback,
                artworkLoader: model.artworkLoader,
                spectrumBuffer: model.analyzer.spectrumBuffer,
                appErrorMessage: model.errorMessage,
                onSelectArtist: showArtist,
                onSelectTrack: showTrack,
                onPlayTrack: model.playLikedTrack
            )
        }
    }

    // Each stack page owns its toolbar; pushed pages replace the parent toolbar.
    @ToolbarContentBuilder
    private var navigationToolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) {
                navigationButtons
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) {
                navigationButtons
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
            }
        }
    }

    private var navigationButtons: some View {
        HStack(spacing: 8) {
            Button {
                _ = navigateBack()
            } label: {
                Label("Back", systemImage: "chevron.left")
                    .frame(width: 16, height: 16)
            }
            .disabled(path.isEmpty)
            .help("Go back")

            if !forwardPath.isEmpty {
                Button {
                    _ = navigateForward()
                } label: {
                    Label("Forward", systemImage: "chevron.right")
                        .frame(width: 16, height: 16)
                }
                .help("Go forward")
            }
        }
        .labelStyle(.iconOnly)
    }

    private func showSearch(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        forwardPath.removeAll()
        path.append(.search(query))
    }

    private func showGenreSearch(_ genre: String) {
        guard !genre.isEmpty else { return }
        forwardPath.removeAll()
        path.append(.genre(genre))
    }

    private func showTrack(_ track: SoundCloudTrack) {
        isShowingQueue = false
        if case let .track(current) = path.last,
           current.urn == track.urn { return }
        forwardPath.removeAll()
        path.append(.track(track))
    }

    private func showPlaylist(_ playlist: SoundCloudPlaylist) {
        forwardPath.removeAll()
        path.append(.playlist(playlist))
    }

    private func showArtist(_ artist: SoundCloudUser) {
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
                selectedDestination = destination
                selectionStore.save(destination, for: user)
            }
        )
    }

    private var navigationPath: Binding<[Route]> {
        // Bind to this section so a departing stack cannot change another section's history.
        let destinationID = destinationID
        return Binding(
            get: { navigationHistories[destinationID, default: NavigationHistory()].path },
            set: { newPath in
                guard self.destinationID == destinationID else { return }
                let oldPath = path
                guard newPath != oldPath else { return }

                if newPath.count < oldPath.count,
                   oldPath.starts(with: newPath) {
                    forwardPath.append(
                        contentsOf: oldPath.dropFirst(newPath.count).reversed()
                    )
                } else {
                    forwardPath.removeAll()
                }
                path = newPath
            }
        )
    }
}

private struct NavigationHistory {
    var path: [Route] = []
    var forwardPath: [Route] = []
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
    case search(String)
    case genre(String)
    case playlist(SoundCloudPlaylist)
    case track(SoundCloudTrack)
    case artist(SoundCloudUser)
    case artistUsers(SoundCloudUser, ArtistUserList)
}

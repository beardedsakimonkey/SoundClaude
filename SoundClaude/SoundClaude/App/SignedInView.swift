import SwiftUI

struct SignedInView: View {
    let user: SoundCloudUser

    @ObservedObject private var model: AppModel
    @State private var selectedDestination: SidebarDestination?
    private let selectionStore = SidebarSelectionStore()
    @State private var path: [Route] = []
    @State private var forwardPath: [Route] = []

    init(user: SoundCloudUser, model: AppModel) {
        self.user = user
        _model = ObservedObject(wrappedValue: model)
        _selectedDestination = State(initialValue: SidebarSelectionStore().restore(for: user))
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView(
                    selection: sidebarSelection,
                    playlists: model.playlists,
                    user: user,
                    artworkLoader: model.artworkLoader,
                    onSelectProfile: showArtist,
                    onSignOut: model.signOut
                )
                    .navigationSplitViewColumnWidth(
                        min: 180,
                        ideal: 220,
                        max: 280
                    )
            } detail: {
                selectedView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            PlayerFooterView(
                model: model,
                onSelectTrack: showTrack,
                onSelectArtist: showArtist
            )
            .fixedSize(horizontal: false, vertical: true)
        }
        .background {
            NavigationBackEventView(
                onBack: navigateBack,
                onForward: navigateForward
            )
        }
    }

    private var selectedView: some View {
        NavigationStack(path: navigationPath) {
            rootView
                .toolbar { navigationToolbar }
                .navigationDestination(for: Route.self) { route in
                    switch route {
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
        }
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
            if !path.isEmpty {
                Button {
                    _ = navigateBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .frame(width: 16, height: 16)
                }
                .help("Go back")
            }

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

    private func showTrack(_ track: SoundCloudTrack) {
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
                path.removeAll()
                forwardPath.removeAll()
                selectedDestination = destination
                selectionStore.save(destination, for: user)
            }
        )
    }

    private var navigationPath: Binding<[Route]> {
        Binding(
            get: { path },
            set: { newPath in
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

struct SidebarView: View {
    @Binding var selection: SidebarDestination?
    @ObservedObject var playlists: PlaylistsController
    let user: SoundCloudUser
    let artworkLoader: ArtworkLoader
    let onSelectProfile: (SoundCloudUser) -> Void
    let onSignOut: () async -> Void

    @State private var isProfileHovered = false

    var body: some View {
        List(selection: $selection) {
            ForEach(SidebarDestination.libraryDestinations) { destination in
                Label(destination.title, systemImage: destination.systemImage)
                    .tag(destination)
            }
            Section("Playlists") {
                ForEach(playlists.playlists) { playlist in
                    Label(playlist.title, systemImage: "music.note.list")
                        .lineLimit(1)
                        .help(playlist.title)
                        .tag(SidebarDestination.playlist(playlist))
                }
                if playlists.isLoading {
                    ProgressView("Loading playlists")
                        .controlSize(.small)
                } else if let errorMessage = playlists.errorMessage {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Try Again") { Task { await playlists.load() } }
                    }
                } else if playlists.playlists.isEmpty {
                    Text("No playlists")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { await playlists.load() }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            accountFooter
        }
        .navigationTitle("SoundClaude")
    }

    private var accountFooter: some View {
        HStack(spacing: 8) {
            Button {
                onSelectProfile(user)
            } label: {
                HStack(spacing: 8) {
                    TrackArtworkView(
                        artworkURL: user.avatarURL,
                        loader: artworkLoader,
                        size: 24
                    )
                    .clipShape(Circle())
                    Text(user.username)
                        .font(.callout.weight(.medium))
                        .underline(isProfileHovered)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isProfileHovered = $0 }
            .help("View profile: \(user.username)")
            .accessibilityLabel("View profile: \(user.username)")

            Menu {
                Button("Log out") {
                    Task { await onSignOut() }
                }
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .padding(12)
    }
}

private enum Route: Hashable {
    case playlist(SoundCloudPlaylist)
    case track(SoundCloudTrack)
    case artist(SoundCloudUser)
    case artistUsers(SoundCloudUser, ArtistUserList)
}

import SwiftUI

struct SignedInView: View {
    let user: SoundCloudUser

    @ObservedObject private var model: AppModel
    @State private var selectedDestination: SidebarDestination? = .liked
    @State private var path: [Route] = []
    @State private var forwardPath: [Route] = []

    init(user: SoundCloudUser, model: AppModel) {
        self.user = user
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView(selection: $selectedDestination)
                    .navigationSplitViewColumnWidth(
                        min: 180,
                        ideal: 220,
                        max: 280
                    )
            } detail: {
                VStack(spacing: 0) {
                    MetalVisualizerView(
                        spectrumBuffer: model.analyzer.spectrumBuffer
                    )
                    .frame(
                        minHeight: 90,
                        idealHeight: 120,
                        maxHeight: 150
                    )

                    Divider()
                    selectedView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
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

    @ViewBuilder
    private var selectedView: some View {
        switch selectedDestination {
        case .home:
            NavigationStack {
                HomeView()
                    .toolbar { navigationToolbar }
            }
        case .liked, .none:
            NavigationStack(path: navigationPath) {
                LikesView(
                    user: user,
                    likes: model.likes,
                    playback: model.playback,
                    artworkLoader: model.artworkLoader,
                    appErrorMessage: model.errorMessage,
                    onSelectArtist: showArtist,
                    onSelectTrack: showTrack,
                    onPlayTrack: model.play,
                    onSignOut: model.signOut
                )
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
                    case let .artist(artist):
                        ArtistDetailView(
                            artist: artist,
                            model: model,
                            onSelectTrack: showTrack,
                            onSelectArtist: showArtist
                        )
                        .id(artist.permalinkURL)
                        .navigationBarBackButtonHidden(true)
                        .toolbar { navigationToolbar }
                    }
                }
            }
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
            if selectedDestination != .home, !path.isEmpty {
                Button {
                    _ = navigateBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .frame(width: 16, height: 16)
                }
                .help("Go back")
            }

            if selectedDestination != .home, !forwardPath.isEmpty {
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
        selectedDestination = .liked
        forwardPath.removeAll()
        path.append(.track(track))
    }

    private func showArtist(_ artist: SoundCloudUser) {
        selectedDestination = .liked
        if case let .artist(current) = path.last,
           current.permalinkURL == artist.permalinkURL { return }
        forwardPath.removeAll()
        path.append(.artist(artist))
    }

    private func navigateBack() -> Bool {
        guard selectedDestination != .home,
              let route = path.popLast() else {
            return false
        }

        forwardPath.append(route)
        return true
    }

    private func navigateForward() -> Bool {
        guard selectedDestination != .home,
              let route = forwardPath.popLast() else {
            return false
        }

        path.append(route)
        return true
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

    var body: some View {
        List(selection: $selection) {
            ForEach(SidebarDestination.allCases) { destination in
                Label(destination.title, systemImage: destination.systemImage)
                    .tag(destination)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("SoundClaude")
    }
}

private enum Route: Hashable {
    case track(SoundCloudTrack)
    case artist(SoundCloudUser)
}

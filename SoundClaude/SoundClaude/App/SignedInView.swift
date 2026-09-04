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
                        minHeight: 180,
                        idealHeight: 240,
                        maxHeight: 300
                    )

                    Divider()
                    selectedView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Divider()
            PlayerFooterView(
                playback: model.playback,
                artworkLoader: model.artworkLoader
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
            }
        case .liked, .none:
            NavigationStack(path: navigationPath) {
                LibraryView(
                    user: user,
                    library: model.library,
                    playback: model.playback,
                    artworkLoader: model.artworkLoader,
                    appErrorMessage: model.errorMessage,
                    onSelectTrack: showTrack,
                    onPlayTrack: model.play,
                    onSignOut: model.signOut
                )
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case let .track(track):
                        TrackDetailView(track: track, model: model)
                    }
                }
            }
        }
    }

    private func showTrack(_ track: SoundCloudTrack) {
        forwardPath.removeAll()
        path.append(.track(track))
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
}

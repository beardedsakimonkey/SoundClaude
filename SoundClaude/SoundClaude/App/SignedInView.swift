import SwiftUI

struct SignedInView: View {
    let user: SoundCloudUser

    @ObservedObject private var model: AppModel
    @State private var selectedDestination: SidebarDestination? = .liked
    @State private var path: [Route] = []

    init(user: SoundCloudUser, model: AppModel) {
        self.user = user
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selectedDestination)
        } detail: {
            VStack(spacing: 0) {
                MetalVisualizerView(
                    spectrumBuffer: model.analyzer.spectrumBuffer
                )
                .frame(minHeight: 180, idealHeight: 240, maxHeight: 300)

                Divider()
                selectedView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                PlayerFooterView(
                    playback: model.playback,
                    artworkLoader: model.artworkLoader
                )
            }
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
            NavigationStack(path: $path) {
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
        path.append(.track(track))
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

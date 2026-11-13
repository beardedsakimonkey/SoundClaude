import SwiftUI

/// SoundCloud's recommendations from soundcloud.com/discover, as shelves for the Search page.
struct SearchDiscover: View {
    let model: AppModel
    /// Stations arrive here as playlists; `isStation` tells them apart.
    let onSelectPlaylist: (SoundCloudPlaylist) -> Void

    @State private var selections: [SoundCloudSelection]?
    @State private var hasFailed = false

    private static let sectionSpacing: CGFloat = 32

    init(model: AppModel, onSelectPlaylist: @escaping (SoundCloudPlaylist) -> Void) {
        self.model = model
        self.onSelectPlaylist = onSelectPlaylist
        // Show a revisited page without waiting a frame for load().
        _selections = State(initialValue: model.cachedDiscoverSelections())
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .task { await load() }
        #if DEBUG
            .debugViewUpdates("SearchDiscover")
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if let selections {
            // Lazy, so that shelves below the window do not load their covers.
            LazyVStack(alignment: .leading, spacing: Self.sectionSpacing) {
                ForEach(selections) { selection in
                    VStack(alignment: .leading, spacing: 16) {
                        Text(selection.title)
                            .font(.sectionHeading)
                            .opacity(0.96)
                            .modifier(FadeInOnAppear())
                        SearchShelf {
                            ForEach(selection.items) { item in
                                SearchPlaylistCard(
                                    playlist: item.playlist, shortTitle: item.shortTitle,
                                    summary: item.summary, artworkLoader: model.artworkLoader
                                ) {
                                    onSelectPlaylist(item.playlist)
                                }
                            }
                        }
                        // Line the first cover up with the section's heading.
                        .padding(.leading, -SearchPlaylistCard.inset)
                    }
                }
            }
        } else if !hasFailed {
            // The recommendations are an extra, so a failure leaves the page without them.
            LoadingSpinner()
                .accessibilityLabel("Loading recommendations")
                .frame(maxWidth: .infinity)
        }
    }

    private func load() async {
        do {
            // Returns the cached rows until they are due a refresh.
            let loaded = try await model.discoverSelections()
            try Task.checkCancellation()
            selections = loaded
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            hasFailed = true
        }
    }
}

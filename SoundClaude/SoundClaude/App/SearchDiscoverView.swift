import SwiftUI

/// SoundCloud's recommendations from soundcloud.com/discover, as shelves for the Search page.
struct SearchDiscover: View {
    let model: AppModel
    /// Stations arrive here as playlists; `isStation` tells them apart.
    let onSelectPlaylist: (SoundCloudPlaylist) -> Void

    @State private var selections: [SoundCloudSelection]?
    @State private var hasFailed = false

    private static let sectionSpacing: CGFloat = 32
    // Speculatively load the covers of the two shelves below the visible ones, and one above.
    private static let prefetchShelfCount = 2

    @State private var coordinator = TrackScrollArtworkPrefetcher(
        rendition: .square500,
        lookahead: prefetchShelfCount,
        lookbehind: 1
    )
    /// How many cards of a shelf fit across the page before it scrolls sideways.
    @State private var cardsPerShelf = 0
    #if DEBUG
    private let prefetchSettings = ArtworkPrefetchDebugSettings.shared
    private var prefetchEnabled: Bool { prefetchSettings.isEnabled }
    #else
    private let prefetchEnabled = true
    #endif

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
            .onGeometryChange(for: Int.self) { geometry in
                let cardWidth = SearchPlaylistCard.artworkSize + 2 * SearchPlaylistCard.inset
                return Int((geometry.size.width / cardWidth).rounded(.up))
            } action: { count in
                cardsPerShelf = count
            }
            .onChange(of: cardsPerShelf) { _, _ in configurePrefetch() }
            .onChange(of: selections?.map(\.id)) { _, _ in configurePrefetch() }
            .onChange(of: prefetchEnabled) { _, _ in configurePrefetch() }
            .onAppear { configurePrefetch() }
            .onDisappear { coordinator.stop(loader: model.artworkLoader) }
        #if DEBUG
            .preference(key: TrackArtworkQueueDebugKey.self, value: [coordinator.prefetcher])
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
                        SearchShelf(
                            itemWidth: SearchPlaylistCard.width,
                            artworkCenterY: SearchPlaylistCard.artworkCenterY
                        ) {
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
                    .onAppear {
                        coordinator.setVisible(selection.id, isVisible: true, loader: model.artworkLoader)
                    }
                    .onDisappear {
                        coordinator.setVisible(selection.id, isVisible: false, loader: model.artworkLoader)
                    }
                }
            }
        } else if !hasFailed {
            // The recommendations are an extra, so a failure leaves the page without them.
            Color.clear
                .frame(height: 1)
                .frame(maxWidth: .infinity)
        }
    }

    // Only the cards that fit across the page: the rest of a shelf is off to the side.
    private func configurePrefetch() {
        let selections = selections ?? []
        coordinator.configure(
            ids: selections.map(\.id),
            urlGroups: selections.map { selection in
                selection.items.prefix(cardsPerShelf).compactMap {
                    $0.playlist.artworkURL ?? $0.playlist.owner.avatarURL
                }
            },
            loader: model.artworkLoader, isEnabled: prefetchEnabled
        )
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

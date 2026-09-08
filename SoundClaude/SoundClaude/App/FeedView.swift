import SwiftUI

struct FeedView: View {
    @ObservedObject var model: AppModel
    let onSelectPlaylist: (SoundCloudPlaylist) -> Void
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void

    @State private var items: [SoundCloudFeedItem] = []
    @State private var nextPageURL: URL?
    @State private var loadedPageURLs: Set<URL> = []
    @State private var hasLoaded = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if !hasLoaded, errorMessage == nil {
                ProgressView("Loading feed")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task { await loadPage() }
            } else {
                feedContent
            }
        }
        .navigationTitle("Feed")
    }

    private var feedContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                Text("Feed")
                    .font(.title.weight(.semibold))

                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 5) {
                            ArtistLink(
                                artist: item.user,
                                artworkLoader: model.artworkLoader,
                                onSelect: onSelectArtist
                            )
                            .fontWeight(.semibold)
                            .layoutPriority(1)
                            Group {
                                if item.isRepost {
                                    Image(systemName: "repeat")
                                        .accessibilityHidden(true)
                                }
                                Text(activityLabel(for: item))
                                    .fixedSize()
                                TimelineView(.periodic(from: .now, by: 60)) { context in
                                    Text(relativeTime(for: item.createdAt, now: context.date))
                                }
                                .fixedSize()
                            }
                            .foregroundStyle(.tertiary)
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 8)

                        switch item.content {
                        case let .track(track):
                            TrackCardView(
                                track: track,
                                model: model,
                                onSelectTrack: onSelectTrack,
                                onSelectArtist: onSelectArtist,
                                onPlayTrack: { track in
                                    await model.play(track, queue: TrackQueue(
                                        source: .feed,
                                        tracks: items.compactMap(\.content.track),
                                        nextPageURL: nextPageURL
                                    ))
                                }
                            )
                        case let .playlist(playlist):
                            PlaylistCardView(
                                playlist: playlist,
                                model: model,
                                playlists: model.playlists,
                                onSelectPlaylist: onSelectPlaylist,
                                onSelectTrack: onSelectTrack,
                                onSelectArtist: onSelectArtist
                            )
                        }
                    }
                }

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.secondary)
                    Button("Try Again") { Task { await loadPage() } }
                        .disabled(isLoading)
                }
                if !hasLoaded || nextPageURL != nil {
                    if errorMessage == nil {
                        ProgressView("Loading feed")
                            .frame(maxWidth: .infinity)
                            .task(id: nextPageURL) { await loadPage() }
                    }
                } else if items.isEmpty, errorMessage == nil {
                    ContentUnavailableView(
                        "Your feed is empty",
                        systemImage: "music.note",
                        description: Text("Tracks and playlists posted or reposted by people you follow will appear here.")
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(20)
        }
    }

    private func activityLabel(for item: SoundCloudFeedItem) -> String {
        switch item.content {
        case .track: item.isRepost ? "reposted a track" : "posted a track"
        case .playlist: item.isRepost ? "reposted a playlist" : "posted a playlist"
        }
    }

    private func relativeTime(for date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(for: min(date, now.addingTimeInterval(-1)), relativeTo: now)
    }

    private func loadPage() async {
        guard !isLoading, !hasLoaded || nextPageURL != nil else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let pageURL = nextPageURL
            let page = try await model.feed(pageURL: pageURL)
            try Task.checkCancellation()
            if let nextURL = page.nextURL,
               nextURL == pageURL || loadedPageURLs.contains(nextURL) {
                throw SoundCloudError.invalidData
            }
            var knownIDs = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { knownIDs.insert($0.id).inserted })
            if let pageURL { loadedPageURLs.insert(pageURL) }
            nextPageURL = page.nextURL
            hasLoaded = true
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}

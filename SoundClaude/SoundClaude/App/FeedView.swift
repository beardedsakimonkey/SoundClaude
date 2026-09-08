import SwiftUI

struct FeedView: View {
    @ObservedObject var model: AppModel
    let onSelectPlaylist: (SoundCloudPlaylist) -> Void
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void

    @ObservedObject var feed: FeedController

    private var items: [SoundCloudFeedItem] { feed.cache.items }
    private var nextPageURL: URL? { feed.cache.nextPageURL }

    var body: some View {
        Group {
            if !feed.cache.hasLoadedPage, feed.errorMessage == nil {
                ProgressView("Loading feed")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                feedContent
            }
        }
        .navigationTitle("Feed")
        .task { await feed.load() }
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

                if let errorMessage = feed.errorMessage {
                    Text(errorMessage).foregroundStyle(.secondary)
                    Button("Try Again") { Task { await feed.retry() } }
                        .disabled(feed.isLoading)
                }
                if feed.isLoading {
                    ProgressView("Loading feed")
                        .frame(maxWidth: .infinity)
                } else if nextPageURL != nil, feed.errorMessage == nil {
                    ProgressView("Loading feed")
                        .frame(maxWidth: .infinity)
                        .task(id: nextPageURL) { await feed.loadMore() }
                } else if items.isEmpty, feed.errorMessage == nil {
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
}

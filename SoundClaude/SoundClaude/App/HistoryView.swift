import SwiftUI

struct HistoryView: View {
    let model: AppModel
    @Binding var searchText: String
    let isActive: Bool
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void

    @AppStorage("historyTrackLayout") private var trackLayout = TrackLayout.list
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var tracks: [SoundCloudTrack] { model.historyTracks }

    var body: some View {
        ZStack(alignment: .top) {
            RouteGradientBackdrop()

            historyContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("History")
        #if DEBUG
        .debugViewUpdates("HistoryView")
        #endif
    }

    private var historyContent: some View {
        let filteredTracks = tracks.filtered(by: searchText)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("History")
                        .font(.largeTitle.weight(.semibold))

                    Spacer()

                    TrackFilterField(
                        text: $searchText,
                        isActive: isActive,
                        accessibilityLabel: "Search listening history"
                    )
                    .frame(maxWidth: 200)
                    .padding(.leading, 8)

                    TrackLayoutPicker(trackLayout: $trackLayout)
                }

                trackList(tracks: filteredTracks)
                    .animation(
                        reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85),
                        value: tracks.map(\.id)
                    )

                if filteredTracks.isEmpty {
                    EmptyStateView(tracks.isEmpty ? "No listening history" : "No matching tracks")
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(20)
            .scrollKeyNavigation()
        }
    }

    @ViewBuilder
    private func trackList(tracks: [SoundCloudTrack]) -> some View {
        if trackLayout == .grid {
            TrackArtworkGrid(tracks: tracks, loader: model.artworkLoader) { track in
                TrackGridTile(
                    track: track,
                    playback: model.playback,
                    analyzer: model.analyzer,
                    artworkLoader: model.artworkLoader,
                    likes: model.likes,
                    onAddToQueue: model.addToQueue,
                    onSelectTrack: onSelectTrack,
                    onSelectArtist: onSelectArtist,
                    onPlayTrack: play
                )
            }
        } else {
            TrackArtworkList(tracks: tracks, loader: model.artworkLoader) { track in
                TrackListRow(
                    track: track,
                    playback: model.playback,
                    analyzer: model.analyzer,
                    artworkLoader: model.artworkLoader,
                    likes: model.likes,
                    onAddToQueue: model.addToQueue,
                    onSelectTrack: onSelectTrack,
                    onSelectArtist: onSelectArtist,
                    onPlayTrack: play
                )
            }
        }
    }

    private func play(_ track: SoundCloudTrack) async {
        await model.play(track, queue: TrackQueue(
            source: .history,
            tracks: tracks
        ))
    }
}

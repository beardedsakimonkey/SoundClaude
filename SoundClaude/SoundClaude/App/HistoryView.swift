import SwiftUI

struct HistoryView: View {
    @ObservedObject var model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void

    @AppStorage("historyTrackLayout") private var trackLayout = TrackLayout.list
    private var tracks: [SoundCloudTrack] { model.historyTracks }

    var body: some View {
        ZStack(alignment: .top) {
            RouteGradientBackdrop()

            historyContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("History")
    }

    private var historyContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("History")
                        .font(.largeTitle.weight(.semibold))

                    Spacer()

                    TrackLayoutPicker(trackLayout: $trackLayout)
                }

                trackList

                if tracks.isEmpty {
                    EmptyStateView("No listening history")
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private var trackList: some View {
        if trackLayout == .grid {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 160), spacing: 20, alignment: .top)],
                alignment: .leading,
                spacing: 24
            ) {
                ForEach(tracks) { track in
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
            }
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(tracks) { track in
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
    }

    private func play(_ track: SoundCloudTrack) async {
        await model.play(track, queue: TrackQueue(
            source: .history,
            tracks: tracks
        ))
    }
}

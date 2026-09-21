import SwiftUI

struct HistoryView: View {
    @ObservedObject var model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void

    @AppStorage("historyTrackLayout") private var trackLayout = TrackLayout.list
    @State private var tracks: [SoundCloudTrack] = []
    @State private var hasLoaded = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var reloadID = UUID()

    var body: some View {
        ZStack(alignment: .top) {
            RouteGradientBackdrop()

            historyContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("History")
        .task(id: reloadID) { await load() }
    }

    private var historyContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("History")
                        .font(.largeTitle.weight(.semibold))

                    Spacer()

                    TrackLayoutPicker(trackLayout: $trackLayout)

                    RefreshButton(title: "Refresh history", isLoading: isLoading) {
                        reloadID = UUID()
                    }
                }

                trackList

                if isLoading || (!hasLoaded && errorMessage == nil) {
                    ProgressView()
                        .accessibilityLabel("Loading history")
                        .frame(maxWidth: .infinity)
                } else if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                    Button("Try Again") { reloadID = UUID() }
                } else if tracks.isEmpty {
                    ContentUnavailableView(
                        "No listening history",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Recently played tracks available for playback will appear here.")
                    )
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

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let loadedTracks = try await model.recentlyPlayedTracks()
            try Task.checkCancellation()
            tracks = loadedTracks
            hasLoaded = true
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            errorMessage = error.localizedDescription
        }
    }
}

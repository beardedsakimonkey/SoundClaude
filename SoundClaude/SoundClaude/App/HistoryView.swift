import SwiftUI

struct HistoryView: View {
    @ObservedObject var model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void

    @State private var tracks: [SoundCloudTrack] = []
    @State private var hasLoaded = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var reloadID = UUID()

    var body: some View {
        ZStack(alignment: .top) {
            if !hasLoaded, errorMessage == nil {
                ProgressView("Loading history")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                historyContent
            }
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

                    RefreshButton(title: "Refresh history", isLoading: isLoading) {
                        reloadID = UUID()
                    }
                }

                ForEach(tracks) { track in
                    TrackCardView(
                        track: track,
                        model: model,
                        onSelectTrack: onSelectTrack,
                        onSelectArtist: onSelectArtist,
                        onPlayTrack: { track in
                            await model.play(track, queue: TrackQueue(
                                source: .history,
                                tracks: tracks
                            ))
                        }
                    )
                }

                if isLoading {
                    ProgressView("Loading history")
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

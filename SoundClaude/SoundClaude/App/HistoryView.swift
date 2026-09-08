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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                Text("Your last 25 recently played tracks, newest first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

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

                if isLoading || (!hasLoaded && errorMessage == nil) {
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
        .navigationTitle("History")
        .toolbar {
            ToolbarItem {
                Button {
                    reloadID = UUID()
                } label: {
                    Label("Refresh History", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
                .help("Refresh history")
            }
        }
        .task(id: reloadID) { await load() }
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

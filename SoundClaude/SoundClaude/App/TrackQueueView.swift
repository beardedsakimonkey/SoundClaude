import SwiftUI

struct TrackQueueView: View {
    @ObservedObject var model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void

    @ObservedObject private var likes: LikesController
    @Environment(\.dismiss) private var dismiss

    init(
        model: AppModel,
        onSelectTrack: @escaping (SoundCloudTrack) -> Void,
        onSelectArtist: @escaping (SoundCloudUser) -> Void
    ) {
        self.model = model
        self.onSelectTrack = onSelectTrack
        self.onSelectArtist = onSelectArtist
        _likes = ObservedObject(wrappedValue: model.likes)
    }

    private var tracks: [SoundCloudTrack] {
        model.queue.source == .likes ? likes.tracks : model.queue.tracks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Track Queue")
                Text("(\(tracks.count))")
                    .foregroundStyle(.secondary)
                    .fontWeight(.regular)
            }
            .font(.title2.weight(.semibold))

            if tracks.isEmpty {
                ContentUnavailableView(
                    "The queue is empty",
                    systemImage: "music.note.list",
                    description: Text("Play a track to start a queue.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(tracks) { track in
                                TrackListRow(
                                    track: track,
                                    playback: model.playback,
                                    artworkLoader: model.artworkLoader,
                                    onSelectTrack: { selected in
                                        dismiss()
                                        onSelectTrack(selected)
                                    },
                                    onSelectArtist: { artist in
                                        dismiss()
                                        onSelectArtist(artist)
                                    },
                                    onPlayTrack: { await model.play($0) }
                                )
                                .id(track.urn)
                            }
                        }
                    }
                    .onAppear {
                        if let urn = model.playback.currentTrack?.urn {
                            proxy.scrollTo(urn, anchor: .center)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut("q", modifiers: [])
            }
        }
        .padding(24)
        .frame(width: 560, height: 520)
        .onExitCommand { dismiss() }
        .dismissOnOutsideClick()
    }
}

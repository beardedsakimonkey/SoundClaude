import SwiftUI

struct TrackQueueView: View {
    @ObservedObject var model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    let onDismiss: () -> Void

    @ObservedObject private var likes: LikesController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        model: AppModel,
        onSelectTrack: @escaping (SoundCloudTrack) -> Void,
        onSelectArtist: @escaping (SoundCloudUser) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.model = model
        self.onSelectTrack = onSelectTrack
        self.onSelectArtist = onSelectArtist
        self.onDismiss = onDismiss
        _likes = ObservedObject(wrappedValue: model.likes)
    }

    private var tracks: [SoundCloudTrack] {
        model.queue.resolvedTracks(likes: likes.tracks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "music.note.list")
                        .accessibilityHidden(true)
                    Text("Track Queue")
                    Text("(\(tracks.count))")
                        .foregroundStyle(.secondary)
                        .fontWeight(.regular)
                }
                .font(.title2.weight(.semibold))

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close track queue (Esc)")
                .accessibilityLabel("Close track queue")
            }

            if tracks.isEmpty {
                ContentUnavailableView(
                    "The queue is empty",
                    systemImage: "music.note.list",
                    description: Text("Play a track to start a queue.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(tracks) { track in
                            HStack(spacing: 0) {
                                Image(systemName: "line.3.horizontal")
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 28, height: 56)
                                    .contentShape(Rectangle())
                                    .help("Drag to reorder")
                                    .accessibilityLabel("Reorder \(track.title)")
                                TrackListRow(
                                    track: track,
                                    playback: model.playback,
                                    artworkLoader: model.artworkLoader,
                                    onSelectTrack: { selected in
                                        onDismiss()
                                        onSelectTrack(selected)
                                    },
                                    onSelectArtist: { artist in
                                        onDismiss()
                                        onSelectArtist(artist)
                                    },
                                    onPlayTrack: { await model.play($0) }
                                )
                            }
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .id(track.urn)
                        }
                        .onMove(perform: model.moveQueueTracks)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .animation(
                        reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85),
                        value: tracks.map(\.urn)
                    )
                    .onAppear {
                        if let urn = model.playback.currentTrack?.urn {
                            proxy.scrollTo(urn, anchor: .center)
                        }
                    }
                }
            }
        }
        .padding(16)
        .onExitCommand(perform: onDismiss)
    }
}

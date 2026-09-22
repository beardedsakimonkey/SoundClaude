import SwiftUI

struct TrackQueueView: View {
    @ObservedObject var model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    let onDismiss: () -> Void

    @ObservedObject private var likes: LikesController

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
                    Text("Track Queue")
                    Text("(\(tracks.count))")
                        .foregroundStyle(.secondary)
                        .fontWeight(.regular)
                }
                .font(.title2.weight(.semibold))

                Spacer()

                if !tracks.isEmpty {
                    QueueClearButton(action: model.clearQueue)
                }

                QueueCloseButton(action: onDismiss)
            }

            if tracks.isEmpty {
                EmptyStateView("The queue is empty")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TrackQueueList(
                    tracks: tracks,
                    currentTrackURN: model.playback.currentTrack?.urn,
                    onMove: model.moveQueueTracks,
                    onDismiss: onDismiss
                ) { track in
                    TrackListRow(
                        track: track,
                        playback: model.playback,
                        analyzer: model.analyzer,
                        artworkLoader: model.artworkLoader,
                        likes: model.likes,
                        onRemoveFromQueue: model.removeFromQueue,
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
            }
        }
        .padding(16)
        .onExitCommand(perform: onDismiss)
    }
}

private struct QueueClearButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text("Clear")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(isHovered ? 0.08 : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .onDisappear { isHovered = false }
        .help("Clear track queue")
        .accessibilityLabel("Clear track queue")
    }
}

private struct QueueCloseButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background {
                    Circle()
                        .fill(Color.primary.opacity(isHovered ? 0.08 : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .onDisappear { isHovered = false }
        .keyboardShortcut(.cancelAction)
        .help("Close track queue (Esc)")
        .accessibilityLabel("Close track queue")
    }
}

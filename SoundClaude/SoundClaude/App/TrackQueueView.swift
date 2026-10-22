import SwiftUI

struct TrackQueueView: View {
    let model: AppModel
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
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Track Queue")
                    Text("(\(tracks.count))")
                        .foregroundStyle(.secondary)
                        .fontWeight(.regular)
                }
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

                if !tracks.isEmpty {
                    QueueClearButton(action: model.clearQueue)
                }

                QueueCloseButton(action: onDismiss)
            }
            .padding(16)

            Group {
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
                        QueueTrackRow(
                            track: track,
                            model: model,
                            onSelectTrack: onSelectTrack,
                            onSelectArtist: onSelectArtist,
                            onDismiss: onDismiss
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .onExitCommand(perform: onDismiss)
        #if DEBUG
        .debugViewUpdates("TrackQueueView")
        #endif
    }
}

// Keep row actions independent of the queue array and drag layout state.
// Removing or moving another track must not change this row's inputs.
private struct QueueTrackRow: View {
    let track: SoundCloudTrack
    let model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    let onDismiss: () -> Void

    var body: some View {
        TrackListRow(
            track: track,
            playback: model.playback,
            analyzer: model.analyzer,
            artworkLoader: model.artworkLoader,
            likes: model.likes,
            showsDuration: false,
            showsLikes: false,
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
        .onContentHover { isHovered = $0 }
        .onDisappear { isHovered = false }
        .contentHelp("Clear track queue")
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
        .onContentHover { isHovered = $0 }
        .onDisappear { isHovered = false }
        .keyboardShortcut(.cancelAction)
        .contentHelp("Close track queue (Esc)")
        .accessibilityLabel("Close track queue")
    }
}

import SwiftUI

struct TrackQueueView: View {
    let model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    let onSelectSource: () -> Void
    let onDismiss: () -> Void

    private let likes: LikesController

    init(
        model: AppModel,
        onSelectTrack: @escaping (SoundCloudTrack) -> Void,
        onSelectArtist: @escaping (SoundCloudUser) -> Void,
        onSelectSource: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.model = model
        self.onSelectTrack = onSelectTrack
        self.onSelectArtist = onSelectArtist
        self.onSelectSource = onSelectSource
        self.onDismiss = onDismiss
        self.likes = model.likes
    }

    private var tracks: [SoundCloudTrack] {
        model.queue.source == .likes
            ? model.queue.resolvedTracks(likes: likes.tracks)
            : model.queue.playbackTracks
    }

    private var canClear: Bool {
        tracks.contains { $0.urn != model.playback.currentTrack?.urn }
    }

    private var sourceLabel: QueueSourceLabel? {
        guard !tracks.isEmpty else { return nil }
        return QueueSourceLabel(queue: model.queue, playlistTitle: model.queuePlaylist?.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Queue")
                        Text("(\(tracks.count))")
                            .foregroundStyle(.secondary)
                            .fontWeight(.regular)
                    }
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if canClear {
                        QueueClearButton(action: model.clearQueue)
                    }

                    QueueCloseButton(action: onDismiss)
                }

                if let sourceLabel {
                    HStack(spacing: 6) {
                        Text("Playing from")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        QueueSourceButton(label: sourceLabel, action: onSelectSource)
                            .id(sourceLabel.title)
                    }
                    .padding(.top, 8)
                }
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
            showsMetadata: false,
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

struct QueueSourceLabel {
    let title: String
    let systemImage: String
    // Queues saved before source tracks and artists were recorded cannot open their source.
    let isNavigable: Bool

    init?(queue: TrackQueue, playlistTitle: String?) {
        switch queue.source {
        case .single:
            return nil
        case .feed:
            self.init(destination: .feed)
        case .likes:
            self.init(destination: .liked)
        case .history:
            self.init(destination: .history)
        case let .search(query):
            self.init(title: "“\(query)”", systemImage: "magnifyingglass")
        case let .genre(genre):
            self.init(title: genre, systemImage: "guitars")
        case let .tag(tag):
            self.init(title: "#\(tag)", systemImage: "number")
        case .playlist:
            self.init(title: playlistTitle ?? "Playlist", systemImage: "music.note.list")
        case .station:
            self.init(title: queue.sourceTitle ?? "Station", systemImage: "dot.radiowaves.left.and.right")
        case .related:
            let title = queue.sourceTrack.map { "Related to \($0.title)" } ?? "Related tracks"
            self.init(title: title, systemImage: "sparkles", isNavigable: queue.sourceTrack != nil)
        case .artist:
            self.init(artist: queue.sourceArtist, tab: nil)
        case .artistReposts:
            self.init(artist: queue.sourceArtist, tab: "Reposts")
        case .artistLikes:
            self.init(artist: queue.sourceArtist, tab: "Likes")
        }
    }

    private init(title: String, systemImage: String, isNavigable: Bool = true) {
        self.title = title
        self.systemImage = systemImage
        self.isNavigable = isNavigable
    }

    private init(destination: SidebarDestination) {
        self.init(title: destination.title, systemImage: destination.systemImage)
    }

    private init(artist: SoundCloudUser?, tab: String?) {
        let name = artist?.username ?? "Artist"
        self.init(
            title: tab.map { "\(name) · \($0)" } ?? name,
            systemImage: "person",
            isNavigable: artist != nil
        )
    }
}

private struct QueueSourceButton: View {
    let label: QueueSourceLabel
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: label.systemImage)
                Text(label.title)
                    .underline(isHovered && label.isNavigable)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!label.isNavigable)
        .onContentHover { isHovered = $0 }
        .onDisappear { isHovered = false }
        .contentHelp("Playing from \(label.title)")
        .accessibilityLabel("Playing from \(label.title)")
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

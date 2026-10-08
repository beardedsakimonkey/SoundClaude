import SwiftUI

extension View {
    func trackContextMenu(
        track: SoundCloudTrack?,
        likes: LikesController,
        onAddToQueue: @escaping (SoundCloudTrack) -> Void
    ) -> some View {
        modifier(TrackContextMenu(track: track, likes: likes, onAddToQueue: onAddToQueue))
    }
}

private struct TrackContextMenu: ViewModifier {
    let track: SoundCloudTrack?
    let likes: LikesController
    let onAddToQueue: (SoundCloudTrack) -> Void

    @State private var likeErrorMessage: String?

    func body(content: Content) -> some View {
        content
            .contextMenu {
                if let track {
                    TrackMenuItems(
                        track: track,
                        likes: likes,
                        likeErrorMessage: $likeErrorMessage,
                        onAddToQueue: onAddToQueue
                    )
                }
            }
            .alert("Could not update like", isPresented: Binding(
                get: { likeErrorMessage != nil },
                set: { if !$0 { likeErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { likeErrorMessage = nil }
            } message: {
                Text(likeErrorMessage ?? "Please try again.")
            }
    }
}

struct TrackMenuItems: View {
    let track: SoundCloudTrack
    @ObservedObject var likes: LikesController
    @Binding var likeErrorMessage: String?
    var onAddToQueue: ((SoundCloudTrack) -> Void)? = nil
    var onRemoveFromQueue: ((SoundCloudTrack) -> Void)? = nil
    var onRemoveFromPlaylist: ((SoundCloudTrack) -> Void)? = nil
    var isUpdatingPlaylist = false

    @Environment(\.addToPlaylist) private var addToPlaylist

    var body: some View {
        let isLiked = likes.isLiked(track)

        if let onRemoveFromQueue {
            Button("Remove from queue", systemImage: "text.badge.minus") {
                onRemoveFromQueue(track)
            }
        } else if let onAddToQueue {
            Button("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                onAddToQueue(track)
            }
        }
        if let onRemoveFromPlaylist {
            Button("Remove from playlist", systemImage: "text.badge.minus", role: .destructive) {
                onRemoveFromPlaylist(track)
            }
            .disabled(isUpdatingPlaylist)
        }
        Button("Add to playlist", systemImage: "text.badge.plus") {
            addToPlaylist(track)
        }
        Button(isLiked ? "Unlike" : "Like", systemImage: isLiked ? "heart.fill" : "heart") {
            Task {
                do {
                    try await likes.toggleLike(track)
                } catch is CancellationError {
                } catch {
                    likeErrorMessage = error.localizedDescription
                }
            }
        }
        .disabled(likes.updatingTrackURNs.contains(track.urn))
    }
}

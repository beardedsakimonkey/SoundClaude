import SwiftUI

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

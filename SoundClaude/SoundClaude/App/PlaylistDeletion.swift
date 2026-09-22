import SwiftUI

struct PlaylistDeletionState {
    var pendingPlaylist: SoundCloudPlaylist?
    var deletingURNs: Set<String> = []
    var errorMessage: String?
}

struct DeletePlaylistButton: View {
    let playlist: SoundCloudPlaylist
    @Binding var state: PlaylistDeletionState

    var body: some View {
        Button("Delete Playlist…", systemImage: "trash", role: .destructive) {
            state.pendingPlaylist = playlist
        }
        .disabled(state.deletingURNs.contains(playlist.urn))
    }
}

// Attach to the containing view so dialogs remain visible after a menu closes.
struct PlaylistDeletionModifier: ViewModifier {
    @Binding var state: PlaylistDeletionState
    let playlists: PlaylistsController
    let onDeleted: (SoundCloudPlaylist) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Delete \(state.pendingPlaylist?.title ?? "playlist")?",
                isPresented: Binding(
                    get: { state.pendingPlaylist != nil },
                    set: { if !$0 { state.pendingPlaylist = nil } }
                ),
                titleVisibility: .visible,
                presenting: state.pendingPlaylist
            ) { playlist in
                Button("Delete Playlist", role: .destructive) {
                    delete(playlist)
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This will permanently delete the playlist from SoundCloud.")
            }
            .alert("Could not delete playlist", isPresented: Binding(
                get: { state.errorMessage != nil },
                set: { if !$0 { state.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { state.errorMessage = nil }
            } message: {
                Text(state.errorMessage ?? "Please try again.")
            }
    }

    private func delete(_ playlist: SoundCloudPlaylist) {
        guard state.deletingURNs.insert(playlist.urn).inserted else { return }
        Task { @MainActor in
            defer { state.deletingURNs.remove(playlist.urn) }
            do {
                try await playlists.deletePlaylist(playlist)
                onDeleted(playlist)
            } catch is CancellationError {
            } catch {
                state.errorMessage = "\(playlist.title): \(error.localizedDescription)"
            }
        }
    }
}

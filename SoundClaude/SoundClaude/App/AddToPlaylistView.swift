import SwiftUI

private struct AddToPlaylistKey: EnvironmentKey {
    static let defaultValue: (SoundCloudTrack) -> Void = { _ in }
}

extension EnvironmentValues {
    var addToPlaylist: (SoundCloudTrack) -> Void {
        get { self[AddToPlaylistKey.self] }
        set { self[AddToPlaylistKey.self] = newValue }
    }
}

struct AddToPlaylistView: View {
    let track: SoundCloudTrack
    let user: SoundCloudUser
    @ObservedObject var playlists: PlaylistsController
    let artworkLoader: ArtworkLoader
    @Environment(\.dismiss) private var dismiss
    @State private var selectedURN: String?
    @State private var isAdding = false
    @State private var errorMessage: String?

    private var ownedPlaylists: [SoundCloudPlaylist] {
        playlists.playlists.filter {
            ($0.owner.urn == user.urn && user.urn != nil)
                || $0.owner.permalinkURL == user.permalinkURL
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add to playlist").font(.title2.bold())
            Text(track.title).foregroundStyle(.secondary).lineLimit(2)
            List(ownedPlaylists, selection: $selectedURN) { playlist in
                HStack(spacing: 10) {
                    TrackArtworkView(
                        artworkURL: artworkURL(for: playlist),
                        loader: artworkLoader,
                        size: 36
                    )
                    Text(playlist.title)
                        .lineLimit(2)
                    Spacer()
                    if playlist.isPrivate {
                        Image(systemName: "lock")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Private playlist")
                    }
                }
                .padding(.vertical, 2)
                .tag(playlist.urn)
            }
            .overlay {
                if ownedPlaylists.isEmpty {
                    if playlists.isLoading {
                        ProgressView()
                    } else {
                        Text("No playlists. Create a playlist in the sidebar first.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                }
            }
            .disabled(isAdding)
            if let message = errorMessage ?? playlists.errorMessage {
                Text(message).foregroundStyle(.red).font(.callout)
                Button("Reload playlists") { Task { await playlists.load() } }
                    .disabled(isAdding || playlists.isLoading)
            }
            HStack {
                if isAdding { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isAdding)
                Button("Add") {
                    guard let playlist = ownedPlaylists.first(where: { $0.urn == selectedURN }) else { return }
                    isAdding = true
                    errorMessage = nil
                    Task { @MainActor in
                        defer { isAdding = false }
                        do {
                            try await playlists.addTrack(track, to: playlist)
                            dismiss()
                        } catch is CancellationError {
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isAdding || selectedURN == nil)
            }
        }
        .padding(24)
        .frame(width: 420, height: 380)
        .interactiveDismissDisabled(isAdding)
        .task { await playlists.load() }
    }

    private func artworkURL(for playlist: SoundCloudPlaylist) -> URL? {
        let contents = playlists.cache.contents[playlist.urn]
        return (contents?.playlist ?? playlist).artworkURL
            ?? contents?.tracks.first(where: { $0.displayArtworkURL != nil })?.displayArtworkURL
    }
}

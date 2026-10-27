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
    @State private var memberships: [String: Bool] = [:]
    @State private var failedURNs: Set<String> = []
    @State private var updatingURNs: Set<String> = []
    @State private var errorMessage: String?

    private var ownedPlaylists: [SoundCloudPlaylist] {
        playlists.playlists.filter {
            ($0.owner.urn == user.urn && user.urn != nil)
                || $0.owner.permalinkURL == user.permalinkURL
        }
    }

    var body: some View {
        let ownedPlaylists = ownedPlaylists
        VStack(alignment: .leading, spacing: 16) {
            Text("Add to playlist").font(.title2.bold())
            trackHeader
            CountedSectionHeader(
                title: "Playlists",
                count: ownedPlaylists.isEmpty && playlists.isLoading ? nil : ownedPlaylists.count
            )
            ScrollView {
                LazyVStack(spacing: Self.rowSpacing) {
                    ForEach(ownedPlaylists) { playlist in
                        PlaylistToggleRow(
                            playlist: playlist,
                            artworkURL: playlists.artworkURL(for: playlist),
                            trackCount: playlist.trackCount
                                ?? playlists.cache.contents[playlist.urn]?.tracks.count,
                            artworkLoader: artworkLoader,
                            isMember: memberships[playlist.urn],
                            isUpdating: updatingURNs.contains(playlist.urn),
                            hasError: failedURNs.contains(playlist.urn)
                        ) {
                            toggle(playlist)
                        }
                        .task(id: playlist.urn) { await playlists.loadArtwork(for: playlist) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .frame(height: listHeight(rowCount: ownedPlaylists.count))
            .overlay {
                if ownedPlaylists.isEmpty {
                    if playlists.isLoading {
                        LoadingSpinner()
                    } else {
                        Text("No playlists. Create a playlist in the sidebar first.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                }
            }
            if let message = errorMessage ?? playlists.errorMessage {
                VStack(spacing: 8) {
                    Text(message)
                        .foregroundStyle(.red)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                    if errorMessage == nil {
                        Button("Reload playlists") { Task { await playlists.load() } }
                            .disabled(playlists.isLoading)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled(!updatingURNs.isEmpty)
        .dismissOnOutsideClick(isEnabled: updatingURNs.isEmpty)
        .task { await playlists.load() }
        .task(id: ownedPlaylists.map(\.urn)) { await loadMemberships() }
    }

    private static let rowSpacing: CGFloat = 2

    /// Size the list from row count so short libraries shrink the sheet; long ones scroll.
    private func listHeight(rowCount: Int) -> CGFloat {
        guard rowCount > 0 else { return 120 }
        let height = CGFloat(rowCount) * PlaylistToggleRow.height + CGFloat(rowCount - 1) * Self.rowSpacing
        // Show half of the next row as a cue that the list scrolls.
        return min(height, 6.5 * (PlaylistToggleRow.height + Self.rowSpacing))
    }

    private var trackHeader: some View {
        HStack(spacing: 12) {
            TrackArtworkView(
                artworkURL: track.displayArtworkURL,
                loader: artworkLoader,
                size: 32
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .opacity(0.95)
                Text(track.artist.username)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
        .opacity(track.access == .protected ? protectedTrackOpacity : 1)
        .accessibilityElement(children: .combine)
    }

    /// Check a few playlists at a time so large libraries do not flood the API.
    private func loadMemberships() async {
        var pending = ownedPlaylists.filter {
            memberships[$0.urn] == nil && !failedURNs.contains($0.urn)
        }[...]
        let controller = playlists
        let track = track
        await withTaskGroup(of: (String, Bool?).self) { group in
            func addNext() {
                guard !Task.isCancelled, let playlist = pending.popFirst() else { return }
                group.addTask {
                    (playlist.urn, try? await controller.contains(track, in: playlist))
                }
            }
            for _ in 0..<3 { addNext() }
            for await (urn, isMember) in group {
                if let isMember {
                    if memberships[urn] == nil { memberships[urn] = isMember }
                } else if !Task.isCancelled {
                    failedURNs.insert(urn)
                }
                addNext()
            }
        }
    }

    private func toggle(_ playlist: SoundCloudPlaylist) {
        let urn = playlist.urn
        if failedURNs.contains(urn) {
            failedURNs.remove(urn)
            Task { await loadMemberships() }
            return
        }
        guard let isMember = memberships[urn], updatingURNs.insert(urn).inserted else { return }
        memberships[urn] = !isMember
        errorMessage = nil
        Task { @MainActor in
            defer { updatingURNs.remove(urn) }
            do {
                if isMember {
                    try await playlists.removeTrack(track, from: playlist)
                } else {
                    try await playlists.addTrack(track, to: playlist)
                }
            } catch is CancellationError {
            } catch {
                memberships[urn] = isMember
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct PlaylistToggleRow: View {
    let playlist: SoundCloudPlaylist
    let artworkURL: URL?
    let trackCount: Int?
    let artworkLoader: ArtworkLoader
    let isMember: Bool?
    let isUpdating: Bool
    let hasError: Bool
    let action: () -> Void

    static let height: CGFloat = 52

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                TrackArtworkView(
                    artworkURL: artworkURL,
                    loader: artworkLoader,
                    size: 44
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.title)
                        .opacity(0.95)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                indicator
                    .frame(width: 20, height: 20)
            }
            .frame(height: Self.height)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(isHovering && isEnabled ? 0.06 : 0))
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onContentHover { isHovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([playlist.title, subtitle].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityValue(isMember == true ? "Added" : "Not added")
        .accessibilityAddTraits(.isToggle)
    }

    private var isEnabled: Bool { (isMember != nil || hasError) && !isUpdating }

    private var subtitle: String {
        [
            trackCount.map { "\($0.formatted()) \($0 == 1 ? "track" : "tracks")" },
            playlist.isPrivate ? "Private" : nil,
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    @ViewBuilder
    private var indicator: some View {
        if hasError {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .contentHelp("Could not check this playlist. Click to retry.")
        } else if let isMember {
            Image(systemName: isMember ? "checkmark.square.fill" : "square")
                .font(.system(size: 16))
                .foregroundStyle(isMember ? Color.accentColor : Color.secondary)
                .opacity(isUpdating ? 0.5 : 1)
        } else {
            LoadingSpinner().controlSize(.small)
        }
    }
}

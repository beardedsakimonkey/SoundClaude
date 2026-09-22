import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarDestination?
    let currentPlaylistURN: String?
    @ObservedObject var playlists: PlaylistsController
    let user: SoundCloudUser
    let artworkLoader: ArtworkLoader
    let onSelectPlaylist: (SoundCloudPlaylist) -> Void
    let onDeletePlaylist: (SoundCloudPlaylist) -> Void
    let onSelectProfile: (SoundCloudUser) -> Void
    let onReselect: () -> Void
    let onSignOut: () async -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isSidebarFocused: Bool
    @State private var isShowingCreatePlaylist = false
    @State private var isProfileHovered = false
    @State private var isSignOutHovered = false
    @State private var dropTargetURN: String?
    @State private var addingToPlaylistURNs: Set<String> = []
    @State private var playlistDropError: String?
    @State private var playlistLikeError: String?
    @State private var editingPlaylist: SoundCloudPlaylist?
    @State private var playlistDeletion = PlaylistDeletionState()
    @AppStorage("sidebarPlaylistsExpanded") private var isPlaylistsExpanded = true
    @AppStorage("sidebarLikedPlaylistsExpanded") private var isLikedPlaylistsExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            accountHeader
            sidebarList
        }
        .navigationTitle("SoundClaude")
        .sheet(isPresented: $isShowingCreatePlaylist) {
            PlaylistEditorView(playlists: playlists, onSaved: onSelectPlaylist)
        }
        .sheet(item: $editingPlaylist) { playlist in
            PlaylistEditorView(playlists: playlists, playlist: playlist)
        }
        .modifier(PlaylistDeletionModifier(
            state: $playlistDeletion, playlists: playlists, onDeleted: onDeletePlaylist
        ))
        .alert("Could not add track to playlist", isPresented: Binding(
            get: { playlistDropError != nil },
            set: { if !$0 { playlistDropError = nil } }
        )) {
            Button("OK", role: .cancel) { playlistDropError = nil }
        } message: {
            Text(playlistDropError ?? "Please try again.")
        }
        .alert("Could not unlike playlist", isPresented: Binding(
            get: { playlistLikeError != nil },
            set: { if !$0 { playlistLikeError = nil } }
        )) {
            Button("OK", role: .cancel) { playlistLikeError = nil }
        } message: {
            Text(playlistLikeError ?? "Please try again.")
        }
    }

    private var sidebarList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(SidebarDestination.libraryDestinations) { destination in
                    Label {
                        Text(destination.title)
                    } icon: {
                        Image(systemName: destination.systemImage)
                    }
                        .modifier(SidebarRowStyle(isSelected: selection == destination, usesPrimaryForeground: true) {
                            select(destination)
                        })
                }
                VStack(alignment: .leading, spacing: 0) {
                    sectionHeader("Playlists", isExpanded: $isPlaylistsExpanded)
                    if isPlaylistsExpanded {
                        Label {
                            Text("New")
                        } icon: {
                            Image(systemName: "plus")
                                .frame(width: 24, height: 24)
                        }
                            .modifier(SidebarRowStyle(isSelected: false) {
                                isShowingCreatePlaylist = true
                            })
                            .transition(.opacity)

                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(playlists.playlists) { playlist in
                                playlistRow(playlist)
                                    .transition(.opacity)
                            }
                            if playlists.isLoading {
                                ProgressView()
                                    .accessibilityLabel("Loading playlists")
                                    .controlSize(.small)
                                    .frame(maxWidth: .infinity, alignment: .center)
                            } else if let errorMessage = playlists.errorMessage {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(errorMessage)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Button("Try Again") { Task { await playlists.load() } }
                                        .modifier(SidebarHoverBackground())
                                }
                            } else if playlists.playlists.isEmpty {
                                Text("No playlists")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    if !playlists.likedPlaylists.isEmpty {
                        sectionHeader("Liked Playlists", isExpanded: $isLikedPlaylistsExpanded)
                            .transition(.opacity)
                    }
                    if isLikedPlaylistsExpanded {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(playlists.likedPlaylists) { playlist in
                                playlistRow(playlist)
                                    .transition(.opacity)
                            }
                            if playlists.isLoadingLikes {
                                if !playlists.likedPlaylists.isEmpty {
                                    ProgressView()
                                        .accessibilityLabel("Loading liked playlists")
                                        .controlSize(.small)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                }
                            } else if let errorMessage = playlists.likesErrorMessage {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(errorMessage)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Button("Try Again") { Task { await playlists.loadLikes() } }
                                        .modifier(SidebarHoverBackground())
                                }
                            } else if playlists.hasLoadedLikes && playlists.likedPlaylists.isEmpty {
                                Text("No liked playlists")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                    }
                }
            }
            .padding(8)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.25),
                value: isPlaylistsExpanded
            )
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.25),
                value: isLikedPlaylistsExpanded
            )
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.25),
                value: playlists.playlists.map(\.urn)
            )
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.25),
                value: playlists.likedPlaylists.map(\.urn)
            )
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isSidebarFocused)
        .onMoveCommand { direction in
            let destinations = SidebarDestination.libraryDestinations
            let index = selection.flatMap { destinations.firstIndex(of: $0) } ?? 0
            switch direction {
            case .up: selection = destinations[max(0, index - 1)]
            case .down: selection = destinations[min(destinations.count - 1, index + 1)]
            default: break
            }
        }
        .task { await playlists.load() }
        .task { await playlists.loadLikes() }
    }

    @ViewBuilder
    private func playlistRow(_ playlist: SoundCloudPlaylist) -> some View {
        let isOwned = (playlist.owner.urn == user.urn && user.urn != nil)
            || playlist.owner.permalinkURL == user.permalinkURL
        let contents = playlists.cache.contents[playlist.urn]
        let artworkURL = contents?.playlist.artworkURL
            ?? playlist.artworkURL
            ?? contents?.tracks.first(where: { $0.displayArtworkURL != nil })?.displayArtworkURL

        let row = Label {
            Text(playlist.title)
        } icon: {
            TrackArtworkView(
                artworkURL: artworkURL,
                loader: artworkLoader,
                size: 24,
                showsBorder: false
            )
        }
            .lineLimit(1)
            .help(playlist.title)
            .modifier(SidebarRowStyle(isSelected: false, usesPrimaryForeground: currentPlaylistURN == playlist.urn) {
                onSelectPlaylist(playlist)
            })
            .contextMenu {
                if playlists.likedPlaylistURNs.contains(playlist.urn) {
                    Button("Unlike playlist", systemImage: "heart.slash") {
                        Task { @MainActor in
                            guard playlists.likedPlaylistURNs.contains(playlist.urn) else { return }
                            do {
                                try await playlists.toggleLike(playlist)
                            } catch is CancellationError {
                            } catch {
                                playlistLikeError = "\(playlist.title): \(error.localizedDescription)"
                            }
                        }
                    }
                    .disabled(playlists.updatingLikeURNs.contains(playlist.urn))
                }
                if isOwned {
                    Button {
                        editingPlaylist = contents?.playlist ?? playlist
                    } label: {
                        Label("Edit playlist", systemImage: "pencil")
                    }
                    .disabled(playlists.updatingPlaylistURNs.contains(playlist.urn)
                        || playlistDeletion.deletingURNs.contains(playlist.urn))
                    DeletePlaylistButton(playlist: playlist, state: $playlistDeletion)
                }
            }

        if isOwned {
            row
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(dropTargetURN == playlist.urn ? 0.18 : 0))
                }
                .overlay(alignment: .trailing) {
                    if addingToPlaylistURNs.contains(playlist.urn) {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 8)
                            .accessibilityLabel("Adding track to \(playlist.title)")
                            .allowsHitTesting(false)
                    }
                }
                .dropDestination(for: TrackPlaylistDrag.self) { items, _ in
                    guard !items.isEmpty,
                          addingToPlaylistURNs.insert(playlist.urn).inserted else { return false }
                    dropTargetURN = nil
                    Task { @MainActor in
                        defer { addingToPlaylistURNs.remove(playlist.urn) }
                        do {
                            for item in items {
                                try await playlists.addTrack(item.track, to: playlist)
                            }
                        } catch is CancellationError {
                        } catch {
                            playlistDropError = "\(playlist.title): \(error.localizedDescription)"
                        }
                    }
                    return true
                } isTargeted: { isTargeted in
                    if isTargeted && !addingToPlaylistURNs.contains(playlist.urn) {
                        dropTargetURN = playlist.urn
                    } else if dropTargetURN == playlist.urn {
                        dropTargetURN = nil
                    }
                }
        } else {
            row
        }
    }

    private func sectionHeader(_ title: String, isExpanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            HStack {
                Text(title)
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.25),
                        value: isExpanded.wrappedValue
                    )
                    .accessibilityHidden(true)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.top, 16)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
            .modifier(SidebarForegroundHover())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded.wrappedValue ? "Expanded" : "Collapsed")
        .help("\(isExpanded.wrappedValue ? "Collapse" : "Expand") \(title)")
    }

    private func select(_ destination: SidebarDestination) {
        isSidebarFocused = true
        if selection == destination {
            onReselect()
        } else {
            selection = destination
        }
    }

    private var accountHeader: some View {
        HStack(spacing: 8) {
            Button {
                onSelectProfile(user)
            } label: {
                HStack(spacing: 8) {
                    TrackArtworkView(
                        artworkURL: user.avatarURL,
                        loader: artworkLoader,
                        size: 24,
                        showsPlaceholderIcon: false
                    )
                    .clipShape(Circle())
                    Text(user.username)
                        .font(.callout.weight(.medium))
                        .underline(isProfileHovered)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onContentHover { isProfileHovered = $0 }
            .help("View profile: \(user.username)")
            .accessibilityLabel("View profile: \(user.username)")

            Spacer(minLength: 0)

            Button(role: .destructive) {
                Task { await onSignOut() }
            } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .frame(width: 28, height: 28)
                    .background {
                        Circle()
                            .fill(Color.primary.opacity(isSignOutHovered ? 0.1 : 0))
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .onContentHover { isSignOutHovered = $0 }
            .help("Sign out")
            .accessibilityLabel("Sign out")
        }
        .padding(.horizontal, 12)
    }
}

private struct SidebarRowStyle: ViewModifier {
    let isSelected: Bool
    var usesPrimaryForeground = false
    let onSelect: () -> Void

    func body(content: Content) -> some View {
        Button(action: onSelect) {
            content
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
            .buttonStyle(.plain)
            .modifier(SidebarForegroundHover(isSelected: isSelected, usesPrimaryForeground: usesPrimaryForeground))
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.06 : 0))
            }
    }
}

private struct SidebarForegroundHover: ViewModifier {
    var isSelected = false
    var usesPrimaryForeground = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var foregroundColor: Color {
        if isSelected {
            return Color("AccentColor")
        }
        if usesPrimaryForeground {
            return isHovered ? (colorScheme == .dark ? .white : .black) : .primary
        }
        return isHovered ? .primary : .secondary
    }

    func body(content: Content) -> some View {
        content
            .foregroundStyle(foregroundColor)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isHovered)
            .onContentHover { isHovered = $0 }
    }
}

private struct SidebarHoverBackground: ViewModifier {
    var isSelected = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.06 : 0))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(isHovered && isEnabled ? 0.06 : 0))
                            .animation(
                                reduceMotion ? nil : .easeInOut(duration: 0.2),
                                value: isHovered && isEnabled
                            )
                    }
            }
            .onContentHover { isHovered = $0 }
    }
}

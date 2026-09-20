import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarDestination?
    @ObservedObject var playlists: PlaylistsController
    let user: SoundCloudUser
    let artworkLoader: ArtworkLoader
    let onSelectPlaylist: (SoundCloudPlaylist) -> Void
    let onSelectProfile: (SoundCloudUser) -> Void
    let onReselect: () -> Void
    let onSignOut: () async -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isSidebarFocused: Bool
    @State private var isShowingCreatePlaylist = false
    @State private var isProfileHovered = false
    @State private var isPlaylistsExpanded = true
    @State private var isLikedPlaylistsExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            accountHeader
            sidebarList
        }
        .navigationTitle("SoundClaude")
        .sheet(isPresented: $isShowingCreatePlaylist) {
            CreatePlaylistView(playlists: playlists, onCreated: onSelectPlaylist)
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
                        .modifier(SidebarRowStyle(isSelected: selection == destination) {
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

    private func playlistRow(_ playlist: SoundCloudPlaylist) -> some View {
        let contents = playlists.cache.contents[playlist.urn]
        let artworkURL = contents?.playlist.artworkURL
            ?? playlist.artworkURL
            ?? contents?.tracks.first(where: { $0.displayArtworkURL != nil })?.displayArtworkURL

        return Label {
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
            .modifier(SidebarRowStyle(isSelected: false) {
                onSelectPlaylist(playlist)
            })
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
                        size: 24
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
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Sign out")
            .accessibilityLabel("Sign out")
        }
        .padding(12)
    }
}

private struct SidebarRowStyle: ViewModifier {
    let isSelected: Bool
    let onSelect: () -> Void

    func body(content: Content) -> some View {
        Button(action: onSelect) {
            content
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
            .buttonStyle(.plain)
            .modifier(SidebarForegroundHover(isSelected: isSelected))
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.06 : 0))
            }
    }
}

private struct SidebarForegroundHover: ViewModifier {
    var isSelected = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var foregroundColor: Color {
        if isSelected {
            return Color("AccentColor")
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

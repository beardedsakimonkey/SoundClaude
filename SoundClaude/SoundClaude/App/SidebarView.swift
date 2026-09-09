import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarDestination?
    @ObservedObject var playlists: PlaylistsController
    let user: SoundCloudUser
    let artworkLoader: ArtworkLoader
    let onSearch: (String) -> Void
    let onSelectProfile: (SoundCloudUser) -> Void
    let onSignOut: () async -> Void

    @State private var isProfileHovered = false
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            accountHeader
            sidebarList
        }
        .navigationTitle("SoundClaude")
    }

    private var sidebarList: some View {
        List(selection: $selection) {
            ForEach(SidebarDestination.libraryDestinations) { destination in
                Label(destination.title, systemImage: destination.systemImage)
                    .tag(destination)
                    .background(SidebarTypingConfiguration())
            }
            Section("Playlists") {
                ForEach(playlists.playlists) { playlist in
                    let contents = playlists.cache.contents[playlist.urn]
                    let artworkURL = contents?.playlist.artworkURL
                        ?? playlist.artworkURL
                        ?? contents?.tracks.first(where: { $0.artworkURL != nil })?.artworkURL

                    Label {
                        Text(playlist.title)
                    } icon: {
                        TrackArtworkView(
                            artworkURL: artworkURL,
                            loader: artworkLoader,
                            size: 24
                        )
                    }
                        .lineLimit(1)
                        .help(playlist.title)
                        .tag(SidebarDestination.playlist(playlist))
                }
                if playlists.isLoading {
                    ProgressView("Loading playlists")
                        .controlSize(.small)
                } else if let errorMessage = playlists.errorMessage {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Try Again") { Task { await playlists.load() } }
                    }
                } else if playlists.playlists.isEmpty {
                    Text("No playlists")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { await playlists.load() }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    isSearchFocused = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("/", modifiers: [])
                .accessibilityLabel("Focus search")
                .help("Focus search (/)")
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .modifier(PreventAutomaticSearchFocus())
                    .onExitCommand {
                        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            searchText = ""
                        }
                        isSearchFocused = false
                    }
                    .onSubmit {
                        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        onSearch(searchText)
                        isSearchFocused = false
                    }
                    .accessibilityLabel("Search SoundCloud")
                    .help("Search SoundCloud. Press / to focus, then Return to search.")
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        isSearchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(8)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .background {
                SearchOutsideClickView(isFocused: isSearchFocused) {
                    if isSearchFocused {
                        isSearchFocused = false
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
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

            Menu {
                Button("Log out") {
                    Task { await onSignOut() }
                }
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .padding(12)
    }
}

// Attach inside a row so only the sidebar's enclosing table is configured.
private struct SidebarTypingConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfigurationView {
        ConfigurationView()
    }

    func updateNSView(_ nsView: ConfigurationView, context: Context) {
        nsView.disableTypeSelect()
    }

    final class ConfigurationView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            disableTypeSelect()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            disableTypeSelect()
        }

        func disableTypeSelect() {
            var ancestor = superview
            while let view = ancestor {
                if let table = view as? NSTableView {
                    table.allowsTypeSelect = false
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

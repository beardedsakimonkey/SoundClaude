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

    @State private var isShowingCreatePlaylist = false
    @State private var isProfileHovered = false

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
        List(selection: $selection) {
            ForEach(SidebarDestination.libraryDestinations) { destination in
                Label {
                    Text(destination.title)
                        .foregroundStyle(selection == destination ? Color("AccentColor") : .primary)
                } icon: {
                    Image(systemName: destination.systemImage)
                        .foregroundStyle(selection == destination ? Color("AccentColor") : .primary)
                }
                    .modifier(SidebarRowStyle(isSelected: selection == destination) {
                        select(destination)
                    })
                    .tag(destination)
            }
            Section {
                Label("New", systemImage: "plus")
                    .modifier(SidebarRowStyle(isSelected: false) {
                        isShowingCreatePlaylist = true
                    })
                    .opacity(0.7)
                    .selectionDisabled()

                ForEach(playlists.playlists) { playlist in
                    let contents = playlists.cache.contents[playlist.urn]
                    let artworkURL = contents?.playlist.artworkURL
                        ?? playlist.artworkURL
                        ?? contents?.tracks.first(where: { $0.displayArtworkURL != nil })?.displayArtworkURL

                    Label {
                        Text(playlist.title)
                            .foregroundStyle(.primary)
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
                        .selectionDisabled()
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
            } header: {
                Text("Playlists")
            }
        }
        .task { await playlists.load() }
        .listStyle(.sidebar)
    }

    private func select(_ destination: SidebarDestination) {
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
            .buttonStyle(.plain)
            .listRowBackground(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.06) : .clear)
                    .padding(.horizontal, 8)
            )
            .background(SidebarTableConfiguration())
    }
}

// Attach inside a row so only the sidebar's enclosing table is configured.
private struct SidebarTableConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfigurationView {
        ConfigurationView()
    }

    func updateNSView(_ nsView: ConfigurationView, context: Context) {
        nsView.configureTable()
    }

    final class ConfigurationView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureTable()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            configureTable()
        }

        func configureTable() {
            var ancestor = superview
            while let view = ancestor {
                if let table = view as? NSTableView {
                    table.allowsTypeSelect = false
                    // SwiftUI draws the gray row background; keep native keyboard selection.
                    table.selectionHighlightStyle = .none
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

private struct CreatePlaylistView: View {
    @ObservedObject var playlists: PlaylistsController
    let onCreated: (SoundCloudPlaylist) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var isPrivate = true
    @State private var isCreating = false
    @State private var errorMessage: String?
    @FocusState private var isTitleFocused: Bool

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create playlist")
                .font(.title2.bold())
            Form {
                TextField("Title", text: $title)
                    .focused($isTitleFocused)
                TextField("Description", text: $description, axis: .vertical)
                    .lineLimit(3...5)
                Picker("Visibility", selection: $isPrivate) {
                    Text("Private").tag(true)
                    Text("Public").tag(false)
                }
            }
            .disabled(isCreating)
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            HStack {
                if isCreating {
                    ProgressView().controlSize(.small)
                    Text("Creating playlist…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCreating)
                Button("Create") {
                    isCreating = true
                    errorMessage = nil
                    Task { @MainActor in
                        defer { isCreating = false }
                        do {
                            let playlist = try await playlists.createPlaylist(
                                title: trimmedTitle,
                                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                                isPrivate: isPrivate
                            )
                            dismiss()
                            onCreated(playlist)
                        } catch is CancellationError {
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedTitle.isEmpty || isCreating)
            }
        }
        .padding(24)
        .frame(width: 420)
        .interactiveDismissDisabled(isCreating)
        .dismissOnOutsideClick(isEnabled: !isCreating)
        .onAppear { isTitleFocused = true }
    }
}

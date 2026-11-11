import SwiftUI
import UniformTypeIdentifiers
import ImageIO

struct PlaylistEditorView: View {
    @ObservedObject var playlists: PlaylistsController
    let onSaved: (SoundCloudPlaylist) -> Void
    let playlist: SoundCloudPlaylist?
    /// The track a new playlist starts with, such as one dropped on the sidebar's New row.
    let initialTrack: SoundCloudTrack?
    let artworkLoader: ArtworkLoader?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var title = ""
    @State private var description = ""
    @State private var isPrivate = true
    @State private var artwork: PlaylistArtwork?
    @State private var artworkPreview: NSImage?
    @State private var removedArtwork = false
    @State private var isChoosingArtwork = false
    @State private var isHoveringArtwork = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var isTitleFocused: Bool

    init(playlists: PlaylistsController, playlist: SoundCloudPlaylist? = nil,
         initialTrack: SoundCloudTrack? = nil, artworkLoader: ArtworkLoader? = nil,
         onSaved: @escaping (SoundCloudPlaylist) -> Void = { _ in }) {
        self.playlists = playlists
        self.playlist = playlist
        self.initialTrack = initialTrack
        self.artworkLoader = artworkLoader
        self.onSaved = onSaved
        _title = State(initialValue: playlist?.title ?? "")
        _description = State(initialValue: playlist?.description ?? "")
        _isPrivate = State(initialValue: playlist?.isPrivate ?? true)
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(playlist == nil ? "New playlist" : "Edit playlist")
                .font(.title2.bold())
            HStack(alignment: .top, spacing: 24) {
                artworkColumn
                playlistFields
            }
            .disabled(isSaving)
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            HStack {
                if isSaving {
                    LoadingSpinner()
                        .controlSize(.small)
                        .accessibilityLabel(playlist == nil ? "Creating playlist" : "Saving playlist")
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button(playlist == nil ? "Create" : "Save") {
                    isSaving = true
                    errorMessage = nil
                    Task { @MainActor in
                        defer { isSaving = false }
                        do {
                            let saved: SoundCloudPlaylist
                            let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
                            if let playlist {
                                guard artwork == nil && !removedArtwork else {
                                    throw SoundCloudError.api("Playlist artwork changes are not supported yet. Cancel and reopen the dialog to edit the playlist details.")
                                }
                                saved = try await playlists.updatePlaylist(
                                    playlist, title: trimmedTitle, description: trimmedDescription,
                                    isPrivate: isPrivate
                                )
                            } else {
                                saved = try await playlists.createPlaylist(
                                    title: trimmedTitle, description: trimmedDescription, isPrivate: isPrivate,
                                    artwork: artwork, track: initialTrack
                                )
                            }
                            dismiss()
                            onSaved(saved)
                        } catch is CancellationError {
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedTitle.isEmpty || isSaving)
            }
        }
        .padding(24)
        .frame(width: 600)
        .interactiveDismissDisabled(isSaving)
        .dismissOnOutsideClick(isEnabled: !isSaving)
        .onAppear { isTitleFocused = true }
        .fileImporter(isPresented: $isChoosingArtwork, allowedContentTypes: [.gif, .jpeg, .png]) { result in
            do {
                let url = try result.get()
                let hasAccess = url.startAccessingSecurityScopedResource()
                defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let identifier = CGImageSourceGetType(source) as String?,
                      let format = [UTType.gif.identifier: PlaylistArtwork.Format.gif,
                                    UTType.jpeg.identifier: .jpeg,
                                    UTType.png.identifier: .png][identifier],
                      let preview = NSImage(data: data) else {
                    errorMessage = "Choose a valid GIF, JPEG, or PNG image."
                    return
                }
                removedArtwork = false
                artwork = PlaylistArtwork(data: data, format: format)
                artworkPreview = preview
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var artworkColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                isChoosingArtwork = true
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.quaternary)
                    if let artworkPreview {
                        Image(nsImage: artworkPreview)
                            .resizable()
                            .scaledToFill()
                    } else if let url = initialTrack?.displayArtworkURL, let artworkLoader {
                        TrackArtworkView(
                            artworkURL: url,
                            loader: artworkLoader,
                            size: 210,
                            rendition: .square500,
                            shape: RoundedRectangle(cornerRadius: 10, style: .continuous),
                            showsBorder: false
                        )
                    } else if let url = playlist?.artworkURL, !removedArtwork {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            defaultArtwork
                        }
                    } else {
                        defaultArtwork
                    }
                }
                .frame(width: 210, height: 210)
                .scaleEffect(isHoveringArtwork && !isSaving && !reduceMotion ? 1.1 : 1)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .modifier(PlayerArtworkGlass(
                    cornerRadius: 10,
                    size: CGSize(width: 210, height: 210)
                ))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringArtwork = $0 }
            .animation(
                reduceMotion ? nil : isHoveringArtwork
                    ? .spring(response: 0.4, dampingFraction: 0.75)
                    : .spring(duration: 0.34, bounce: 0),
                value: isHoveringArtwork
            )
            .accessibilityLabel(hasArtwork ? "Change playlist image" : "Choose playlist image")
            .help("Choose a playlist image")

            HStack(spacing: 8) {
                Button("Choose image…") {
                    isChoosingArtwork = true
                }
                if hasArtwork {
                    Button("Remove") {
                        artwork = nil
                        artworkPreview = nil
                        removedArtwork = playlist?.artworkURL != nil
                    }
                }
            }
        }
        .frame(width: 210)
    }

    private var hasArtwork: Bool {
        artwork != nil || (playlist?.artworkURL != nil && !removedArtwork)
    }

    private var defaultArtwork: some View {
        Image(systemName: "music.note")
            .font(.system(size: 84, weight: .medium))
            .foregroundStyle(.secondary)
    }

    private var playlistFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Title")
                TextField("", text: $title)
                    .accessibilityLabel("Title")
                    .labelsHidden()
                    .focused($isTitleFocused)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Description")
                TextField("", text: $description, axis: .vertical)
                    .accessibilityLabel("Description")
                    .labelsHidden()
                    .lineLimit(3...5)
            }
            Picker("Visibility", selection: $isPrivate) {
                Text("Private").tag(true)
                Text("Public").tag(false)
            }
        }
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

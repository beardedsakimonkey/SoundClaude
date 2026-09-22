import SwiftUI
import UniformTypeIdentifiers
import ImageIO

struct PlaylistEditorView: View {
    @ObservedObject var playlists: PlaylistsController
    let onSaved: (SoundCloudPlaylist) -> Void
    let playlist: SoundCloudPlaylist?
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var isPrivate = true
    @State private var artwork: PlaylistArtwork?
    @State private var artworkPreview: NSImage?
    @State private var isChoosingArtwork = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var isTitleFocused: Bool

    init(playlists: PlaylistsController, playlist: SoundCloudPlaylist? = nil,
         onSaved: @escaping (SoundCloudPlaylist) -> Void = { _ in }) {
        self.playlists = playlists
        self.playlist = playlist
        self.onSaved = onSaved
        _title = State(initialValue: playlist?.title ?? "")
        _description = State(initialValue: playlist?.description ?? "")
        _isPrivate = State(initialValue: playlist?.isPrivate ?? true)
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(playlist == nil ? "Create playlist" : "Edit playlist")
                .font(.title2.bold())
            Form {
                if playlist == nil {
                    HStack {
                        if let artworkPreview {
                            Image(nsImage: artworkPreview)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 64, height: 64)
                                .accessibilityLabel("Selected playlist image")
                        }
                        Button(artwork == nil ? "Choose image…" : "Change image…") {
                            isChoosingArtwork = true
                        }
                        if artwork != nil {
                            Button("Remove") {
                                artwork = nil
                                artworkPreview = nil
                            }
                        }
                    }
                }
                TextField("Title", text: $title)
                    .focused($isTitleFocused)
                TextField("Description", text: $description, axis: .vertical)
                    .lineLimit(3...5)
                Picker("Visibility", selection: $isPrivate) {
                    Text("Private").tag(true)
                    Text("Public").tag(false)
                }
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
                    ProgressView()
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
                                saved = try await playlists.updatePlaylist(
                                    playlist, title: trimmedTitle, description: trimmedDescription,
                                    isPrivate: isPrivate
                                )
                            } else {
                                saved = try await playlists.createPlaylist(
                                    title: trimmedTitle, description: trimmedDescription, isPrivate: isPrivate,
                                    artwork: artwork
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
        .frame(width: 420)
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
                artwork = PlaylistArtwork(data: data, format: format)
                artworkPreview = preview
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

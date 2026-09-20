import SwiftUI

struct CreatePlaylistView: View {
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
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Creating playlist")
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

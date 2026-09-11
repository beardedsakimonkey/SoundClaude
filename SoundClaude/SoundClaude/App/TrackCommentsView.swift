import AppKit
import SwiftUI

struct TrackCommentsView: View {
    let track: SoundCloudTrack
    @ObservedObject var model: AppModel
    let onSelectArtist: (SoundCloudUser) -> Void

    let onCommentAdded: () -> Void

    @State private var draft = ""
    @FocusState private var isCommentFocused: Bool
    @State private var isPosting = false
    @State private var postingErrorMessage: String?
    @State private var comments: [SoundCloudComment] = []
    @State private var nextPageURL: URL?
    @State private var loadedPageURLs: Set<URL> = []
    @State private var hasLoaded = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var artworkAccent: ArtworkAccent?
    @State private var accentArtworkURL: URL?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 24) {
            commentComposer

            ForEach(comments) { comment in
                commentRow(comment)
            }

            if isLoading {
                ProgressView("Loading comments")
                    .frame(maxWidth: .infinity)
            } else if let errorMessage {
                VStack(spacing: 8) {
                    Text(errorMessage).foregroundStyle(.secondary)
                    Button("Try Again") { Task { await loadPage() } }
                }
                .frame(maxWidth: .infinity)
            } else if nextPageURL != nil {
                Button("Load More") { Task { await loadPage() } }
                    .frame(maxWidth: .infinity)
            } else if hasLoaded, comments.isEmpty {
                ContentUnavailableView(
                    "No comments",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("There are no comments to show for this track.")
                )
            }
        }
        .task {
            if !hasLoaded { await loadPage() }
        }
        .task(id: track.artworkURL) {
            artworkAccent = nil
            accentArtworkURL = nil
            guard let url = track.artworkURL,
                  let accent = try? await model.artworkLoader.accentColor(for: url),
                  !Task.isCancelled else { return }
            artworkAccent = accent
            accentArtworkURL = url
        }
    }

    private var commentComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if case let .signedIn(user) = model.auth.state {
                    TrackArtworkView(
                        artworkURL: user.avatarURL,
                        loader: model.artworkLoader,
                        size: 24,
                        shape: RoundedRectangle(cornerRadius: 12),
                        showsBorder: false
                    )
                    .clipShape(Circle())
                }

                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    // Keep the placeholder outside the native field's focus layout.
                    .overlay(alignment: .leading) {
                        if draft.isEmpty {
                            Text("Write a comment")
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .focused($isCommentFocused)
                    .modifier(PreventAutomaticSearchFocus())
                    .onExitCommand { isCommentFocused = false }
                    .onSubmit { Task { await postComment() } }
                    .accessibilityLabel("Comment")
                    .disabled(isPosting)

                Button {
                    Task { await postComment() }
                } label: {
                    ZStack {
                        if isPosting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .accessibilityLabel(isPosting ? "Posting comment" : "Send comment")
                .help("Send comment (Return)")
                .disabled(isPosting || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(5)
            .background(.primary.opacity(0.06), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(
                        .primary.opacity(isCommentFocused ? 0.35 : 0.15),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
            .background {
                SearchOutsideClickView(isFocused: isCommentFocused) {
                    isCommentFocused = false
                }
            }

            if let postingErrorMessage {
                Text(postingErrorMessage)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    private func postComment() async {
        guard !isPosting, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isPosting = true
        postingErrorMessage = nil
        defer { isPosting = false }
        do {
            let comment = try await model.addTrackComment(for: track, body: draft)
            comments.removeAll { $0.urn == comment.urn }
            comments.insert(comment, at: 0)
            draft = ""
            onCommentAdded()
        } catch {
            postingErrorMessage = error.localizedDescription
        }
    }

    private var timestampColor: Color {
        let blue = NSColor.systemBlue.usingColorSpace(.sRGB)!
        let fallback = ArtworkAccent(
            red: blue.redComponent, green: blue.greenComponent, blue: blue.blueComponent
        )
        let accent = accentArtworkURL == track.artworkURL
            ? artworkAccent ?? fallback : fallback
        let contrastedAccent = accent.contrasted(
            isDark: colorScheme == .dark,
            increasedContrast: colorSchemeContrast == .increased
        )
        return Color(
            .sRGB, red: contrastedAccent.red,
            green: contrastedAccent.green, blue: contrastedAccent.blue
        )
    }

    private func commentRow(_ comment: SoundCloudComment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let user = comment.user {
                    ArtistLink(
                        artist: user,
                        artworkLoader: model.artworkLoader,
                        onSelect: onSelectArtist
                    )
                    .font(.headline)
                } else {
                    Label("Unknown user", systemImage: "person.crop.circle")
                        .foregroundStyle(.secondary)
                }
                if let timestamp = comment.timestampMilliseconds {
                    let seconds = timestamp / 1_000
                    let timeLabel = "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
                    Text("at")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        let position = Double(timestamp) / 1_000
                        if model.playback.currentTrack?.urn == track.urn {
                            model.playback.seek(to: position)
                        } else {
                            Task { await model.play(track, position: position) }
                        }
                    } label: {
                        Text(timeLabel)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(timestampColor.opacity(0.12), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(timestampColor)
                    .help("Jump to \(timeLabel)")
                    .accessibilityLabel("Jump to \(timeLabel) in \(track.title)")
                }
                if let createdAt = comment.createdAt {
                    Text(createdAt.formatted(.relative(presentation: .numeric, unitsStyle: .wide)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(createdAt.formatted(date: .abbreviated, time: .shortened))
                }
                Spacer()
            }

            Text(comment.body)
                .foregroundStyle(.primary.opacity(0.75))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func loadPage() async {
        guard !isLoading, !hasLoaded || nextPageURL != nil else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let pageURL = nextPageURL
            let page = try await model.trackComments(for: track, pageURL: pageURL)
            try Task.checkCancellation()
            if let nextURL = page.nextURL,
               nextURL == pageURL || loadedPageURLs.contains(nextURL) {
                throw SoundCloudError.invalidData
            }
            var knownURNs = Set(comments.map(\.urn))
            comments.append(contentsOf: page.comments.filter { knownURNs.insert($0.urn).inserted })
            if let pageURL { loadedPageURLs.insert(pageURL) }
            nextPageURL = page.nextURL
            hasLoaded = true
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}

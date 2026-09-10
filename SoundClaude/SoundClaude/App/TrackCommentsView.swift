import SwiftUI

struct TrackCommentsView: View {
    let track: SoundCloudTrack
    @ObservedObject var model: AppModel
    let onSelectArtist: (SoundCloudUser) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var comments: [SoundCloudComment] = []
    @State private var nextPageURL: URL?
    @State private var loadedPageURLs: Set<URL> = []
    @State private var hasLoaded = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Comments").font(.title2.weight(.semibold))
                    Text(track.title)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(24)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(comments) { comment in
                        commentRow(comment)
                        Divider()
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
                .padding(24)
            }
        }
        .frame(width: 600, height: 560)
        .dismissOnOutsideClick()
        .task { await loadPage() }
    }

    private func commentRow(_ comment: SoundCloudComment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                if let user = comment.user {
                    ArtistLink(artist: user, artworkLoader: model.artworkLoader) { selected in
                        dismiss()
                        onSelectArtist(selected)
                    }
                    .font(.headline)
                } else {
                    Label("Unknown user", systemImage: "person.crop.circle")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let createdAt = comment.createdAt {
                    Text(createdAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(createdAt.formatted(date: .abbreviated, time: .shortened))
                }
            }

            Text(comment.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            if let timestamp = comment.timestampMilliseconds {
                let seconds = timestamp / 1_000
                Text("At \(seconds / 60):\(String(format: "%02d", seconds % 60))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
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

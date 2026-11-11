import SwiftUI

struct ArtistCommentsView: View {
    let artist: SoundCloudUser
    let model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void

    @State private var comments: [SoundCloudComment]
    @State private var nextPageURL: URL?
    @State private var loadedPageURLs: Set<URL> = []
    @State private var hasLoaded: Bool
    @State private var isLoading = false
    @State private var errorMessage: String?

    init(
        artist: SoundCloudUser,
        model: AppModel,
        onSelectTrack: @escaping (SoundCloudTrack) -> Void,
        onSelectArtist: @escaping (SoundCloudUser) -> Void
    ) {
        self.artist = artist
        self.model = model
        self.onSelectTrack = onSelectTrack
        self.onSelectArtist = onSelectArtist
        // The artist page's preview already requested the first page.
        let firstPage = model.cachedFirstArtistCommentPage(for: artist)
        _comments = State(initialValue: firstPage?.comments ?? [])
        _nextPageURL = State(initialValue: firstPage?.nextURL)
        _hasLoaded = State(initialValue: firstPage != nil)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 6) {
                    Text("Comments by")
                    ArtistLink(
                        artist: artist,
                        artworkLoader: model.artworkLoader,
                        showsAvatarBorder: true,
                        showsVerifiedBadge: true,
                        helpTitle: "View profile",
                        onSelect: onSelectArtist
                    )
                    .imageScale(.small)
                }
                .font(.title2)
                .lineLimit(1)

                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(comments) { comment in
                        if let track = comment.track {
                            ArtistCommentRow(
                                comment: comment,
                                track: track,
                                artworkLoader: model.artworkLoader,
                                onSelectTrack: onSelectTrack,
                                onSelectArtist: onSelectArtist
                            )
                            .modifier(FadeInOnAppear())
                        }
                    }

                    if let errorMessage {
                        VStack(spacing: 8) {
                            Text(errorMessage).foregroundStyle(.secondary)
                            Button("Try Again") { Task { await loadPage() } }
                                .disabled(isLoading)
                        }
                        .frame(maxWidth: .infinity)
                    } else if !hasLoaded || nextPageURL != nil {
                        LoadingSpinner()
                            .accessibilityLabel("Loading comments")
                            .frame(maxWidth: .infinity)
                            .task { await loadPage() }
                            // A new spinner per page, so an empty page moves on to the next.
                            .id(nextPageURL)
                    } else if comments.isEmpty {
                        EmptyStateView("No comments")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            .scrollKeyNavigation()
            .remembersScrollPosition()
        }
        .background(alignment: .top) {
            RouteGradientBackdrop()
        }
        .navigationTitle("Comments by \(artist.username)")
    }

    private func loadPage() async {
        guard !isLoading, !hasLoaded || nextPageURL != nil else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let pageURL = nextPageURL
            let page = try await model.artistComments(for: artist, pageURL: pageURL)
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

/// A comment an artist posted, and the track it was posted on.
struct ArtistCommentRow: View {
    let comment: SoundCloudComment
    let track: SoundCloudTrack
    /// Shows the track's artwork beside the comment.
    var artworkLoader: ArtworkLoader? = nil
    var bodyLineLimit: Int? = nil
    /// Puts the timestamp under the comment instead of beside the title, for narrow columns.
    var showsTimestampBelow = false
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void

    @State private var isHoveringTitle = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let artworkLoader {
                Button {
                    onSelectTrack(track)
                } label: {
                    TrackArtworkView(
                        artworkURL: track.displayArtworkURL,
                        loader: artworkLoader,
                        size: 50
                    )
                }
                .buttonStyle(.plain)
                .prefetch(.track(track))
                .contentHelp(track.title)
                // The title links to the same page.
                .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Button {
                        onSelectTrack(track)
                    } label: {
                        Text("\(Text("on").foregroundStyle(.secondary)) \(Text(track.title).underline(isHoveringTitle))")
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .prefetch(.track(track)) { isHoveringTitle = $0 }
                    .contentHelp(track.title)

                    Spacer(minLength: 0)

                    if !showsTimestampBelow {
                        timestamp
                    }
                }

                ArtistMentionText(comment.body, isQuoted: true, onSelectArtist: onSelectArtist)
                    .textSelection(.enabled)
                    .lineLimit(bodyLineLimit)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                if showsTimestampBelow {
                    timestamp
                }
            }
        }
    }

    private var timestamp: some View {
        RelativeTimestampView(
            date: comment.createdAt,
            accessibilityPrefix: "Posted",
            showsSeparator: false
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize()
    }
}

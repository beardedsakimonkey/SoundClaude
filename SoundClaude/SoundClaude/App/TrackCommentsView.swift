import AppKit
import SwiftUI

enum CommentSortOrder: String, CaseIterable {
    case newest
    case oldest
    case trackTime

    var title: String {
        switch self {
        case .newest: "Newest"
        case .oldest: "Oldest"
        case .trackTime: "Track Time"
        }
    }

    func precedes(_ lhs: SoundCloudComment, _ rhs: SoundCloudComment) -> Bool {
        if self == .trackTime, lhs.timestampMilliseconds != rhs.timestampMilliseconds {
            guard let left = lhs.timestampMilliseconds else { return false }
            guard let right = rhs.timestampMilliseconds else { return true }
            return left < right
        }
        // Missing dates go last; equal dates retain their loaded order.
        guard let left = lhs.createdAt else { return false }
        guard let right = rhs.createdAt else { return true }
        return self == .oldest ? left < right : left > right
    }
}

struct CommentSortMenu: View {
    @AppStorage("commentSortOrder") private var sortOrder = CommentSortOrder.newest
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.down")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            SortMenu(
                label: "Sort comments",
                selection: $sortOrder,
                options: CommentSortOrder.allCases,
                title: { $0.title },
                reservesWidestTitle: false
            )
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct TrackCommentsView: View {
    let track: SoundCloudTrack
    let model: AppModel
    let onSelectArtist: (SoundCloudUser) -> Void

    let onCommentAdded: () -> Void

    @AppStorage("commentSortOrder") private var sortOrder = CommentSortOrder.newest
    // Keep loaded order for stable sorting when dates or track times are equal.
    @State private var comments: [SoundCloudComment] = []
    // Reply URN to the URN of the comment that starts its thread.
    @State private var parentURNs: [String: String] = [:]
    @State private var threader = SoundCloudCommentThreader()
    @State private var rows: [TrackCommentListRow] = []
    @State private var nextPageURL: URL?
    @State private var loadedPageURLs: Set<URL> = []
    @State private var hasLoaded = false
    @State private var isLoading = false
    // Owned by the list, not the spinner, so scrolling the spinner away does not cancel it.
    @State private var pageTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var likes = TrackCommentLikes()
    @State private var artworkAccent: ArtworkAccent?
    @State private var accentArtworkURL: URL?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        let rowTimestampColor = timestampColor

        LazyVStack(alignment: .leading, spacing: 20) {
            TrackCommentComposer(track: track, model: model) { comment in
                comments.removeAll { $0.urn == comment.urn }
                comments.insert(comment, at: 0)
                likes.merge([:], for: [comment])
                updateSortedComments()
                onCommentAdded()
            }
            .modifier(FadeInOnAppear())

            ForEach(rows) { row in
                TrackCommentRow(
                    comment: row.comment,
                    isReply: row.isReply,
                    track: track,
                    model: model,
                    likes: likes,
                    timestampColor: rowTimestampColor,
                    onSelectArtist: onSelectArtist
                )
                .modifier(FadeInOnAppear())
            }

            if let errorMessage {
                VStack(spacing: 8) {
                    Text(errorMessage).foregroundStyle(.secondary)
                    Button("Try Again") { Task { await loadPage() } }
                }
                .frame(maxWidth: .infinity)
                .modifier(FadeInOnAppear())
            } else if isLoading || nextPageURL != nil {
                LoadingSpinner()
                    .accessibilityLabel("Loading comments")
                    .frame(maxWidth: .infinity)
                    .modifier(FadeInOnAppear())
                    .task {
                        guard nextPageURL != nil else { return }
                        startLoadingPage()
                    }
                    // A new spinner per page. Reusing the first-load spinner would
                    // request the next page while it is still built but off screen.
                    .id(nextPageURL)
            }
        }
        .onChange(of: sortOrder) { _, _ in
            updateSortedComments()
        }
        .onDisappear { pageTask?.cancel() }
        .task {
            if !hasLoaded { await loadPage() }
        }
        .task(id: track.displayArtworkURL) {
            artworkAccent = nil
            accentArtworkURL = nil
            guard let url = track.displayArtworkURL,
                  let accent = try? await model.artworkLoader.accentColor(for: url),
                  !Task.isCancelled else { return }
            artworkAccent = accent
            accentArtworkURL = url
        }
        #if DEBUG
        .debugViewUpdates("TrackCommentsView")
        #endif
    }

    private var timestampColor: Color {
        let blue = NSColor.systemBlue.usingColorSpace(.sRGB)!
        let fallback = ArtworkAccent(
            red: blue.redComponent, green: blue.greenComponent, blue: blue.blueComponent
        )
        let accent = accentArtworkURL == track.displayArtworkURL
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

    // Sort threads by their first comment; replies stay in posted order beneath it.
    private func updateSortedComments() {
        let urns = Set(comments.map(\.urn))
        func parent(of comment: SoundCloudComment) -> String? {
            parentURNs[comment.urn].flatMap { urns.contains($0) ? $0 : nil }
        }
        let replies = Dictionary(grouping: comments.filter { parent(of: $0) != nil }) { parent(of: $0)! }
        rows = comments.filter { parent(of: $0) == nil }
            .sorted(by: sortOrder.precedes)
            .flatMap { root in
                [TrackCommentListRow(comment: root, isReply: false)]
                    + (replies[root.urn] ?? []).map { TrackCommentListRow(comment: $0, isReply: true) }
            }
    }

    private func startLoadingPage() {
        guard pageTask == nil else { return }
        pageTask = Task {
            await loadPage()
            pageTask = nil
        }
    }

    // Hearts appear when their page's likes arrive; a failure leaves them hidden.
    private func loadLikes(for page: [SoundCloudComment]) {
        Task { [likes] in
            guard let loaded = try? await model.commentLikes(for: track, comments: page) else { return }
            likes.merge(loaded, for: page)
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
            // Thread before dropping known comments so a known comment can still start a thread.
            let pageParentURNs = threader.parentURNs(in: page.comments)
            var knownURNs = Set(comments.map(\.urn))
            let newComments = page.comments.filter { knownURNs.insert($0.urn).inserted }
            if !newComments.isEmpty {
                for comment in newComments {
                    parentURNs[comment.urn] = pageParentURNs[comment.urn]
                }
                comments.append(contentsOf: newComments)
                updateSortedComments()
                loadLikes(for: newComments)
            }
            if let pageURL { loadedPageURLs.insert(pageURL) }
            nextPageURL = page.nextURL
            hasLoaded = true
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}

// Keep composer interaction state local so hover, focus, and typing do not update the list.
private struct TrackCommentComposer: View {
    let track: SoundCloudTrack
    let model: AppModel
    let onCommentAdded: (SoundCloudComment) -> Void

    @State private var draft = ""
    @FocusState private var isCommentFocused: Bool
    @State private var isCommentHovered = false
    @State private var commentTimestampMilliseconds: Int?
    @State private var isPosting = false
    @State private var postingErrorMessage: String?

    private static let avatarSize: CGFloat = 28

    private var showsComposerControls: Bool {
        isCommentHovered || isCommentFocused || isPosting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if case let .signedIn(user) = model.auth.state {
                    TrackArtworkView(
                        artworkURL: user.avatarURL,
                        loader: model.artworkLoader,
                        size: Self.avatarSize,
                        shape: RoundedRectangle(cornerRadius: Self.avatarSize / 2),
                        showsBorder: false,
                        showsPlaceholderIcon: false
                    )
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                }

                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    // Keep the placeholder outside the native field's focus layout.
                    .overlay(alignment: .leading) {
                        if draft.isEmpty {
                            Text(commentPlaceholder)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .focused($isCommentFocused)
                    .onChange(of: isCommentFocused) { _, isFocused in
                        guard isFocused, !isPosting else { return }
                        commentTimestampMilliseconds = model.playback.currentTrack?.urn == track.urn
                            ? Int(max(0, model.playback.currentTime) * 1_000) : nil
                    }
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
                            LoadingSpinner()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 13, weight: .semibold))
                        }
                    }
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .accessibilityLabel(isPosting ? "Posting comment" : "Send comment")
                .contentHelp("Send comment (Return)")
                .disabled(isPosting || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(showsComposerControls ? 1 : 0)
                .allowsHitTesting(showsComposerControls)
                .accessibilityHidden(!showsComposerControls)
                .animation(.easeInOut(duration: 0.15), value: showsComposerControls)
            }
            .padding(5)
            .background {
                Capsule()
                    .fill(.primary.opacity(isCommentFocused || isCommentHovered ? 0.06 : 0))
                    .animation(
                        .easeInOut(duration: 0.15),
                        value: isCommentFocused || isCommentHovered
                    )
            }
            .contentShape(Capsule())
            .onTapGesture {
                guard !isPosting else { return }
                isCommentFocused = true
            }
            .onContentHover { isCommentHovered = $0 }
            .overlay {
                Capsule()
                    .strokeBorder(
                        .primary.opacity(showsComposerControls ? (isCommentFocused ? 0.35 : 0.15) : 0),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
                    .animation(.easeInOut(duration: 0.15), value: showsComposerControls)
            }
            .background {
                SearchOutsideClickView(isFocused: isCommentFocused) {
                    isCommentFocused = false
                }
            }
            // Align the avatar with the rows while keeping the capsule's inset.
            .padding(.leading, -5)

            if let postingErrorMessage {
                Text(postingErrorMessage)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: 320, alignment: .leading)
        #if DEBUG
        .debugViewUpdates("TrackCommentComposer")
        #endif
    }

    private var commentPlaceholder: String {
        guard isCommentFocused, let commentTimestampMilliseconds else {
            return "Write a comment"
        }
        let seconds = commentTimestampMilliseconds / 1_000
        let timestamp = "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
        return "Write a comment at \(timestamp)"
    }

    private func postComment() async {
        guard !isPosting, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isPosting = true
        postingErrorMessage = nil
        defer { isPosting = false }
        do {
            let comment = try await model.addTrackComment(
                for: track, body: draft, timestampMilliseconds: commentTimestampMilliseconds
            )
            draft = ""
            isCommentFocused = false
            commentTimestampMilliseconds = nil
            onCommentAdded(comment)
        } catch {
            postingErrorMessage = error.localizedDescription
        }
    }
}

private struct TrackCommentListRow: Identifiable {
    let comment: SoundCloudComment
    let isReply: Bool

    var id: String { comment.urn }
}

private struct TrackCommentRow: View {
    let comment: SoundCloudComment
    let isReply: Bool
    let track: SoundCloudTrack
    let model: AppModel
    let likes: TrackCommentLikes
    let timestampColor: Color
    let onSelectArtist: (SoundCloudUser) -> Void

    private static let avatarSize: CGFloat = 50
    private static let replyAvatarSize: CGFloat = 36
    private static let avatarSpacing: CGFloat = 14

    private var avatarSize: CGFloat { isReply ? Self.replyAvatarSize : Self.avatarSize }

    var body: some View {
        HStack(spacing: 16) {
            content
            TrackCommentLikeButton(comment: comment, track: track, model: model, likes: likes)
        }
        // Start replies under the body of the comment they answer.
        .padding(.leading, isReply ? Self.avatarSize + Self.avatarSpacing : 0)
    }

    private var content: some View {
        HStack(alignment: .top, spacing: Self.avatarSpacing) {
            if let user = comment.user {
                TrackCommentAvatar(user: user, loader: model.artworkLoader, size: avatarSize)
            } else {
                Image(systemName: "person.crop.circle")
                    .resizable()
                    .frame(width: avatarSize, height: avatarSize)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 6) {
                header

                ArtistMentionText(comment.body, onSelectArtist: onSelectArtist)
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .foregroundStyle(.primary.opacity(0.95))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Center short comments on the avatar; taller ones stay top-aligned.
            .frame(minHeight: avatarSize, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let user = comment.user {
                ArtistLink(
                    artist: user,
                    onSelect: onSelectArtist
                )
                .font(.body)
                .fontWeight(.medium)
                .opacity(0.85)
                // Truncate the relative age before the username.
                .layoutPriority(1)
            } else {
                Text("Unknown user")
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
            }
            if let timestamp = comment.timestampMilliseconds {
                let seconds = timestamp / 1_000
                let timeLabel = "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
                Text("at")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                if track.access == .protected {
                    Text(timeLabel)
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .fixedSize()
                        .foregroundStyle(timestampColor)
                        .opacity(protectedTrackOpacity)
                } else {
                    Button {
                        let position = Double(timestamp) / 1_000
                        if model.playback.currentTrack?.urn == track.urn {
                            model.playback.seek(to: position)
                        } else {
                            Task { await model.play(track, position: position) }
                        }
                    } label: {
                        Text(timeLabel)
                    }
                    .buttonStyle(CommentTimestampButtonStyle(color: timestampColor))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .fixedSize()
                    .foregroundStyle(timestampColor)
                    .contentHelp("Jump to \(timeLabel)")
                    .accessibilityLabel("Jump to \(timeLabel) in \(track.title)")
                }
            }
            if let createdAt = comment.createdAt {
                RelativeTimestampView(
                    date: createdAt,
                    accessibilityPrefix: "Posted",
                    showsSeparator: false
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }
}

/// Like state for one comment list. Rows read it only in their hearts, so a toggle
/// does not update the list or the rest of the row.
@MainActor @Observable
final class TrackCommentLikes {
    private(set) var likes: [String: SoundCloudCommentLikes] = [:]
    private(set) var pendingURNs: Set<String> = []

    /// Comments missing from `loaded` have no likes.
    func merge(_ loaded: [String: SoundCloudCommentLikes], for comments: [SoundCloudComment]) {
        for comment in comments where !pendingURNs.contains(comment.urn) {
            likes[comment.urn] = loaded[comment.urn] ?? SoundCloudCommentLikes(count: 0, isLiked: false)
        }
    }

    func toggle(_ comment: SoundCloudComment, on track: SoundCloudTrack, model: AppModel) async {
        guard !pendingURNs.contains(comment.urn), let current = likes[comment.urn] else { return }
        pendingURNs.insert(comment.urn)
        defer { pendingURNs.remove(comment.urn) }
        let isLiked = !current.isLiked
        likes[comment.urn] = SoundCloudCommentLikes(
            count: max(0, current.count + (isLiked ? 1 : -1)), isLiked: isLiked
        )
        do {
            try await model.setCommentLiked(isLiked, comment: comment, on: track)
        } catch {
            likes[comment.urn] = current
            if !(error is CancellationError) {
                model.likeErrorMessage = error.localizedDescription
            }
        }
    }
}

private struct TrackCommentLikeButton: View {
    let comment: SoundCloudComment
    let track: SoundCloudTrack
    let model: AppModel
    let likes: TrackCommentLikes

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var likeTaps = 0

    var body: some View {
        let state = likes.likes[comment.urn]
        let isLiked = state?.isLiked == true
        let count = state?.count ?? 0
        let isUpdating = likes.pendingURNs.contains(comment.urn)
        let actionLabel = isLiked ? "Unlike comment" : "Like comment"

        VStack(spacing: 0) {
            Button {
                guard !isUpdating else { return }
                if !isLiked { likeTaps += 1 }
                Task { await likes.toggle(comment, on: track, model: model) }
            } label: {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isLiked ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? 0 : likeTaps)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(CommentLikeButtonStyle())
            .contentHelp(actionLabel)
            .accessibilityLabel(actionLabel)
            .accessibilityValue(count == 1 ? "1 like" : "\(count) likes")

            // Reserve the count's line so hearts align across rows.
            Text(count.formatted(.number.notation(.compactName)))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .opacity(count > 0 ? 1 : 0)
                .accessibilityHidden(true)
        }
        .frame(width: 36)
        .opacity(state == nil ? 0 : 1)
        .allowsHitTesting(state != nil)
        .accessibilityHidden(state == nil)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: state == nil)
    }
}

private struct CommentLikeButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 28, height: 28)
            .background(.primary.opacity(isHovering ? 0.08 : 0), in: Circle())
            .contentShape(Circle())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .onContentHover { isHovering = $0 }
            .animation(.easeInOut(duration: 0.15), value: isHovering)
    }
}

// Keep the sheet state local so opening a picture does not update the row.
private struct TrackCommentAvatar: View {
    let user: SoundCloudUser
    let loader: ArtworkLoader
    let size: CGFloat

    @State private var isShowingPicture = false
    @State private var isHovering = false

    var body: some View {
        let thumbnail = TrackArtworkView(
            artworkURL: user.avatarURL,
            loader: loader,
            size: size,
            showsBorder: false,
            showsPlaceholderIcon: false
        )
        .scaleEffect(isHovering ? 1.15 : 1)
        .clipShape(Circle())
        .overlay {
            Circle()
                .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .animation(
            .spring(response: 0.35, dampingFraction: 0.75),
            value: isHovering
        )

        if user.avatarURL != nil {
            Button {
                isShowingPicture = true
            } label: {
                thumbnail
            }
            .buttonStyle(TrackCommentAvatarButtonStyle())
            .contentShape(Circle())
            .prefetch(
                user.avatarURL.map(PrefetchTarget.fullSizeImage),
                in: Circle().path(in: CGRect(x: 0, y: 0, width: size, height: size))
            ) { isHovering = $0 }
            .contentHelp("View full-size picture")
            .accessibilityLabel("View full-size picture of \(user.username)")
            .sheet(isPresented: $isShowingPicture) {
                FullSizeArtworkView(
                    title: user.username,
                    artworkURL: user.avatarURL,
                    loader: loader
                )
            }
        } else {
            thumbnail
        }
    }
}

private struct TrackCommentAvatarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private struct CommentTimestampButtonStyle: ButtonStyle {
    let color: Color

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let isHighlighted = isHovering && isEnabled

        configuration.label
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(isHighlighted ? 0.24 : 0.12), in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.5)
            .onContentHover { isHovering = $0 }
    }
}

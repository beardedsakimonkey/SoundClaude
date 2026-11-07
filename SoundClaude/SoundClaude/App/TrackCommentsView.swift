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

    /// +1 when the user posts a comment, -1 when they delete one.
    let onCommentCountChange: (Int) -> Void

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
    @State private var replies = TrackCommentReplies()
    @State private var artworkAccent: ArtworkAccent?
    @State private var accentArtworkURL: URL?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let rowTimestampColor = timestampColor

        LazyVStack(alignment: .leading, spacing: 20) {
            TrackCommentComposer(track: track, model: model) { comment in
                comments.removeAll { $0.urn == comment.urn }
                comments.insert(comment, at: 0)
                likes.merge([:], for: [comment])
                updateSortedComments()
                onCommentCountChange(1)
            }
            .modifier(FadeInOnAppear())

            ForEach(rows) { row in
                TrackCommentRow(
                    comment: row.comment,
                    isReply: row.isReply,
                    track: track,
                    model: model,
                    likes: likes,
                    replies: replies,
                    timestampColor: rowTimestampColor,
                    onSelectArtist: onSelectArtist,
                    onReplyAdded: addReply,
                    onDeleted: deleteComment
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

    // The new reply joins the end of its parent's thread, as the threaded endpoint lists it.
    private func addReply(_ reply: SoundCloudComment, to parent: SoundCloudComment) {
        let threadURN = parentURNs[parent.urn].flatMap { urn in
            comments.contains { $0.urn == urn } ? urn : nil
        } ?? parent.urn
        comments.removeAll { $0.urn == reply.urn }
        comments.append(reply)
        parentURNs[reply.urn] = threadURN
        likes.merge([:], for: [reply])
        // The posted reply takes the closing composer's place in one move.
        withAnimation(reduceMotion ? nil : TrackCommentReplies.animation) {
            updateSortedComments()
            replies.close(parent)
        }
        onCommentCountChange(1)
    }

    // Replies to a deleted thread start stay in the list as comments of their own.
    private func deleteComment(_ comment: SoundCloudComment) {
        guard comments.contains(where: { $0.urn == comment.urn }) else { return }
        comments.removeAll { $0.urn == comment.urn }
        parentURNs[comment.urn] = nil
        replies.close(comment)
        updateSortedComments()
        onCommentCountChange(-1)
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

/// The comment a reply answers. As on the website, a reply is an ordinary comment that
/// takes its thread's track time and starts with a mention of the comment's author.
private struct TrackCommentReplyTarget {
    let mention: String
    let timestampMilliseconds: Int

    init?(_ comment: SoundCloudComment) {
        guard let permalink = comment.user?.permalinkURL.lastPathComponent, !permalink.isEmpty,
              // Untimed comments never form threads, so a reply to one would not appear under it.
              let timestamp = comment.timestampMilliseconds else { return nil }
        mention = "@\(permalink): "
        timestampMilliseconds = timestamp
    }
}

// Keep composer interaction state local so hover, focus, and typing do not update the list.
private struct TrackCommentComposer: View {
    let track: SoundCloudTrack
    let model: AppModel
    let reply: TrackCommentReplyTarget?
    /// Changes each time the user asks to reply again while this composer is open.
    let focusRequest: Int
    let onCancel: () -> Void
    let onCommentAdded: (SoundCloudComment) -> Void

    @State private var draft: String
    @FocusState private var isCommentFocused: Bool
    @State private var isCommentHovered = false
    @State private var commentTimestampMilliseconds: Int?
    @State private var isPosting = false
    @State private var postingErrorMessage: String?

    private static let avatarSize: CGFloat = 28

    init(
        track: SoundCloudTrack,
        model: AppModel,
        reply: TrackCommentReplyTarget? = nil,
        focusRequest: Int = 0,
        onCancel: @escaping () -> Void = {},
        onCommentAdded: @escaping (SoundCloudComment) -> Void
    ) {
        self.track = track
        self.model = model
        self.reply = reply
        self.focusRequest = focusRequest
        self.onCancel = onCancel
        self.onCommentAdded = onCommentAdded
        _draft = State(initialValue: reply?.mention ?? "")
        _commentTimestampMilliseconds = State(initialValue: reply?.timestampMilliseconds)
    }

    // An open reply composer always shows its controls; the top one shows them while
    // in use or holding a draft.
    private var showsComposerControls: Bool {
        showsComposerBackground || isPosting
    }

    private var showsComposerBackground: Bool {
        reply != nil || !draft.isEmpty || isCommentFocused || isCommentHovered
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                field
                // The X keeps its slot while hidden, so it appearing does not narrow
                // the field and both composers share one width.
                Button(action: reply != nil ? onCancel : discardDraft) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(CommentIconButtonStyle())
                .contentHelp(closeLabel)
                .accessibilityLabel(closeLabel)
                .disabled(isPosting)
                .opacity(showsCloseButton ? 1 : 0)
                .allowsHitTesting(showsCloseButton)
                .accessibilityHidden(!showsCloseButton)
            }
            .animation(.easeInOut(duration: 0.15), value: showsCloseButton)

            if let postingErrorMessage {
                Text(postingErrorMessage)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: 480, alignment: .leading)
        .onAppear {
            // A reply composer opens because the user asked to write one. Wait a turn:
            // while the Reply click is still being handled, the request focuses the
            // list's top composer instead of this one.
            guard reply != nil else { return }
            DispatchQueue.main.async { isCommentFocused = true }
        }
        .onChange(of: focusRequest) { _, _ in
            DispatchQueue.main.async { isCommentFocused = true }
        }
        #if DEBUG
        .debugViewUpdates("TrackCommentComposer")
        #endif
    }

    private var field: some View {
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

            textField

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
            }
            .buttonStyle(CommentIconButtonStyle())
            .foregroundStyle(.primary)
            .accessibilityLabel(isPosting ? "Posting \(noun)" : "Send \(noun)")
            .contentHelp("Send \(noun) (Return)")
            .disabled(isPosting || !hasMessage)
            .opacity(showsComposerControls ? 1 : 0)
            .allowsHitTesting(showsComposerControls)
            .accessibilityHidden(!showsComposerControls)
            .animation(.easeInOut(duration: 0.15), value: showsComposerControls)
        }
        .padding(5)
        .background {
            Capsule()
                .fill(.primary.opacity(showsComposerBackground ? 0.06 : 0))
                .animation(.easeInOut(duration: 0.15), value: showsComposerBackground)
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
                .animation(.easeInOut(duration: 0.15), value: isCommentFocused)
        }
        .background {
            SearchOutsideClickView(isFocused: isCommentFocused)
        }
        // Align the avatar with the rows while keeping the capsule's inset.
        .padding(.leading, -5)
    }

    @ViewBuilder private var textField: some View {
        let field = TextField("", text: $draft)
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
                if reply != nil {
                    moveInsertionPointToEnd()
                } else {
                    commentTimestampMilliseconds = model.playback.currentTrack?.urn == track.urn
                        ? Int(max(0, model.playback.currentTime) * 1_000) : nil
                }
            }
            .onExitCommand {
                // Close a reply that has nothing beyond its mention; otherwise keep the draft.
                if reply != nil, !hasMessage {
                    onCancel()
                } else {
                    isCommentFocused = false
                }
            }
            .onSubmit { Task { await postComment() } }
            .accessibilityLabel(reply != nil ? "Reply" : "Comment")
            .disabled(isPosting)

        // A reply field is opened on purpose, so it may take focus as it appears.
        if reply == nil {
            field.modifier(PreventAutomaticSearchFocus())
        } else {
            field
        }
    }

    private var noun: String { reply != nil ? "reply" : "comment" }

    private var showsCloseButton: Bool { reply != nil || !draft.isEmpty }

    private var closeLabel: String { reply != nil ? "Cancel reply" : "Discard comment" }

    private func discardDraft() {
        draft = ""
        postingErrorMessage = nil
        isCommentFocused = false
        commentTimestampMilliseconds = nil
    }

    /// Whether the draft says anything beyond a reply's prefilled mention.
    private var hasMessage: Bool {
        var message = Substring(draft)
        if let mention = reply?.mention.trimmingCharacters(in: .whitespaces),
           message.hasPrefix(mention) {
            message = message.dropFirst(mention.count)
        }
        return !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var commentPlaceholder: String {
        if reply != nil { return "Write a reply" }
        guard isCommentFocused, let commentTimestampMilliseconds else {
            return "Write a comment"
        }
        let seconds = commentTimestampMilliseconds / 1_000
        let timestamp = "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
        return "Write a comment at \(timestamp)"
    }

    // A focused text field selects all its text; put the insertion point after the mention instead.
    private func moveInsertionPointToEnd() {
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
                  editor.isFieldEditor, editor.string == draft else { return }
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        }
    }

    private func postComment() async {
        guard !isPosting, hasMessage else { return }
        isPosting = true
        postingErrorMessage = nil
        defer { isPosting = false }
        do {
            let comment = try await model.addTrackComment(
                for: track, body: draft, timestampMilliseconds: commentTimestampMilliseconds
            )
            isCommentFocused = false
            if reply == nil {
                draft = ""
                commentTimestampMilliseconds = nil
            }
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
    let replies: TrackCommentReplies
    let timestampColor: Color
    let onSelectArtist: (SoundCloudUser) -> Void
    let onReplyAdded: (SoundCloudComment, SoundCloudComment) -> Void
    let onDeleted: (SoundCloudComment) -> Void

    @State private var isDeleting = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let avatarSize: CGFloat = 50
    private static let replyAvatarSize: CGFloat = 36
    private static let avatarSpacing: CGFloat = 14

    private var avatarSize: CGFloat { isReply ? Self.replyAvatarSize : Self.avatarSize }

    private var canDelete: Bool {
        guard case let .signedIn(user) = model.auth.state, let urn = user.urn else { return false }
        return comment.user?.urn == urn || track.artist.urn == urn
    }

    var body: some View {
        let replyTarget = TrackCommentReplyTarget(comment)

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                content(canReply: replyTarget != nil, canDelete: canDelete)
                TrackCommentLikeButton(comment: comment, track: track, model: model, likes: likes)
            }

            if let replyTarget {
                // Below the heart's row so opening it does not move the heart.
                TrackCommentReplyComposerSlot(
                    comment: comment,
                    target: replyTarget,
                    track: track,
                    model: model,
                    replies: replies,
                    onReplyAdded: onReplyAdded
                )
                .padding(.leading, avatarSize + Self.avatarSpacing)
            }
        }
        // Dim the comment, and keep it from being liked or answered, while it is deleted.
        .opacity(isDeleting ? 0.4 : 1)
        .disabled(isDeleting)
        .animation(.easeInOut(duration: 0.15), value: isDeleting)
        // Start replies under the body of the comment they answer.
        .padding(.leading, isReply ? Self.avatarSize + Self.avatarSpacing : 0)
    }

    private func content(canReply: Bool, canDelete: Bool) -> some View {
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

                if canReply || canDelete {
                    HStack(spacing: 12) {
                        if canReply {
                            Button("Reply") {
                                withAnimation(reduceMotion ? nil : TrackCommentReplies.animation) {
                                    replies.open(comment)
                                }
                            }
                                .buttonStyle(CommentReplyButtonStyle())
                                .accessibilityLabel("Reply to \(comment.user?.username ?? "comment")")
                        }
                        if canDelete {
                            TrackCommentDeleteButton(
                                comment: comment, track: track, model: model,
                                isDeleting: $isDeleting, onDeleted: onDeleted
                            )
                        }
                    }
                }
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

/// Which comments have a reply composer open. Each comment's state is observed only by
/// its own composer slot, so opening a reply does not update the list or the other rows.
@MainActor
final class TrackCommentReplies {
    /// Opening and closing a composer animate in a transaction, so the rows below it
    /// slide along with it instead of jumping.
    static let animation = Animation.easeInOut(duration: 0.25)

    private var states: [String: TrackCommentReplyState] = [:]

    func state(for comment: SoundCloudComment) -> TrackCommentReplyState {
        if let state = states[comment.urn] { return state }
        let state = TrackCommentReplyState()
        states[comment.urn] = state
        return state
    }

    func open(_ comment: SoundCloudComment) {
        let state = state(for: comment)
        state.isOpen = true
        state.focusRequest += 1
    }

    func close(_ comment: SoundCloudComment) {
        states[comment.urn]?.isOpen = false
    }
}

@MainActor @Observable
final class TrackCommentReplyState {
    fileprivate(set) var isOpen = false
    /// Changes each time the user clicks Reply, so an open composer takes focus again.
    fileprivate(set) var focusRequest = 0
}

private struct TrackCommentReplyComposerSlot: View {
    let comment: SoundCloudComment
    let target: TrackCommentReplyTarget
    let track: SoundCloudTrack
    let model: AppModel
    let replies: TrackCommentReplies
    let onReplyAdded: (SoundCloudComment, SoundCloudComment) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = replies.state(for: comment)
        if state.isOpen {
            TrackCommentComposer(
                track: track,
                model: model,
                reply: target,
                focusRequest: state.focusRequest,
                onCancel: {
                    withAnimation(reduceMotion ? nil : TrackCommentReplies.animation) {
                        replies.close(comment)
                    }
                },
                onCommentAdded: { onReplyAdded($0, comment) }
            )
            // Fades with the animated open and close; Reduce Motion shows it at once.
            .transition(.opacity)
        }
    }
}

// Keep the confirmation and error local; only progress reaches the row, which dims.
private struct TrackCommentDeleteButton: View {
    let comment: SoundCloudComment
    let track: SoundCloudTrack
    let model: AppModel
    @Binding var isDeleting: Bool
    let onDeleted: (SoundCloudComment) -> Void

    @State private var isConfirming = false
    @State private var errorMessage: String?

    var body: some View {
        Button("Delete") { isConfirming = true }
            .buttonStyle(CommentReplyButtonStyle())
            .accessibilityLabel(isDeleting ? "Deleting comment" : "Delete comment")
            .confirmationDialog(
                "Delete this comment?",
                isPresented: $isConfirming,
                titleVisibility: .visible
            ) {
                Button("Delete Comment", role: .destructive) {
                    Task { await delete() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete the comment from SoundCloud.")
            }
            .alert("Could not delete comment", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "Please try again.")
            }
    }

    private func delete() async {
        guard !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await model.deleteTrackComment(comment, on: track)
            onDeleted(comment)
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct CommentReplyButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(isHovering ? .secondary : .tertiary)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .onContentHover { isHovering = $0 }
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
    @State private var isHovering = false

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
                    .foregroundStyle(
                        isLiked ? AnyShapeStyle(Color.accentColor)
                            : count > 0 || isHovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary)
                    )
                    .animation(.easeInOut(duration: 0.15), value: isHovering)
                    .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? 0 : likeTaps)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(CommentIconButtonStyle())
            .onContentHover { isHovering = $0 }
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

private struct CommentIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 28, height: 28)
            .background(.primary.opacity(isHovering && isEnabled ? 0.08 : 0), in: Circle())
            .contentShape(Circle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .pressBounce(configuration.isPressed)
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

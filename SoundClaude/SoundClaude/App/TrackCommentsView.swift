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
    @State private var sortedComments: [SoundCloudComment] = []
    @State private var nextPageURL: URL?
    @State private var loadedPageURLs: Set<URL> = []
    @State private var hasLoaded = false
    @State private var isLoading = false
    // Owned by the list, not the spinner, so scrolling the spinner away does not cancel it.
    @State private var pageTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var artworkAccent: ArtworkAccent?
    @State private var accentArtworkURL: URL?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        let rowTimestampColor = timestampColor

        LazyVStack(alignment: .leading, spacing: 28) {
            TrackCommentComposer(track: track, model: model) { comment in
                comments.removeAll { $0.urn == comment.urn }
                comments.insert(comment, at: 0)
                updateSortedComments()
                onCommentAdded()
            }
            .modifier(FadeInOnAppear())

            ForEach(sortedComments) { comment in
                TrackCommentRow(
                    comment: comment,
                    track: track,
                    model: model,
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

    private func updateSortedComments() {
        sortedComments = comments.sorted(by: sortOrder.precedes)
    }

    private func startLoadingPage() {
        guard pageTask == nil else { return }
        pageTask = Task {
            await loadPage()
            pageTask = nil
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
            let newComments = page.comments.filter { knownURNs.insert($0.urn).inserted }
            if !newComments.isEmpty {
                comments.append(contentsOf: newComments)
                updateSortedComments()
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

private struct TrackCommentRow: View {
    let comment: SoundCloudComment
    let track: SoundCloudTrack
    let model: AppModel
    let timestampColor: Color
    let onSelectArtist: (SoundCloudUser) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if let user = comment.user {
                TrackCommentAvatar(user: user, loader: model.artworkLoader)
            } else {
                Image(systemName: "person.crop.circle")
                    .resizable()
                    .frame(width: 50, height: 50)
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
            .frame(minHeight: 50, alignment: .leading)
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

// Keep the sheet state local so opening a picture does not update the row.
private struct TrackCommentAvatar: View {
    let user: SoundCloudUser
    let loader: ArtworkLoader

    @State private var isShowingPicture = false
    @State private var cachedFullSizePicture: CachedFullSizeArtwork?
    @State private var isHovering = false

    var body: some View {
        let thumbnail = TrackArtworkView(
            artworkURL: user.avatarURL,
            loader: loader,
            size: 50,
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
            // The sheet opens on mouse up; a press skips the hover delay.
            .buttonStyle(TrackCommentAvatarButtonStyle {
                Task { await prefetchFullSizePicture() }
            })
            .contentShape(Circle())
            .onContentHover(in: Circle().path(in: CGRect(x: 0, y: 0, width: 50, height: 50))) {
                isHovering = $0
            }
            .task(id: isHovering ? user.avatarURL : nil) {
                guard isHovering else { return }
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                await prefetchFullSizePicture()
            }
            .contentHelp("View full-size picture")
            .accessibilityLabel("View full-size picture of \(user.username)")
            .sheet(isPresented: $isShowingPicture) {
                FullSizeArtworkView(
                    title: user.username,
                    artworkURL: user.avatarURL,
                    loader: loader,
                    cachedArtwork: $cachedFullSizePicture
                )
            }
        } else {
            thumbnail
        }
    }

    // Seed the sheet's cache so it opens with the picture instead of a spinner.
    // Hover and press share the loader's in-flight request, so this fetches once.
    private func prefetchFullSizePicture() async {
        guard let url = user.avatarURL,
              cachedFullSizePicture?.sourceURL != url,
              // Opening the sheet retries failed prefetches.
              let data = try? await loader.data(for: url, rendition: .original),
              cachedFullSizePicture?.sourceURL != url else { return }
        cachedFullSizePicture = CachedFullSizeArtwork(sourceURL: url, data: data)
    }
}

private struct TrackCommentAvatarButtonStyle: ButtonStyle {
    let onPress: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : 1)
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed { onPress() }
            }
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

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
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                Text("Sort by")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)

                sortMenu
            }
            .fixedSize(horizontal: true, vertical: false)

            sortMenu
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort comments", selection: $sortOrder) {
                ForEach(CommentSortOrder.allCases, id: \.self) { order in
                    Text(order.title)
                        .tag(order)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(sortOrder.title)
                .font(.subheadline)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .opacity(isHovered ? 1 : 0.7)
        .onContentHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovered)
        .accessibilityLabel("Sort comments")
        .accessibilityValue(sortOrder.title)
        .help("Sort comments")
    }
}

struct TrackCommentsView: View {
    let track: SoundCloudTrack
    @ObservedObject var model: AppModel
    let onSelectArtist: (SoundCloudUser) -> Void

    let onCommentAdded: () -> Void

    @AppStorage("commentSortOrder") private var sortOrder = CommentSortOrder.newest
    @State private var draft = ""
    @FocusState private var isCommentFocused: Bool
    @State private var isCommentHovered = false
    @State private var commentTimestampMilliseconds: Int?
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
                .modifier(FadeInOnAppear())

            ForEach(comments.sorted(by: sortOrder.precedes)) { comment in
                commentRow(comment)
                    .modifier(FadeInOnAppear())
            }

            if isLoading {
                ProgressView()
                    .accessibilityLabel("Loading comments")
                    .frame(maxWidth: .infinity)
                    .modifier(FadeInOnAppear())
            } else if let errorMessage {
                VStack(spacing: 8) {
                    Text(errorMessage).foregroundStyle(.secondary)
                    Button("Try Again") { Task { await loadPage() } }
                }
                .frame(maxWidth: .infinity)
                .modifier(FadeInOnAppear())
            } else if nextPageURL != nil {
                Button("Load More") { Task { await loadPage() } }
                    .frame(maxWidth: .infinity)
                    .modifier(FadeInOnAppear())
            }
        }
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
    }

    private var showsComposerControls: Bool {
        isCommentHovered || isCommentFocused || isPosting
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
            .onHover { isCommentHovered = $0 }
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
        .frame(maxWidth: 280, alignment: .leading)
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
            comments.removeAll { $0.urn == comment.urn }
            comments.insert(comment, at: 0)
            draft = ""
            isCommentFocused = false
            commentTimestampMilliseconds = nil
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

    private func commentRow(_ comment: SoundCloudComment) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let user = comment.user {
                Button {
                    onSelectArtist(user)
                } label: {
                    TrackArtworkView(
                        artworkURL: user.avatarURL,
                        loader: model.artworkLoader,
                        size: 40,
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
                .buttonStyle(.plain)
                .help("View artist")
                .accessibilityLabel("View artist: \(user.username)")
            } else {
                Image(systemName: "person.crop.circle")
                    .resizable()
                    .frame(width: 40, height: 40)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let user = comment.user {
                        ArtistLink(
                            artist: user,
                            onSelect: onSelectArtist
                        )
                        .font(.headline)
                        .fontWeight(.medium)
                        .opacity(0.85)
                    } else {
                        Text("Unknown user")
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
                        }
                        .buttonStyle(CommentTimestampButtonStyle(color: timestampColor))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(timestampColor)
                        .help("Jump to \(timeLabel)")
                        .accessibilityLabel("Jump to \(timeLabel) in \(track.title)")
                    }
                    if let createdAt = comment.createdAt {
                        Text(createdAt.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help(createdAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    Spacer()
                }

                ArtistMentionText(comment.body, onSelectArtist: onSelectArtist)
                    .textSelection(.enabled)
                    .foregroundStyle(.primary.opacity(0.95))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
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

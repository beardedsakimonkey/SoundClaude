import SwiftUI

extension NotificationFilter {
    static let storageKey = "notificationsFilter"

    /// The filter the page last showed.
    static var saved: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .all
    }

    var title: String { rawValue.capitalized }

    var systemImage: String {
        switch self {
        case .all: "bell"
        case .likes: "heart"
        case .reposts: "arrow.2.squarepath"
        case .comments: "text.bubble"
        case .follows: "person.badge.plus"
        }
    }

    var emptyTitle: LocalizedStringKey {
        switch self {
        case .all: "No notifications"
        case .likes: "No likes"
        case .reposts: "No reposts"
        case .comments: "No comments"
        case .follows: "No new followers"
        }
    }
}

/// Likes, reposts, comments, mentions, and new followers, as on soundcloud.com/notifications.
struct NotificationsView: View {
    let model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectPlaylist: (SoundCloudPlaylist) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void

    @AppStorage(NotificationFilter.storageKey) private var filter = NotificationFilter.all
    @State private var isRefreshing = false
    @State private var refreshErrorMessage: String?
    /// Changes after a refresh, so the list starts over from the reloaded first page.
    @State private var refreshCount = 0

    private struct ListID: Hashable {
        let filter: NotificationFilter
        let refreshCount: Int
    }

    var body: some View {
        ScrollbarReservedScrollView { _ in
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Notifications")
                            .font(.largeTitle.weight(.semibold))
                        Spacer()
                        RefreshButton(title: "Refresh notifications", isLoading: isRefreshing) {
                            Task { await refresh() }
                        }
                    }

                    TabPicker(
                        title: "Notification type",
                        options: NotificationFilter.allCases,
                        selection: $filter,
                        optionSystemImage: \.systemImage,
                        optionText: \.title,
                        allowsIconOnly: true,
                        horizontalPadding: 12,
                        prefetch: { .notifications($0) }
                    )
                    .font(.body.weight(.semibold))
                }

                if let refreshErrorMessage {
                    Label(refreshErrorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.accentColor)
                }

                // A new list per filter, so a page loading for the old one is dropped.
                NotificationList(
                    filter: filter,
                    model: model,
                    onSelectTrack: onSelectTrack,
                    onSelectPlaylist: onSelectPlaylist,
                    onSelectArtist: onSelectArtist
                )
                .id(ListID(filter: filter, refreshCount: refreshCount))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .remembersScrollPosition()
        }
        .background(alignment: .top) {
            RouteGradientBackdrop()
        }
        .navigationTitle("Notifications")
        .onChange(of: filter) { refreshErrorMessage = nil }
    }

    /// Keeps the current list until the reloaded first page arrives.
    private func refresh() async {
        isRefreshing = true
        refreshErrorMessage = nil
        defer { isRefreshing = false }
        let filter = filter
        do {
            try await model.reloadNotifications(filter: filter)
            if filter == self.filter { refreshCount += 1 }
        } catch {
            if filter == self.filter { refreshErrorMessage = error.localizedDescription }
        }
    }
}

private struct NotificationList: View {
    let filter: NotificationFilter
    let model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectPlaylist: (SoundCloudPlaylist) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void

    @State private var notifications: [SoundCloudNotification]
    @State private var nextPageURL: URL?
    @State private var loadedPageURLs: Set<URL> = []
    @State private var hasLoaded: Bool
    @State private var errorMessage: String?

    init(
        filter: NotificationFilter,
        model: AppModel,
        onSelectTrack: @escaping (SoundCloudTrack) -> Void,
        onSelectPlaylist: @escaping (SoundCloudPlaylist) -> Void,
        onSelectArtist: @escaping (SoundCloudUser) -> Void
    ) {
        self.filter = filter
        self.model = model
        self.onSelectTrack = onSelectTrack
        self.onSelectPlaylist = onSelectPlaylist
        self.onSelectArtist = onSelectArtist
        // The account menu's hover, a tab's hover, a refresh, or an earlier visit
        // may have loaded the first page.
        let firstPage = model.cachedFirstNotificationPage(filter: filter)
        _notifications = State(initialValue: firstPage?.notifications ?? [])
        _nextPageURL = State(initialValue: firstPage?.nextURL)
        _hasLoaded = State(initialValue: firstPage != nil)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            ForEach(notifications) { notification in
                NotificationRow(
                    notification: notification,
                    model: model,
                    onSelectTrack: onSelectTrack,
                    onSelectPlaylist: onSelectPlaylist,
                    onSelectArtist: onSelectArtist
                )
                .modifier(FadeInOnAppear())
            }

            if let errorMessage {
                VStack(spacing: 8) {
                    Text(errorMessage).foregroundStyle(.secondary)
                    // Brings back the spinner, which loads the page.
                    Button("Try Again") { self.errorMessage = nil }
                }
                .frame(maxWidth: .infinity)
            } else if !hasLoaded || nextPageURL != nil {
                LoadingSpinner()
                    .accessibilityLabel("Loading notifications")
                    .frame(maxWidth: .infinity)
                    .task { await loadPage() }
                    // A new spinner per page, so an empty page moves on to the next.
                    .id(nextPageURL)
            } else if notifications.isEmpty {
                EmptyStateView(filter.emptyTitle)
            }
        }
        .padding(.top, 8)
    }

    private func loadPage() async {
        let pageURL = nextPageURL
        do {
            let page = try await model.notifications(filter: filter, pageURL: pageURL)
            try Task.checkCancellation()
            // The client rejects a page that links to itself; this catches longer loops.
            if let nextURL = page.nextURL, loadedPageURLs.contains(nextURL) {
                throw SoundCloudError.invalidData
            }
            var knownIDs = Set(notifications.map(\.id))
            notifications.append(contentsOf: page.notifications.filter { knownIDs.insert($0.id).inserted })
            if let pageURL { loadedPageURLs.insert(pageURL) }
            nextPageURL = page.nextURL
            hasLoaded = true
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}

private struct NotificationRow: View {
    let notification: SoundCloudNotification
    let model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectPlaylist: (SoundCloudPlaylist) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void

    private var user: SoundCloudUser { notification.user }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    ArtistLink(
                        artist: user,
                        showsVerifiedBadge: true,
                        helpTitle: "View profile",
                        onSelect: onSelectArtist
                    )
                    .fontWeight(.semibold)
                    Text(actionDescription)
                        .foregroundStyle(.secondary)
                        // Truncate the username first.
                        .layoutPriority(1)
                }
                .lineLimit(1)

                if let content = notification.content {
                    NotificationContentLink(content: content) { select(content) }
                }

                if let comment = notification.comment {
                    ArtistMentionText(comment.body, isQuoted: true, onSelectArtist: onSelectArtist)
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }

                RelativeTimestampView(
                    date: notification.createdAt,
                    accessibilityPrefix: "Received",
                    showsSeparator: false
                )
                .foregroundStyle(.secondary)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let content = notification.content {
                Button {
                    select(content)
                } label: {
                    TrackArtworkView(
                        artworkURL: content.displayArtworkURL,
                        loader: model.artworkLoader,
                        size: 48
                    )
                }
                .buttonStyle(.plain)
                .prefetch(content.prefetchTarget)
                .contentHelp(content.title)
                // The title links to the same page.
                .accessibilityHidden(true)
            } else if notification.kind == .follow, user.urn != nil {
                NotificationFollowButton(user: user, model: model)
            }
        }
    }

    private var avatar: some View {
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
                Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1)
            }
            .overlay(alignment: .bottomTrailing) {
                kindBadge.offset(x: 4, y: 4)
            }
        }
        .buttonStyle(.plain)
        .prefetch(.artist(user))
        .contentHelp("View profile: \(user.username)")
        // The username links to the same page.
        .accessibilityHidden(true)
    }

    private var kindBadge: some View {
        Image(systemName: kindSystemImage)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(notification.kind == .like ? Color.pink : Color.primary)
            .frame(width: 18, height: 18)
            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
            .overlay {
                Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }

    private var kindSystemImage: String {
        switch notification.kind {
        case .like: "heart.fill"
        case .repost: "arrow.2.squarepath"
        case .comment: "text.bubble.fill"
        case .mention: "at"
        case .follow: "person.fill"
        }
    }

    private var actionDescription: String {
        let noun = switch notification.content {
        case let .playlist(playlist): playlist.isAlbum == true ? "album" : "playlist"
        case .track, nil: "track"
        }
        return switch notification.kind {
        case .like: "liked your \(noun)"
        case .repost: "reposted your \(noun)"
        case .comment: notification.content == nil ? "commented" : "commented on your track"
        case .mention: "mentioned you in a comment"
        case .follow: "started following you"
        }
    }

    private func select(_ content: SoundCloudFeedContent) {
        switch content {
        case let .track(track): onSelectTrack(track)
        case let .playlist(playlist): onSelectPlaylist(playlist)
        }
    }
}

/// Owns its hover state, so hovering the title does not update the whole row.
private struct NotificationContentLink: View {
    let content: SoundCloudFeedContent
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            Text(content.title)
                .underline(isHovering)
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .prefetch(content.prefetchTarget) { isHovering = $0 }
        .contentHelp(content.title)
    }
}

private extension SoundCloudFeedContent {
    var prefetchTarget: PrefetchTarget {
        switch self {
        case let .track(track): .track(track)
        case let .playlist(playlist): .playlist(playlist)
        }
    }
}

/// Follows a new follower back, or shows that you already follow them.
private struct NotificationFollowButton: View {
    let user: SoundCloudUser
    let model: AppModel

    @State private var isFollowing: Bool?
    @State private var isUpdating = false
    @State private var errorMessage: String?

    init(user: SoundCloudUser, model: AppModel) {
        self.user = user
        self.model = model
        _isFollowing = State(initialValue: model.cachedIsFollowingArtist(user))
    }

    var body: some View {
        let isLoading = isUpdating || (isFollowing == nil && errorMessage == nil)

        Button {
            Task { await toggle() }
        } label: {
            Label {
                Text(isFollowing == true ? "Following" : "Follow back")
            } icon: {
                Image(systemName: isFollowing == true ? "person.fill.checkmark" : "person.badge.plus")
                    .opacity(isLoading ? 0 : 1)
                    .overlay {
                        if isLoading {
                            LoadingSpinner()
                                .controlSize(.mini)
                                .accessibilityHidden(true)
                        }
                    }
            }
            .labelStyle(.titleAndIcon)
        }
        .controlSize(.small)
        .disabled(isFollowing == nil || isUpdating)
        .contentHelp(errorMessage ?? (isFollowing == true ? "Unfollow \(user.username)" : "Follow \(user.username)"))
        .accessibilityValue(isLoading ? "Loading follow status" : "")
        .fixedSize()
        .task { await loadStatus() }
    }

    private func loadStatus() async {
        guard isFollowing == nil else { return }
        do {
            let followed = try await model.isFollowingArtist(user)
            try Task.checkCancellation()
            isFollowing = followed
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func toggle() async {
        guard let isFollowing, !isUpdating else { return }
        isUpdating = true
        errorMessage = nil
        defer { isUpdating = false }
        do {
            try await model.setArtistFollowed(user, isFollowed: !isFollowing)
            self.isFollowing = !isFollowing
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

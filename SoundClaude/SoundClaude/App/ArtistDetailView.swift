import AppKit
import SwiftUI

struct ArtistDetailView: View {
    private enum ContentTab: String, CaseIterable, Identifiable {
        case tracks = "Tracks"
        case reposts = "Reposts"
        case playlists = "Playlists"
        case likes = "Likes"

        var id: Self { self }
    }

    @Environment(\.colorScheme) private var colorScheme

    let artist: SoundCloudUser
    @ObservedObject var model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    let onSelectUsers: (SoundCloudUser, ArtistUserList) -> Void
    let onSelectPlaylist: (SoundCloudPlaylist) -> Void

    @State private var isFollowing: Bool?
    @State private var isUpdatingFollow = false
    @State private var followErrorMessage: String?
    @State private var followerCountAdjustment = 0
    @State private var headerImage: NSImage?
    @State private var headerImageURL: URL?
    @State private var details: SoundCloudArtistDetails?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var tracks: [SoundCloudTrack] = []
    @State private var nextPageURL: URL?
    @State private var loadedPageURLs: Set<URL> = []
    @State private var hasLoadedTracks = false
    @State private var isLoadingTracks = false
    @State private var tracksErrorMessage: String?
    @State private var selectedTab = ContentTab.tracks
    @State private var reposts: [SoundCloudTrack] = []
    @State private var repostsNextPageURL: URL?
    @State private var loadedRepostsPageURLs: Set<URL> = []
    @State private var hasLoadedReposts = false
    @State private var isLoadingReposts = false
    @State private var repostsErrorMessage: String?
    @State private var likes: [SoundCloudTrack] = []
    @State private var likesNextPageURL: URL?
    @State private var loadedLikesPageURLs: Set<URL> = []
    @State private var hasLoadedLikes = false
    @State private var isLoadingLikes = false
    @State private var likesErrorMessage: String?
    @State private var playlists: [SoundCloudPlaylist] = []
    @State private var playlistsNextPageURL: URL?
    @State private var loadedPlaylistsPageURLs: Set<URL> = []
    @State private var hasLoadedPlaylists = false
    @State private var isLoadingPlaylists = false
    @State private var playlistsErrorMessage: String?
    @State private var isShowingArtwork = false
    @State private var isHoveringArtwork = false
    @State private var cachedFullSizeArtwork: CachedFullSizeArtwork?

    init(
        artist: SoundCloudUser,
        model: AppModel,
        onSelectTrack: @escaping (SoundCloudTrack) -> Void,
        onSelectArtist: @escaping (SoundCloudUser) -> Void,
        onSelectPlaylist: @escaping (SoundCloudPlaylist) -> Void,
        onSelectUsers: @escaping (SoundCloudUser, ArtistUserList) -> Void
    ) {
        self.artist = artist
        self.model = model
        self.onSelectTrack = onSelectTrack
        self.onSelectArtist = onSelectArtist
        self.onSelectUsers = onSelectUsers
        self.onSelectPlaylist = onSelectPlaylist
        let cached = model.cachedArtistDetails(for: artist)
        _details = State(initialValue: cached)
        _isLoading = State(initialValue: cached == nil)
        let cachedHeader = model.cachedArtistHeader(for: artist)
        _headerImage = State(initialValue: cachedHeader?.image)
        _headerImageURL = State(initialValue: cachedHeader?.artworkURL)
    }

    var body: some View {
        ZStack(alignment: .top) {
            artworkBackdrop
                .ignoresSafeArea(edges: .top)

            if let details {
                detailsView(details)
            } else if isLoading {
                ProgressView("Loading artist")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("Could not load artist", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage ?? "An unknown error occurred.")
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            }
        }
        .navigationTitle(details?.user.username ?? artist.username)
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible, placement: .primaryAction)
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Spacer()
                }
            }
            ToolbarItem(placement: .primaryAction) {
                OpenInSoundCloudButton(url: details?.user.permalinkURL ?? artist.permalinkURL)
                    .help("Open this artist in your web browser")
            }
        }
        .task(id: artist.permalinkURL) { await load() }
        .task(id: artist.permalinkURL) {
            guard headerImage == nil,
                  let header = try? await model.artistHeader(for: artist),
                  !Task.isCancelled else { return }
            headerImage = header.image
            headerImageURL = header.artworkURL
        }
        .task(id: details?.user.urn) {
            await loadFollowStatus()
        }
        .onChange(of: selectedTab) { _, tab in
            guard tab == .reposts, !hasLoadedReposts else { return }
            Task { await loadReposts() }
        }
        .sheet(isPresented: $isShowingArtwork) {
            FullSizeArtworkView(
                title: details?.user.username ?? artist.username,
                artworkURL: details?.user.avatarURL ?? artist.avatarURL,
                loader: model.artworkLoader,
                cachedArtwork: $cachedFullSizeArtwork
            )
        }
    }

    @ViewBuilder
    private var artworkBackdrop: some View {
        let backdrop = TrackArtworkBackdropView(
            artworkURL: headerImageURL,
            loader: model.artworkLoader,
            cachedImage: headerImage
        )
        .frame(height: 460)

        if #available(macOS 26.0, *) {
            backdrop.backgroundExtensionEffect()
        } else {
            backdrop
        }
    }

    private func detailsView(_ details: SoundCloudArtistDetails) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top, spacing: 24) {
                        artistPicture(for: details.user)
                        VStack(alignment: .leading, spacing: 10) {
                            Text(details.user.username)
                                .font(.system(size: 36, weight: .semibold))
                                .opacity(0.9)
                                .textSelection(.enabled)
                            let location = [details.city, details.country]
                                .compactMap(nonempty).joined(separator: ", ")
                            if !location.isEmpty {
                                Text(location)
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            }
                            if canFollowArtist {
                                followControls
                            }
                        }
                        .padding(headerImage == nil ? 0 : 16)
                        .background {
                            if headerImage != nil {
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(.thinMaterial)
                            }
                        }
                    }

                    HStack(spacing: 24) {
                        userStatistic(details.followersCount.map { max(0, $0 + followerCountAdjustment) }, list: .followers, user: details.user)
                        userStatistic(details.followingsCount, list: .following, user: details.user)
                        statistic(details.trackCount, label: "tracks")
                    }
                    .padding(headerImage == nil ? 0 : 12)
                    .background {
                        if headerImage != nil {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(.thinMaterial)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: 260, alignment: .leading)
                .background {
                    if let headerImage {
                        GeometryReader { geometry in
                            Image(nsImage: headerImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .clipped()
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                        }
                        .padding(.horizontal, 10)
                        .accessibilityHidden(true)
                    }
                }
                .environment(\.colorScheme, headerImage == nil ? colorScheme : .dark)
                .padding(.horizontal, -24)
                .padding(.top, -24)

                if let description = nonempty(details.description) {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("About")
                            .font(.headline)
                            .opacity(0.96)
                        ExpandableDescriptionText(
                            description: description,
                            onSelectArtist: onSelectArtist
                        )
                        .id(artist.permalinkURL)
                    }
                }

                Divider()
                TabPicker(
                    title: "Artist content",
                    options: ContentTab.allCases,
                    selection: $selectedTab
                )
                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                switch selectedTab {
                case .tracks:
                    trackList
                case .reposts:
                    repostList
                case .playlists:
                    playlistList
                case .likes:
                    likesList
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    private var canFollowArtist: Bool {
        guard let user = details?.user, user.urn != nil,
              case let .signedIn(account) = model.auth.state else { return false }
        return user.urn != account.urn && user.permalinkURL != account.permalinkURL
    }

    private var followControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    Task { await toggleFollow() }
                } label: {
                    Label(isFollowing == true ? "Unfollow" : "Follow",
                          systemImage: isFollowing == true ? "person.badge.minus" : "person.badge.plus")
                }
                .disabled(isFollowing == nil || isUpdatingFollow)
                if isUpdatingFollow || (isFollowing == nil && followErrorMessage == nil) {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Loading follow status")
                }
            }
            if let followErrorMessage {
                Text(followErrorMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if isFollowing == nil {
                    Button("Try Again") { Task { await loadFollowStatus() } }
                }
            }
        }
    }

    private func loadFollowStatus() async {
        guard canFollowArtist, let user = details?.user else { return }
        isFollowing = nil
        followErrorMessage = nil
        do {
            let followed = try await model.isFollowingArtist(user)
            try Task.checkCancellation()
            isFollowing = followed
        } catch {
            guard !Task.isCancelled else { return }
            followErrorMessage = error.localizedDescription
        }
    }

    private func toggleFollow() async {
        guard let isFollowing, !isUpdatingFollow, let user = details?.user else { return }
        isUpdatingFollow = true
        followErrorMessage = nil
        defer { isUpdatingFollow = false }
        do {
            try await model.setArtistFollowed(user, isFollowed: !isFollowing)
            self.isFollowing = !isFollowing
            followerCountAdjustment += isFollowing ? -1 : 1
        } catch {
            followErrorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private func artistPicture(for user: SoundCloudUser) -> some View {
        let avatarURL = user.avatarURL ?? artist.avatarURL
        let thumbnail = TrackArtworkView(
            artworkURL: avatarURL,
            loader: model.artworkLoader,
            size: 180,
            rendition: .square500
        )
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1) }

        if avatarURL != nil {
            Button {
                isShowingArtwork = true
            } label: {
                thumbnail
                    .artworkExpandIndicator(isHovering: isHoveringArtwork)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .onContentHover { isHoveringArtwork = $0 }
            .help("View full-size artist picture")
            .accessibilityLabel("View full-size picture of \(user.username)")
        } else {
            thumbnail
        }
    }

    private var trackList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(tracks) { track in
                TrackListRow(
                    track: track,
                    playback: model.playback,
                    artworkLoader: model.artworkLoader,
                    likes: model.likes,
                    onSelectTrack: onSelectTrack,
                    onSelectArtist: onSelectArtist,
                    onPlayTrack: { selected in
                        await model.play(selected, queue: TrackQueue(
                            source: .artist(details?.user.urn ?? artist.urn ?? ""),
                            tracks: tracks,
                            nextPageURL: nextPageURL
                        ))
                    }
                )
            }
            if let tracksErrorMessage {
                Text(tracksErrorMessage).foregroundStyle(.secondary)
                Button("Try Again") { Task { await loadTracks() } }
                    .disabled(isLoadingTracks)
            }
            if isLoadingTracks || (nextPageURL != nil && tracksErrorMessage == nil) {
                ProgressView("Loading tracks")
                    .frame(maxWidth: .infinity)
                    .task(id: nextPageURL) {
                        guard nextPageURL != nil, tracksErrorMessage == nil else { return }
                        await loadTracks()
                    }
            } else if hasLoadedTracks, tracks.isEmpty, tracksErrorMessage == nil {
                ContentUnavailableView(
                    "No playable tracks",
                    systemImage: "music.note",
                    description: Text("This artist has no tracks available for playback here.")
                )
            }
        }
    }

    private var repostList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(reposts) { track in
                TrackListRow(
                    track: track,
                    playback: model.playback,
                    artworkLoader: model.artworkLoader,
                    likes: model.likes,
                    onSelectTrack: onSelectTrack,
                    onSelectArtist: onSelectArtist,
                    onPlayTrack: { selected in
                        await model.play(selected, queue: TrackQueue(
                            source: .artistReposts(details?.user.urn ?? artist.urn ?? ""),
                            tracks: reposts,
                            nextPageURL: repostsNextPageURL
                        ))
                    }
                )
            }
            if let repostsErrorMessage {
                Text(repostsErrorMessage).foregroundStyle(.secondary)
                Button("Try Again") { Task { await loadReposts() } }
                    .disabled(isLoadingReposts)
            }
            if isLoadingReposts
                || (repostsNextPageURL != nil && repostsErrorMessage == nil) {
                ProgressView("Loading reposts")
                    .frame(maxWidth: .infinity)
                    .task(id: repostsNextPageURL) {
                        guard repostsNextPageURL != nil,
                              repostsErrorMessage == nil else { return }
                        await loadReposts()
                    }
            } else if hasLoadedReposts, reposts.isEmpty,
                      repostsErrorMessage == nil {
                ContentUnavailableView(
                    "No playable reposts",
                    systemImage: "arrow.2.squarepath",
                    description: Text("This artist has no reposted tracks available for playback here.")
                )
            }
        }
    }

    private var likesList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(likes) { track in
                TrackListRow(
                    track: track,
                    playback: model.playback,
                    artworkLoader: model.artworkLoader,
                    likes: model.likes,
                    onSelectTrack: onSelectTrack,
                    onSelectArtist: onSelectArtist,
                    onPlayTrack: { selected in
                        await model.play(selected, queue: TrackQueue(
                            source: .artistLikes(details?.user.urn ?? artist.urn ?? ""),
                            tracks: likes,
                            nextPageURL: likesNextPageURL
                        ))
                    }
                )
            }
            if let likesErrorMessage {
                Text(likesErrorMessage).foregroundStyle(.secondary)
                Button("Try Again") { Task { await loadLikes() } }
                    .disabled(isLoadingLikes)
            }
            if isLoadingLikes
                || (likesNextPageURL != nil && likesErrorMessage == nil) {
                ProgressView("Loading likes")
                    .frame(maxWidth: .infinity)
                    .task(id: likesNextPageURL) {
                        guard likesNextPageURL != nil,
                              likesErrorMessage == nil else { return }
                        await loadLikes()
                    }
            } else if hasLoadedLikes, likes.isEmpty,
                      likesErrorMessage == nil {
                ContentUnavailableView(
                    "No playable likes",
                    systemImage: "heart",
                    description: Text("This artist has no liked tracks available for playback here.")
                )
            }
        }
        .task {
            guard !hasLoadedLikes else { return }
            await loadLikes()
        }
    }

    private var playlistList: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(playlists) { playlist in
                PlaylistCardView(
                    playlist: playlist,
                    model: model,
                    playlists: model.playlists,
                    onSelectPlaylist: onSelectPlaylist,
                    onSelectTrack: onSelectTrack,
                    onSelectArtist: onSelectArtist
                )
            }
            if let playlistsErrorMessage {
                Text(playlistsErrorMessage).foregroundStyle(.secondary)
                Button("Try Again") { Task { await loadPlaylists() } }
                    .disabled(isLoadingPlaylists)
            }
            if isLoadingPlaylists
                || (playlistsNextPageURL != nil && playlistsErrorMessage == nil) {
                ProgressView("Loading playlists")
                    .frame(maxWidth: .infinity)
                    .task(id: playlistsNextPageURL) {
                        guard playlistsNextPageURL != nil,
                              playlistsErrorMessage == nil else { return }
                        await loadPlaylists()
                    }
            } else if hasLoadedPlaylists, playlists.isEmpty,
                      playlistsErrorMessage == nil {
                ContentUnavailableView(
                    "No playlists",
                    systemImage: "music.note.list",
                    description: Text("This artist has no playlists available here.")
                )
            }
        }
        .task {
            guard !hasLoadedPlaylists else { return }
            await loadPlaylists()
        }
    }

    @ViewBuilder
    private func userStatistic(_ count: Int?, list: ArtistUserList, user: SoundCloudUser) -> some View {
        if let count {
            Button {
                onSelectUsers(user, list)
            } label: {
                Text("\(count.formatted()) \(list.title.lowercased())")
                    .font(.callout)
                    .underline()
            }
            .buttonStyle(.plain)
            .help("View \(list.title.lowercased()) of \(user.username)")
        }
    }

    @ViewBuilder
    private func statistic(_ count: Int?, label: String) -> some View {
        if let count {
            Text("\(count.formatted()) \(label)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func nonempty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func load() async {
        isLoading = details == nil
        errorMessage = nil
        defer { isLoading = false }
        do {
            let loaded = try await model.artistDetails(for: artist)
            try Task.checkCancellation()
            details = loaded
            if !hasLoadedTracks { await loadTracks() }
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func loadTracks() async {
        guard !isLoadingTracks, let details,
              !hasLoadedTracks || nextPageURL != nil else { return }
        isLoadingTracks = true
        tracksErrorMessage = nil
        defer { isLoadingTracks = false }
        do {
            let pageURL = nextPageURL
            let page = try await model.artistTracks(for: details.user, pageURL: pageURL)
            try Task.checkCancellation()
            if let nextURL = page.nextURL,
               nextURL == pageURL || loadedPageURLs.contains(nextURL) {
                throw SoundCloudError.invalidData
            }
            var knownURNs = Set(tracks.map(\.urn))
            tracks.append(contentsOf: page.tracks.filter { knownURNs.insert($0.urn).inserted })
            if let pageURL { loadedPageURLs.insert(pageURL) }
            nextPageURL = page.nextURL
            hasLoadedTracks = true
        } catch {
            guard !Task.isCancelled else { return }
            tracksErrorMessage = error.localizedDescription
        }
    }

    private func loadPlaylists() async {
        guard !isLoadingPlaylists, let details,
              !hasLoadedPlaylists || playlistsNextPageURL != nil else { return }
        isLoadingPlaylists = true
        playlistsErrorMessage = nil
        defer { isLoadingPlaylists = false }
        do {
            let pageURL = playlistsNextPageURL
            let page = try await model.artistPlaylists(for: details.user, pageURL: pageURL)
            try Task.checkCancellation()
            if let nextURL = page.nextURL,
               nextURL == pageURL || loadedPlaylistsPageURLs.contains(nextURL) {
                throw SoundCloudError.invalidData
            }
            var knownURNs = Set(playlists.map(\.urn))
            playlists.append(contentsOf: page.playlists.filter {
                knownURNs.insert($0.urn).inserted
            })
            if let pageURL { loadedPlaylistsPageURLs.insert(pageURL) }
            playlistsNextPageURL = page.nextURL
            hasLoadedPlaylists = true
        } catch {
            guard !Task.isCancelled else { return }
            playlistsErrorMessage = error.localizedDescription
        }
    }

    private func loadReposts() async {
        guard !isLoadingReposts, let details,
              !hasLoadedReposts || repostsNextPageURL != nil else { return }
        isLoadingReposts = true
        repostsErrorMessage = nil
        defer { isLoadingReposts = false }
        do {
            let pageURL = repostsNextPageURL
            let page = try await model.artistReposts(for: details.user, pageURL: pageURL)
            try Task.checkCancellation()
            if let nextURL = page.nextURL,
               nextURL == pageURL || loadedRepostsPageURLs.contains(nextURL) {
                throw SoundCloudError.invalidData
            }
            var knownURNs = Set(reposts.map(\.urn))
            reposts.append(contentsOf: page.tracks.filter {
                knownURNs.insert($0.urn).inserted
            })
            if let pageURL { loadedRepostsPageURLs.insert(pageURL) }
            repostsNextPageURL = page.nextURL
            hasLoadedReposts = true
        } catch {
            guard !Task.isCancelled else { return }
            repostsErrorMessage = error.localizedDescription
        }
    }
    private func loadLikes() async {
        guard !isLoadingLikes, let details,
              !hasLoadedLikes || likesNextPageURL != nil else { return }
        isLoadingLikes = true
        likesErrorMessage = nil
        defer { isLoadingLikes = false }
        do {
            let pageURL = likesNextPageURL
            let page = try await model.artistLikes(for: details.user, pageURL: pageURL)
            try Task.checkCancellation()
            if let nextURL = page.nextURL,
               nextURL == pageURL || loadedLikesPageURLs.contains(nextURL) {
                throw SoundCloudError.invalidData
            }
            var knownURNs = Set(likes.map(\.urn))
            likes.append(contentsOf: page.tracks.filter {
                knownURNs.insert($0.urn).inserted
            })
            if let pageURL { loadedLikesPageURLs.insert(pageURL) }
            likesNextPageURL = page.nextURL
            hasLoadedLikes = true
        } catch {
            guard !Task.isCancelled else { return }
            likesErrorMessage = error.localizedDescription
        }
    }
}

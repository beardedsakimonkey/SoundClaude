import AppKit
import SwiftUI

struct ArtistDetailView: View {
    private struct ArtistActionButtonStyle: ButtonStyle {
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovering = false

        func makeBody(configuration: Configuration) -> some View {
            let shape = RoundedRectangle(cornerRadius: 6)

            configuration.label
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(.primary.opacity(0.12), in: shape)
                .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.5)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isEnabled)
                .overlay {
                    shape
                        .fill(.primary.opacity(isHovering && isEnabled ? 0.08 : 0))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovering && isEnabled)
                .contentShape(shape)
                .onContentHover { isHovering = $0 }
        }
    }

    private struct ImageButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
        }
    }

    private struct ArtistPictureButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .overlay {
                    Circle()
                        .fill(.black.opacity(configuration.isPressed ? 0.25 : 0))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        }
    }

    private enum ContentTab: String, CaseIterable, Identifiable {
        case tracks = "Tracks"
        case reposts = "Reposts"
        case playlists = "Playlists"
        case likes = "Likes"

        var id: Self { self }

        var systemImage: String {
            switch self {
            case .tracks: "music.note"
            case .reposts: "arrow.2.squarepath"
            case .playlists: "music.note.list"
            case .likes: "heart"
            }
        }
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let artist: SoundCloudUser
    @ObservedObject var model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    let onSelectUsers: (SoundCloudUser, ArtistUserList) -> Void
    let onSelectPlaylist: (SoundCloudPlaylist) -> Void
    let onSelectStation: (String, String) -> Void

    @State private var scrollerStyle = NSScroller.preferredScrollerStyle
    @State private var isFollowing: Bool?
    @State private var isUpdatingFollow = false
    @State private var isShufflingTracks = false
    @State private var followErrorMessage: String?
    @State private var followerCountAdjustment = 0
    @State private var hoveredStatistic: String?
    @State private var headerImage: NSImage?
    @State private var headerImageURL: URL?
    @State private var isHeaderImageMissing = false
    @State private var isHeaderImageVisible = false
    @State private var isHeaderContentHidden = false
    @State private var details: SoundCloudArtistDetails?
    @State private var webProfiles: [SoundCloudWebProfile] = []
    @State private var webProfilesErrorMessage: String?
    @State private var hoveredWebProfileURL: URL?
    @State private var relatedArtists: [SoundCloudUser] = []
    @State private var relatedArtistsPage = 0
    private let relatedArtistsPageSize = 3
    @State private var isLoadingRelatedArtists = false
    @State private var relatedArtistsErrorMessage: String?
    @State private var hoveredRelatedArtistURL: URL?
    @State private var isHoveringRelatedRefresh = false
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
        onSelectUsers: @escaping (SoundCloudUser, ArtistUserList) -> Void,
        onSelectStation: @escaping (String, String) -> Void
    ) {
        self.artist = artist
        self.model = model
        self.onSelectTrack = onSelectTrack
        self.onSelectArtist = onSelectArtist
        self.onSelectUsers = onSelectUsers
        self.onSelectPlaylist = onSelectPlaylist
        self.onSelectStation = onSelectStation
        let cached = model.cachedArtistDetails(for: artist)
        _details = State(initialValue: cached)
        _isLoading = State(initialValue: cached == nil)
        let cachedHeader = model.cachedArtistHeader(for: artist)
        _headerImage = State(initialValue: cachedHeader?.image)
        _headerImageURL = State(initialValue: cachedHeader?.artworkURL)
        _isHeaderImageVisible = State(initialValue: cachedHeader != nil)
    }

    var body: some View {
        ZStack(alignment: .top) {
            artworkBackdrop
                .ignoresSafeArea(edges: .top)

            if let details {
                detailsView(details)
            } else if isLoading {
                ProgressView()
                    .accessibilityLabel("Loading artist")
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
        .task(id: isShufflingTracks) {
            if isShufflingTracks { await shuffleTracks() }
        }
        .task(id: artist.permalinkURL) {
            guard headerImage == nil, !isHeaderImageMissing else { return }
            do {
                let header = try await model.artistHeader(for: artist)
                try Task.checkCancellation()
                headerImage = header?.image
                headerImageURL = header?.artworkURL
                isHeaderImageMissing = header == nil
            } catch {
                // A failed lookup does not confirm that the header is absent.
            }
        }
        .task(id: details?.user.urn) {
            await loadFollowStatus()
        }
        .task(id: details?.user.urn) {
            await loadWebProfiles()
        }
        .task(id: details?.user.urn) {
            await loadRelatedArtists()
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
            artworkURL: headerImageURL ?? (isHeaderImageMissing ? details?.user.avatarURL ?? artist.avatarURL : nil),
            loader: model.artworkLoader,
            fadesToBottom: false,
            cachedImage: headerImage
        )
        .frame(height: 600)
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.25),
                    .init(color: .black.opacity(0.5), location: 0.65),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }

        if #available(macOS 26.0, *) {
            backdrop.backgroundExtensionEffect()
        } else {
            backdrop
        }
    }

    private func detailsView(_ details: SoundCloudArtistDetails) -> some View {
        GeometryReader { geometry in
            let scrollbarWidth = scrollerStyle == .legacy
                ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
                : 0
            let contentWidth = max(0, geometry.size.width - scrollbarWidth)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack(alignment: .center, spacing: 24) {
                            artistPicture(for: details.user)
                            VStack(alignment: .leading, spacing: 10) {
                                Text(details.user.username)
                                    .font(.system(size: 36, weight: .semibold))
                                    .textSelection(.enabled)
                                if let fullName = nonempty(details.user.fullName) {
                                    Text(fullName)
                                        .font(.title3)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(headerImage == nil ? 0 : 16)
                            .background {
                                if headerImage != nil {
                                    RoundedRectangle(cornerRadius: 16)
                                        .fill(.ultraThinMaterial)
                                }
                            }
                        }
                        .opacity(isHeaderContentHidden ? 0 : 1)
                        .allowsHitTesting(!isHeaderContentHidden)
                        .accessibilityHidden(isHeaderContentHidden)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, minHeight: 260, alignment: .leading)
                    .background {
                        if let headerImage {
                            Button {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    isHeaderContentHidden.toggle()
                                }
                            } label: {
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
                                .contentShape(RoundedRectangle(cornerRadius: 16))
                            }
                            .buttonStyle(ImageButtonStyle())
                            .padding(.horizontal, 10)
                            .opacity(isHeaderImageVisible ? 1 : 0)
                            .onAppear {
                                guard !isHeaderImageVisible else { return }
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                                    isHeaderImageVisible = true
                                }
                            }
                            .accessibilityLabel(isHeaderContentHidden ? "Show artist information" : "Hide artist information")
                        }
                    }
                    .environment(\.colorScheme, headerImage == nil ? colorScheme : .dark)
                    .padding(.horizontal, -24)
                    .padding(.top, -24)
                    .padding(.bottom, -12)

                    HStack {
                        TabPicker(
                            title: "Artist content",
                            options: ContentTab.allCases,
                            selection: $selectedTab,
                            optionCount: tabCount,
                            optionSystemImage: { $0.systemImage },
                            allowsIconOnly: true
                        )
                        .font(.body.weight(.semibold))
                        .layoutPriority(1)
                        Spacer(minLength: 16)
                        ViewThatFits(in: .horizontal) {
                            artistActions
                                .labelStyle(.titleAndIcon)
                                .fixedSize(horizontal: true, vertical: false)
                            artistActions
                                .labelStyle(.iconOnly)
                        }
                    }
                    if canFollowArtist, let followErrorMessage {
                        VStack(alignment: .trailing, spacing: 8) {
                            Text(followErrorMessage)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            if isFollowing == nil {
                                Button("Try Again") { Task { await loadFollowStatus() } }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }

                    HStack(alignment: .top, spacing: 24) {
                        tabContent
                            .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 24) {
                            ViewThatFits(in: .horizontal) {
                                artistStatistics(details, showsTrackCount: true)
                                artistStatistics(details, showsTrackCount: false)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            if let description = nonempty(details.description) {
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
                            let location = [details.city, details.country]
                                .compactMap { nonempty($0) }
                                .joined(separator: ", ")
                            if !location.isEmpty {
                                Label(location, systemImage: "mappin.and.ellipse")
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            profileLinks
                            if !relatedArtists.isEmpty || isLoadingRelatedArtists || relatedArtistsErrorMessage != nil {
                                relatedArtistsSection
                            }
                        }
                        .frame(width: min(320, max(0, contentWidth - 72) * 0.3), alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
                // AppKit can defer its narrower width proposal until the first scroll.
                .frame(width: contentWidth)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: geometry.size.width)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
            scrollerStyle = NSScroller.preferredScrollerStyle
        }
    }

    private var profileLinks: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !webProfiles.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(webProfiles) { profile in
                        Link(destination: profile.url) {
                            HStack(spacing: 12) {
                                Group {
                                    if let asset = profile.iconAsset {
                                        Image(asset)
                                            .resizable()
                                            .scaledToFit()
                                    } else {
                                        Image(systemName: "globe")
                                            .resizable()
                                            .scaledToFit()
                                    }
                                }
                                .frame(width: 18, height: 18)
                                .accessibilityHidden(true)
                                Text(profile.title)
                                    .font(.body.weight(.semibold))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            .foregroundStyle(hoveredWebProfileURL == profile.url ? .primary : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onContentHover { isHovering in
                            if isHovering {
                                hoveredWebProfileURL = profile.url
                            } else if hoveredWebProfileURL == profile.url {
                                hoveredWebProfileURL = nil
                            }
                        }
                        .help(profile.url.absoluteString)
                    }
                }
                .padding(.vertical, -6)
            }
            if let webProfilesErrorMessage {
                Text(webProfilesErrorMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Retry profile links") { Task { await loadWebProfiles() } }
            }
        }
    }

    private var relatedArtistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Related")
                    .font(.headline)
                    .opacity(0.96)
                Spacer()
                Button("Refresh") {
                    refreshRelatedArtists()
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(isHoveringRelatedRefresh ? .primary : .secondary)
                .onContentHover { isHoveringRelatedRefresh = $0 }
                .disabled(isLoadingRelatedArtists || relatedArtists.count <= relatedArtistsPageSize)
                .help("Show the next page of related artists")
            }

            VStack(spacing: 0) {
                ForEach(relatedArtists.dropFirst(relatedArtistsPage * relatedArtistsPageSize).prefix(relatedArtistsPageSize), id: \.permalinkURL) { user in
                    Button {
                        onSelectArtist(user)
                    } label: {
                        HStack(spacing: 12) {
                            TrackArtworkView(
                                artworkURL: user.avatarURL,
                                loader: model.artworkLoader,
                                size: 44,
                                showsBorder: false
                            )
                            .clipShape(Circle())
                            .overlay { Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1) }
                            .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(user.username)
                                    .font(.body.weight(.semibold))
                                ViewThatFits(in: .horizontal) {
                                    relatedArtistStatistics(user, showsTrackCount: true)
                                        .fixedSize(horizontal: true, vertical: false)
                                    relatedArtistStatistics(user, showsTrackCount: false)
                                }
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            }
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(8)
                        .background {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.white.opacity(hoveredRelatedArtistURL == user.permalinkURL ? 0.08 : 0))
                                .animation(.easeInOut(duration: 0.15), value: hoveredRelatedArtistURL == user.permalinkURL)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onContentHover { isHovering in
                        if isHovering {
                            hoveredRelatedArtistURL = user.permalinkURL
                        } else if hoveredRelatedArtistURL == user.permalinkURL {
                            hoveredRelatedArtistURL = nil
                        }
                    }
                    .help("View artist: \(user.username)")
                }
            }
            .id(relatedArtistsPage)
            .transition(.opacity)
            .opacity(relatedArtists.isEmpty ? 0 : 1)
            .animation(
                reduceMotion ? nil : .easeIn(duration: 0.25),
                value: relatedArtists.isEmpty
            )

            if isLoadingRelatedArtists {
                ProgressView()
                    .accessibilityLabel("Loading related artists")
                    .controlSize(.small)
            } else if let relatedArtistsErrorMessage {
                Text(relatedArtistsErrorMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Retry related artists") { Task { await loadRelatedArtists() } }
            }
        }
    }

    private func relatedArtistStatistics(_ user: SoundCloudUser, showsTrackCount: Bool) -> some View {
        HStack(spacing: 12) {
            if let count = user.followersCount {
                HStack(spacing: 3) {
                    Image(systemName: "person.fill")
                    Text(count.formatted(.number.notation(.compactName).precision(.fractionLength(0))).uppercased())
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(count.formatted()) followers")
            }
            if showsTrackCount, let count = user.trackCount {
                HStack(spacing: 3) {
                    Image(systemName: "waveform")
                    Text(count.formatted(.number.notation(.compactName).precision(.fractionLength(0))).uppercased())
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(count.formatted()) tracks")
            }
        }
    }

    private func refreshRelatedArtists() {
        let nextPage = relatedArtistsPage + 1
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            relatedArtistsPage = nextPage * relatedArtistsPageSize < relatedArtists.count ? nextPage : 0
        }
        hoveredRelatedArtistURL = nil
    }

    private func loadRelatedArtists() async {
        relatedArtists = []
        relatedArtistsPage = 0
        hoveredRelatedArtistURL = nil
        relatedArtistsErrorMessage = nil
        guard let user = details?.user, user.urn != nil else { return }
        isLoadingRelatedArtists = true
        defer { isLoadingRelatedArtists = false }
        do {
            let artists = try await model.relatedArtists(for: user)
            try Task.checkCancellation()
            relatedArtists = artists
        } catch {
            guard !Task.isCancelled else { return }
            relatedArtistsErrorMessage = "Could not load related artists."
        }
    }

    private func loadWebProfiles() async {
        webProfiles = []
        webProfilesErrorMessage = nil
        guard let user = details?.user, user.urn != nil else { return }
        do {
            let profiles = try await model.artistWebProfiles(for: user)
            try Task.checkCancellation()
            webProfiles = profiles
        } catch {
            guard !Task.isCancelled else { return }
            webProfilesErrorMessage = "Could not load profile links."
        }
    }

    private var canFollowArtist: Bool {
        guard let user = details?.user, user.urn != nil,
              case let .signedIn(account) = model.auth.state else { return false }
        return user.urn != account.urn && user.permalinkURL != account.permalinkURL
    }

    private var tabContent: some View {
        VStack(alignment: .leading, spacing: 24) {
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
    }

    private func tabCount(_ tab: ContentTab) -> Int? {
        let user = details?.user ?? artist
        return switch tab {
        case .tracks: user.trackCount
        case .reposts: user.repostsCount
        case .playlists: user.playlistCount
        case .likes: user.publicFavoritesCount
        }
    }

    private var artistActions: some View {
        HStack {
            if !tracks.isEmpty || (!hasLoadedTracks && tracksErrorMessage == nil) {
                Button {
                    isShufflingTracks = true
                } label: {
                    Label {
                        Text("Shuffle")
                    } icon: {
                        Image(systemName: "shuffle")
                            .opacity(isShufflingTracks ? 0 : 1)
                            .overlay {
                                if isShufflingTracks {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .accessibilityHidden(true)
                                }
                            }
                    }
                }
                .disabled(tracks.isEmpty || isShufflingTracks)
                .help("Shuffle this artist’s tracks")
                .accessibilityValue(isShufflingTracks ? "Starting shuffle playback" : "")
            }
            if nonempty(details?.user.stationURN) != nil {
                stationButton
            }
            if canFollowArtist {
                followControls
            }
        }
        .buttonStyle(ArtistActionButtonStyle())
    }

    private var stationButton: some View {
        Button("Station", systemImage: "dot.radiowaves.left.and.right") {
            guard let urn = nonempty(details?.user.stationURN) else { return }
            onSelectStation(urn, details?.user.username ?? artist.username)
        }
        .help("Open this artist’s station")
    }

    private func shuffleTracks() async {
        defer { isShufflingTracks = false }
        guard !Task.isCancelled, let urn = details?.user.urn,
              let track = tracks.randomElement() else { return }
        if !model.playback.isShuffleEnabled {
            model.toggleShuffle()
        }
        await model.play(track, queue: TrackQueue(
            source: .artist(urn), tracks: tracks, nextPageURL: nextPageURL
        ), loadRemainingTracks: true)
    }

    private var followControls: some View {
        let isLoadingFollow = isUpdatingFollow || (isFollowing == nil && followErrorMessage == nil)

        return Button {
            Task { await toggleFollow() }
        } label: {
            Label {
                Text(isFollowing == true ? "Unfollow" : "Follow")
            } icon: {
                Image(systemName: isFollowing == true ? "person.badge.minus" : "person.badge.plus")
                    .opacity(isLoadingFollow ? 0 : 1)
                    .overlay {
                        if isLoadingFollow {
                            ProgressView()
                                .controlSize(.mini)
                                .accessibilityHidden(true)
                        }
                    }
            }
        }
        .disabled(isFollowing == nil || isUpdatingFollow)
        .help(isFollowing == true ? "Unfollow this artist" : "Follow this artist")
        .accessibilityValue(isLoadingFollow ? "Loading follow status" : "")
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
        let pictureSize: CGFloat = 180
        let thumbnail = TrackArtworkView(
            artworkURL: avatarURL,
            loader: model.artworkLoader,
            size: pictureSize,
            rendition: .square500
        )
        .scaleEffect(isHoveringArtwork && !reduceMotion ? 1.12 : 1)
        .clipShape(Circle())
        .modifier(PlayerArtworkGlass(
            cornerRadius: pictureSize / 2,
            isHovering: isHoveringArtwork && !reduceMotion
        ))
        .animation(
            reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.75),
            value: isHoveringArtwork
        )

        if avatarURL != nil {
            Button {
                isShowingArtwork = true
            } label: {
                thumbnail
            }
            .buttonStyle(ArtistPictureButtonStyle())
            .contentShape(Circle())
            .onContentHover(in: Circle().path(in: CGRect(
                x: 0, y: 0, width: pictureSize, height: pictureSize
            ))) { isHoveringArtwork = $0 }
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
                    analyzer: model.analyzer,
                    artworkLoader: model.artworkLoader,
                    likes: model.likes,
                    showsArtist: false,
                    onAddToQueue: model.addToQueue,
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
                .modifier(FadeInOnAppear())
            }
            if let tracksErrorMessage {
                Text(tracksErrorMessage).foregroundStyle(.secondary)
                Button("Try Again") { Task { await loadTracks() } }
                    .disabled(isLoadingTracks)
            }
            if isLoadingTracks || (nextPageURL != nil && tracksErrorMessage == nil) {
                ProgressView()
                    .accessibilityLabel("Loading tracks")
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
                    analyzer: model.analyzer,
                    artworkLoader: model.artworkLoader,
                    likes: model.likes,
                    onAddToQueue: model.addToQueue,
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
                .modifier(FadeInOnAppear())
            }
            if let repostsErrorMessage {
                Text(repostsErrorMessage).foregroundStyle(.secondary)
                Button("Try Again") { Task { await loadReposts() } }
                    .disabled(isLoadingReposts)
            }
            if isLoadingReposts
                || (repostsNextPageURL != nil && repostsErrorMessage == nil) {
                ProgressView()
                    .accessibilityLabel("Loading reposts")
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
                    analyzer: model.analyzer,
                    artworkLoader: model.artworkLoader,
                    likes: model.likes,
                    onAddToQueue: model.addToQueue,
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
                .modifier(FadeInOnAppear())
            }
            if let likesErrorMessage {
                Text(likesErrorMessage).foregroundStyle(.secondary)
                Button("Try Again") { Task { await loadLikes() } }
                    .disabled(isLoadingLikes)
            }
            if isLoadingLikes
                || (likesNextPageURL != nil && likesErrorMessage == nil) {
                ProgressView()
                    .accessibilityLabel("Loading likes")
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
                .modifier(FadeInOnAppear())
            }
            if let playlistsErrorMessage {
                Text(playlistsErrorMessage).foregroundStyle(.secondary)
                Button("Try Again") { Task { await loadPlaylists() } }
                    .disabled(isLoadingPlaylists)
            }
            if isLoadingPlaylists
                || (playlistsNextPageURL != nil && playlistsErrorMessage == nil) {
                ProgressView()
                    .accessibilityLabel("Loading playlists")
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

    private func artistStatistics(_ details: SoundCloudArtistDetails, showsTrackCount: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            userStatistic(details.followersCount.map { max(0, $0 + followerCountAdjustment) }, list: .followers, user: details.user, allowsScaling: !showsTrackCount)
            userStatistic(details.followingsCount, list: .following, user: details.user, allowsScaling: !showsTrackCount)
            if showsTrackCount, let trackCount = details.trackCount {
                Button {
                    selectedTab = .tracks
                } label: {
                    statistic(trackCount, label: "Tracks", allowsScaling: false)
                }
                .buttonStyle(.plain)
                .disabled(trackCount == 0)
                .help("View tracks by \(details.user.username)")
            }
        }
    }

    @ViewBuilder
    private func userStatistic(_ count: Int?, list: ArtistUserList, user: SoundCloudUser, allowsScaling: Bool) -> some View {
        if let count {
            Button {
                onSelectUsers(user, list)
            } label: {
                statistic(count, label: list.title, allowsScaling: allowsScaling)
            }
            .buttonStyle(.plain)
            .help("View \(list.title.lowercased()) of \(user.username)")
        }
    }

    @ViewBuilder
    private func statistic(_ count: Int?, label: String, allowsScaling: Bool) -> some View {
        if let count {
            VStack(alignment: .leading, spacing: 8) {
                Text(label)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(hoveredStatistic == label ? .primary : .secondary)
                Text(count.formatted(.number.notation(.compactName).precision(.fractionLength(0))).uppercased())
                    .font(.system(size: 28, weight: .semibold))
                    .opacity(hoveredStatistic == label ? 1 : 0.9)
            }
            .lineLimit(1)
            .minimumScaleFactor(allowsScaling ? 0.6 : 1)
            .fixedSize(horizontal: !allowsScaling, vertical: false)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onContentHover { isHovering in
                if isHovering {
                    hoveredStatistic = label
                } else if hoveredStatistic == label {
                    hoveredStatistic = nil
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label): \(count.formatted())")
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

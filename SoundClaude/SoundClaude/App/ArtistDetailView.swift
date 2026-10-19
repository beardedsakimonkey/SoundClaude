import AppKit
import Observation
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

    enum ContentTab: String, CaseIterable, Identifiable {
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
    let model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    let onSelectUsers: (SoundCloudUser, ArtistUserList) -> Void
    let onSelectPlaylist: (SoundCloudPlaylist) -> Void
    let onSelectStation: (String, String) -> Void

    @State private var isFollowing: Bool?
    @State private var isUpdatingFollow = false
    @State private var isShufflingTracks = false
    @State private var followErrorMessage: String?
    @State private var followerCountAdjustment = 0
    @State private var headerImage: NSImage?
    @State private var headerImageURL: URL?
    @State private var isHeaderImageMissing = false
    @State private var isHeaderContentHidden = false
    @State private var details: SoundCloudArtistDetails?
    @State private var webProfiles: [SoundCloudWebProfile] = []
    @State private var webProfilesErrorMessage: String?
    @State private var relatedArtists: [SoundCloudUser] = []
    @State private var relatedArtistsPage = 0
    private let relatedArtistsPageSize = 3
    @State private var isLoadingRelatedArtists = false
    @State private var relatedArtistsErrorMessage: String?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var contentState = ContentState()
    let tabSelection: ArtistTabSelection

    // Observation tracks these fields only in the views that read them.
    @Observable
    fileprivate final class ContentState {
        var tracks: [SoundCloudTrack] = []
        var nextPageURL: URL?
        var loadedPageURLs: Set<URL> = []
        var hasLoadedTracks = false
        var isLoadingTracks = false
        var tracksErrorMessage: String?
        var reposts: [SoundCloudTrack] = []
        var repostsNextPageURL: URL?
        var loadedRepostsPageURLs: Set<URL> = []
        var hasLoadedReposts = false
        var isLoadingReposts = false
        var repostsErrorMessage: String?
        var repostedPlaylists: [SoundCloudPlaylist] = []
        var repostedPlaylistsNextPageURL: URL?
        var loadedRepostedPlaylistsPageURLs: Set<URL> = []
        var hasLoadedRepostedPlaylists = false
        var isLoadingRepostedPlaylists = false
        var repostedPlaylistsErrorMessage: String?
        var likedPlaylists: [SoundCloudPlaylist] = []
        var likedPlaylistsNextPageURL: URL?
        var loadedLikedPlaylistsPageURLs: Set<URL> = []
        var hasLoadedLikedPlaylists = false
        var isLoadingLikedPlaylists = false
        var likedPlaylistsErrorMessage: String?
        var likes: [SoundCloudTrack] = []
        var likesNextPageURL: URL?
        var loadedLikesPageURLs: Set<URL> = []
        var hasLoadedLikes = false
        var isLoadingLikes = false
        var likesErrorMessage: String?
        var playlists: [SoundCloudPlaylist] = []
        var playlistsNextPageURL: URL?
        var loadedPlaylistsPageURLs: Set<URL> = []
        var hasLoadedPlaylists = false
        var isLoadingPlaylists = false
        var playlistsErrorMessage: String?
    }
    @State private var isShowingArtwork = false
    @State private var cachedFullSizeArtwork: CachedFullSizeArtwork?

    init(
        artist: SoundCloudUser,
        model: AppModel,
        tabSelection: ArtistTabSelection,
        onSelectTrack: @escaping (SoundCloudTrack) -> Void,
        onSelectArtist: @escaping (SoundCloudUser) -> Void,
        onSelectPlaylist: @escaping (SoundCloudPlaylist) -> Void,
        onSelectUsers: @escaping (SoundCloudUser, ArtistUserList) -> Void,
        onSelectStation: @escaping (String, String) -> Void
    ) {
        self.artist = artist
        self.model = model
        self.tabSelection = tabSelection
        self.onSelectTrack = onSelectTrack
        self.onSelectArtist = onSelectArtist
        self.onSelectUsers = onSelectUsers
        self.onSelectPlaylist = onSelectPlaylist
        self.onSelectStation = onSelectStation
        let cached = model.cachedArtistDetails(for: artist)
        _details = State(initialValue: cached)
        _webProfiles = State(initialValue: model.cachedArtistWebProfiles(for: cached?.user ?? artist) ?? [])
        _isLoading = State(initialValue: cached == nil)
        let cachedHeader = model.cachedArtistHeader(for: artist)
        _headerImage = State(initialValue: cachedHeader?.image)
        _headerImageURL = State(initialValue: cachedHeader?.artworkURL)
    }

    var body: some View {
        ZStack {
            if let details {
                detailsView(details)
            } else if isLoading {
                LoadingSpinner()
                    .accessibilityLabel("Loading artist")
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .top) {
            artworkBackdrop
                .ignoresSafeArea(edges: .top)
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
                    .contentHelp("Open this artist in your web browser")
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
        .sheet(isPresented: $isShowingArtwork) {
            FullSizeArtworkView(
                title: details?.user.username ?? artist.username,
                artworkURL: details?.user.avatarURL ?? artist.avatarURL,
                loader: model.artworkLoader,
                cachedArtwork: $cachedFullSizeArtwork
            )
        }
        #if DEBUG
        .debugViewUpdates("ArtistDetailView")
        #endif
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
        ScrollbarReservedScrollView { contentSize in
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .center, spacing: 24) {
                        artistPicture(for: details.user)
                        VStack(alignment: .leading, spacing: 10) {
                            Text(details.user.username)
                                .font(.system(size: 36, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
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
                        .accessibilityLabel(isHeaderContentHidden ? "Show artist information" : "Hide artist information")
                    }
                }
                .environment(\.colorScheme, headerImage == nil ? colorScheme : .dark)
                .padding(.horizontal, -24)
                .padding(.top, -24)
                .padding(.bottom, -12)

                HStack {
                    ArtistTabs(selection: tabSelection, optionCount: tabCount)
                    .font(.body.weight(.semibold))
                    .layoutPriority(1)
                    .modifier(FadeInOnAppear())
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
                    ArtistTabContent(selection: tabSelection) { tab in
                        tabContent(for: tab)
                    }
                        // Keep enough scroll space below the tabs when their content
                        // is loading or short, so switching tabs does not pull them down.
                        .frame(
                            maxWidth: .infinity,
                            minHeight: contentSize.height,
                            alignment: .topLeading
                        )

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
                        if !webProfiles.isEmpty || webProfilesErrorMessage != nil {
                            profileLinks
                        }
                        if !relatedArtists.isEmpty || isLoadingRelatedArtists || relatedArtistsErrorMessage != nil {
                            relatedArtistsSection
                        }
                    }
                    .frame(width: min(320, max(0, contentSize.width - 72) * 0.3), alignment: .leading)
                    .modifier(FadeInOnAppear())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
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
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .modifier(HoverForeground())
                        .contentHelp(profile.url.absoluteString)
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
                .modifier(HoverForeground())
                .disabled(isLoadingRelatedArtists || relatedArtists.count <= relatedArtistsPageSize)
                .contentHelp("Show the next page of related artists")
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
                                showsBorder: false,
                                showsPlaceholderIcon: false
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
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .modifier(RelatedArtistHover())
                    .contentHelp("View artist: \(user.username)")
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
                LoadingSpinner()
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
    }

    private func loadRelatedArtists() async {
        relatedArtists = []
        relatedArtistsPage = 0
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
        webProfilesErrorMessage = nil
        guard let user = details?.user, user.urn != nil else { return }
        if let cached = model.cachedArtistWebProfiles(for: user) {
            webProfiles = cached
            return
        }
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

    private struct ArtistTabs: View {
        @Bindable var selection: ArtistTabSelection
        let optionCount: (ContentTab) -> Int?

        var body: some View {
            TabPicker(
                title: "Artist content",
                options: ContentTab.allCases,
                selection: $selection.tab,
                optionCount: optionCount,
                optionSystemImage: { $0.systemImage },
                allowsIconOnly: true
            )
        }
    }

    // Read selection and build the list inside this leaf's observation scope.
    private struct ArtistTabContent<Content: View>: View {
        let selection: ArtistTabSelection
        @ViewBuilder let content: (ContentTab) -> Content

        var body: some View {
            content(selection.tab)
            #if DEBUG
                .debugViewUpdates("ArtistTabContent")
            #endif
        }
    }

    private func tabContent(for tab: ContentTab) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.accentColor)
            }
            switch tab {
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
            if !contentState.tracks.isEmpty || (!contentState.hasLoadedTracks && contentState.tracksErrorMessage == nil) {
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
                                    LoadingSpinner()
                                        .controlSize(.mini)
                                        .accessibilityHidden(true)
                                }
                            }
                    }
                }
                .disabled(contentState.tracks.isEmpty || isShufflingTracks)
                .contentHelp("Shuffle this artist’s tracks")
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
        .contentHelp("Open this artist’s station")
    }

    private func shuffleTracks() async {
        defer { isShufflingTracks = false }
        guard !Task.isCancelled, let urn = details?.user.urn,
              let track = contentState.tracks.randomElement() else { return }
        if !model.playback.isShuffleEnabled {
            model.toggleShuffle()
        }
        await model.play(track, queue: TrackQueue(
            source: .artist(urn), tracks: contentState.tracks, nextPageURL: contentState.nextPageURL
        ), loadRemainingTracks: true)
    }

    private var followControls: some View {
        let isLoadingFollow = isUpdatingFollow || (isFollowing == nil && followErrorMessage == nil)

        return Button {
            Task { await toggleFollow() }
        } label: {
            ZStack {
                Label("Follow", systemImage: "person.badge.plus").hidden()
                Label("Unfollow", systemImage: "person.badge.minus").hidden()

                Label {
                    Text(isFollowing == true ? "Unfollow" : "Follow")
                } icon: {
                    Image(systemName: isFollowing == true ? "person.badge.minus" : "person.badge.plus")
                        .opacity(isLoadingFollow ? 0 : 1)
                        .overlay {
                            if isLoadingFollow {
                                LoadingSpinner()
                                    .controlSize(.mini)
                                    .accessibilityHidden(true)
                            }
                        }
                }
            }
        }
        .disabled(isFollowing == nil || isUpdatingFollow)
        .contentHelp(isFollowing == true ? "Unfollow this artist" : "Follow this artist")
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

    private func artistPicture(for user: SoundCloudUser) -> some View {
        ArtistPicture(
            user: user,
            avatarURL: user.avatarURL ?? artist.avatarURL,
            model: model,
            isShowingArtwork: $isShowingArtwork
        )
    }

    private struct ArtistPicture: View {
        let user: SoundCloudUser
        let avatarURL: URL?
        let model: AppModel
        @Binding var isShowingArtwork: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHoveringArtwork = false

        private var glassParameters: PlayerArtworkGlassParameters {
            var parameters = PlayerArtworkGlassParameters()
            parameters.sweepStrength = 0
            return parameters
        }

        var body: some View {
            let pictureSize: CGFloat = 180
            let thumbnail = TrackArtworkView(
                artworkURL: avatarURL,
                loader: model.artworkLoader,
                size: pictureSize,
                rendition: .square500,
                showsBorder: false,
                showsPlaceholderIcon: false
            )
            .scaleEffect(isHoveringArtwork && !reduceMotion ? 1.12 : 1)
            .clipShape(Circle())
            .modifier(PlayerArtworkGlass(
                cornerRadius: pictureSize / 2,
                isHovering: isHoveringArtwork && !reduceMotion
            ))
            .environment(\.playerArtworkGlassParameters, glassParameters)
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
                .contentHelp("View full-size artist picture")
                .accessibilityLabel("View full-size picture of \(user.username)")
            } else {
                thumbnail
            }
        }
    }

    private var trackList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(contentState.tracks) { track in
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
                            tracks: contentState.tracks,
                            nextPageURL: contentState.nextPageURL
                        ))
                    }
                )
                .modifier(FadeInOnAppear())
            }
            if let message = contentState.tracksErrorMessage {
                Text(message).foregroundStyle(.secondary)
                Button("Try Again") { Task { await loadTracks() } }
                    .disabled(contentState.isLoadingTracks)
            }
            if contentState.isLoadingTracks || (contentState.nextPageURL != nil && contentState.tracksErrorMessage == nil) {
                LoadingSpinner()
                    .accessibilityLabel("Loading tracks")
                    .frame(maxWidth: .infinity)
                    .task(id: contentState.nextPageURL) {
                        guard contentState.nextPageURL != nil, contentState.tracksErrorMessage == nil else { return }
                        await loadTracks()
                    }
            } else if contentState.hasLoadedTracks, contentState.tracks.isEmpty, contentState.tracksErrorMessage == nil {
                EmptyStateView("No visible tracks")
            }
        }
    }

    private var sortedReposts: [SoundCloudFeedContent] {
        SoundCloudFeedContent.sortedByCreationDate(
            contentState.reposts.map(SoundCloudFeedContent.track)
                + contentState.repostedPlaylists.map(SoundCloudFeedContent.playlist)
        )
    }

    private var repostList: some View {
        let items = sortedReposts
        return LazyVStack(alignment: .leading, spacing: 16) {
            contentCards(
                items,
                source: .artistReposts(details?.user.urn ?? artist.urn ?? ""),
                nextPageURL: contentState.repostsNextPageURL
            )
            if let message = contentState.repostsErrorMessage {
                Text(message).foregroundStyle(.secondary)
                Button("Try Again") { Task { await loadReposts() } }
                    .disabled(contentState.isLoadingReposts)
            }
            if let message = contentState.repostedPlaylistsErrorMessage {
                Text(message).foregroundStyle(.secondary)
                Button("Try Again") { Task { await loadRepostedPlaylists() } }
                    .disabled(contentState.isLoadingRepostedPlaylists)
            }
            if contentState.isLoadingReposts || contentState.isLoadingRepostedPlaylists
                || (contentState.repostsNextPageURL != nil && contentState.repostsErrorMessage == nil)
                || (contentState.repostedPlaylistsNextPageURL != nil && contentState.repostedPlaylistsErrorMessage == nil) {
                LoadingSpinner()
                    .accessibilityLabel("Loading reposts")
                    .frame(maxWidth: .infinity)
                    .task(id: contentState.repostsNextPageURL) {
                        guard contentState.repostsNextPageURL != nil,
                              contentState.repostsErrorMessage == nil else { return }
                        await loadReposts()
                    }
                    .task(id: contentState.repostedPlaylistsNextPageURL) {
                        guard contentState.repostedPlaylistsNextPageURL != nil,
                              contentState.repostedPlaylistsErrorMessage == nil else { return }
                        await loadRepostedPlaylists()
                    }
            }
            if contentState.hasLoadedReposts, contentState.hasLoadedRepostedPlaylists,
               contentState.reposts.isEmpty, contentState.repostedPlaylists.isEmpty,
               !contentState.isLoadingReposts, !contentState.isLoadingRepostedPlaylists,
               contentState.repostsNextPageURL == nil, contentState.repostedPlaylistsNextPageURL == nil,
               contentState.repostsErrorMessage == nil, contentState.repostedPlaylistsErrorMessage == nil {
                EmptyStateView("No visible reposts")
            }
        }
        .task(id: details?.user.urn) {
            guard !contentState.hasLoadedRepostedPlaylists else { return }
            await loadRepostedPlaylists()
        }
        .task(id: details?.user.urn) {
            guard !contentState.hasLoadedReposts else { return }
            await loadReposts()
        }
    }

    private func contentCards(
        _ items: [SoundCloudFeedContent],
        source: TrackQueue.Source,
        nextPageURL queueNextPageURL: URL?
    ) -> some View {
        ForEach(items, id: \.urn) { item in
            switch item {
            case let .track(track):
                TrackCardView(
                    track: track,
                    model: model,
                    onSelectTrack: onSelectTrack,
                    onSelectArtist: onSelectArtist,
                    onPlayTrack: { selected in
                        await model.play(selected, queue: TrackQueue(
                            source: source,
                            tracks: items.compactMap(\.track),
                            nextPageURL: queueNextPageURL
                        ))
                    }
                )
            case let .playlist(playlist):
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
        }
    }

    private var sortedLikes: [SoundCloudFeedContent] {
        SoundCloudFeedContent.sortedByCreationDate(
            contentState.likes.map(SoundCloudFeedContent.track)
                + contentState.likedPlaylists.map(SoundCloudFeedContent.playlist)
        )
    }

    private var likesList: some View {
        let items = sortedLikes
        return LazyVStack(alignment: .leading, spacing: 16) {
            contentCards(
                items,
                source: .artistLikes(details?.user.urn ?? artist.urn ?? ""),
                nextPageURL: contentState.likesNextPageURL
            )
            if let message = contentState.likesErrorMessage {
                Text(message).foregroundStyle(.secondary)
                Button("Try Again") { Task { await loadLikes() } }
                    .disabled(contentState.isLoadingLikes)
            }
            if let message = contentState.likedPlaylistsErrorMessage {
                Text(message).foregroundStyle(.secondary)
                Button("Try Again") { Task { await loadLikedPlaylists() } }
                    .disabled(contentState.isLoadingLikedPlaylists)
            }
            if contentState.isLoadingLikes || contentState.isLoadingLikedPlaylists
                || (contentState.likesNextPageURL != nil && contentState.likesErrorMessage == nil)
                || (contentState.likedPlaylistsNextPageURL != nil && contentState.likedPlaylistsErrorMessage == nil) {
                LoadingSpinner()
                    .accessibilityLabel("Loading likes")
                    .frame(maxWidth: .infinity)
                    .task(id: contentState.likesNextPageURL) {
                        guard contentState.likesNextPageURL != nil,
                              contentState.likesErrorMessage == nil else { return }
                        await loadLikes()
                    }
                    .task(id: contentState.likedPlaylistsNextPageURL) {
                        guard contentState.likedPlaylistsNextPageURL != nil,
                              contentState.likedPlaylistsErrorMessage == nil else { return }
                        await loadLikedPlaylists()
                    }
            }
            if contentState.hasLoadedLikes, contentState.hasLoadedLikedPlaylists,
               contentState.likes.isEmpty, contentState.likedPlaylists.isEmpty,
               !contentState.isLoadingLikes, !contentState.isLoadingLikedPlaylists,
               contentState.likesNextPageURL == nil, contentState.likedPlaylistsNextPageURL == nil,
               contentState.likesErrorMessage == nil, contentState.likedPlaylistsErrorMessage == nil {
                EmptyStateView("No visible likes")
            }
        }
        .task(id: details?.user.urn) {
            guard !contentState.hasLoadedLikes else { return }
            await loadLikes()
        }
        .task(id: details?.user.urn) {
            guard !contentState.hasLoadedLikedPlaylists else { return }
            await loadLikedPlaylists()
        }
    }

    private var playlistList: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(contentState.playlists) { playlist in
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
            if let message = contentState.playlistsErrorMessage {
                Text(message).foregroundStyle(.secondary)
                Button("Try Again") { Task { await loadPlaylists() } }
                    .disabled(contentState.isLoadingPlaylists)
            }
            if contentState.isLoadingPlaylists
                || (contentState.playlistsNextPageURL != nil && contentState.playlistsErrorMessage == nil) {
                LoadingSpinner()
                    .accessibilityLabel("Loading playlists")
                    .frame(maxWidth: .infinity)
                    .task(id: contentState.playlistsNextPageURL) {
                        guard contentState.playlistsNextPageURL != nil,
                              contentState.playlistsErrorMessage == nil else { return }
                        await loadPlaylists()
                    }
            } else if contentState.hasLoadedPlaylists, contentState.playlists.isEmpty,
                      contentState.playlistsErrorMessage == nil {
                EmptyStateView("No visible playlists")
            }
        }
        .task {
            guard !contentState.hasLoadedPlaylists else { return }
            await loadPlaylists()
        }
    }

    private func artistStatistics(_ details: SoundCloudArtistDetails, showsTrackCount: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            userStatistic(details.followersCount.map { max(0, $0 + followerCountAdjustment) }, list: .followers, user: details.user, allowsScaling: !showsTrackCount)
            userStatistic(details.followingsCount, list: .following, user: details.user, allowsScaling: !showsTrackCount)
            if showsTrackCount, let trackCount = details.trackCount {
                Button {
                    tabSelection.tab = .tracks
                } label: {
                    statistic(trackCount, label: "Tracks", allowsScaling: false)
                }
                .buttonStyle(.plain)
                .disabled(trackCount == 0)
                .contentHelp("View tracks by \(details.user.username)")
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
            .contentHelp("View \(list.title.lowercased()) of \(user.username)")
        }
    }

    @ViewBuilder
    private func statistic(_ count: Int?, label: String, allowsScaling: Bool) -> some View {
        if let count {
            ArtistStatistic(count: count, label: label, allowsScaling: allowsScaling)
        }
    }

    // Keep pointer state at the leaf so hovering does not invalidate the detail page.
    private struct ArtistStatistic: View {
        let count: Int
        let label: String
        let allowsScaling: Bool
        @State private var isHovering = false

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(label)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(isHovering ? .primary : .secondary)
                Text(count.formatted(.number.notation(.compactName).precision(.fractionLength(0))).uppercased())
                    .font(.system(size: 28, weight: .semibold))
                    .opacity(isHovering ? 1 : 0.9)
            }
            .lineLimit(1)
            .minimumScaleFactor(allowsScaling ? 0.6 : 1)
            .fixedSize(horizontal: !allowsScaling, vertical: false)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onContentHover { isHovering = $0 }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label): \(count.formatted())")
        }
    }

    private struct HoverForeground: ViewModifier {
        @State private var isHovering = false

        func body(content: Content) -> some View {
            content
                .foregroundStyle(isHovering ? .primary : .secondary)
                .onContentHover { isHovering = $0 }
        }
    }

    private struct RelatedArtistHover: ViewModifier {
        @State private var isHovering = false

        func body(content: Content) -> some View {
            content
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
                        .animation(.easeInOut(duration: 0.15), value: isHovering)
                }
                .onContentHover { isHovering = $0 }
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
            if !contentState.hasLoadedTracks { await loadTracks() }
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func loadTracks() async {
        guard !contentState.isLoadingTracks, let details,
              !contentState.hasLoadedTracks || contentState.nextPageURL != nil else { return }
        contentState.isLoadingTracks = true
        contentState.tracksErrorMessage = nil
        defer { contentState.isLoadingTracks = false }
        do {
            let pageURL = contentState.nextPageURL
            let page = try await model.artistTracks(for: details.user, pageURL: pageURL)
            try Task.checkCancellation()
            if let nextURL = page.nextURL,
               nextURL == pageURL || contentState.loadedPageURLs.contains(nextURL) {
                throw SoundCloudError.invalidData
            }
            var knownURNs = Set(contentState.tracks.map(\.urn))
            contentState.tracks.append(contentsOf: page.tracks.filter { knownURNs.insert($0.urn).inserted })
            if let pageURL { contentState.loadedPageURLs.insert(pageURL) }
            contentState.nextPageURL = page.nextURL
            contentState.hasLoadedTracks = true
        } catch {
            guard !Task.isCancelled else { return }
            contentState.tracksErrorMessage = error.localizedDescription
        }
    }

    private func loadPlaylists() async {
        guard !contentState.isLoadingPlaylists, let details,
              !contentState.hasLoadedPlaylists || contentState.playlistsNextPageURL != nil else { return }
        contentState.isLoadingPlaylists = true
        contentState.playlistsErrorMessage = nil
        defer { contentState.isLoadingPlaylists = false }
        do {
            let pageURL = contentState.playlistsNextPageURL
            let page = try await model.artistPlaylists(for: details.user, pageURL: pageURL)
            try Task.checkCancellation()
            if let nextURL = page.nextURL,
               nextURL == pageURL || contentState.loadedPlaylistsPageURLs.contains(nextURL) {
                throw SoundCloudError.invalidData
            }
            var knownURNs = Set(contentState.playlists.map(\.urn))
            contentState.playlists.append(contentsOf: page.playlists.filter {
                knownURNs.insert($0.urn).inserted
            })
            if let pageURL { contentState.loadedPlaylistsPageURLs.insert(pageURL) }
            contentState.playlistsNextPageURL = page.nextURL
            contentState.hasLoadedPlaylists = true
        } catch {
            guard !Task.isCancelled else { return }
            contentState.playlistsErrorMessage = error.localizedDescription
        }
    }

    private func loadRepostedPlaylists() async {
        guard !contentState.isLoadingRepostedPlaylists, let details,
              !contentState.hasLoadedRepostedPlaylists || contentState.repostedPlaylistsNextPageURL != nil else { return }
        contentState.isLoadingRepostedPlaylists = true
        contentState.repostedPlaylistsErrorMessage = nil
        defer { contentState.isLoadingRepostedPlaylists = false }
        do {
            let pageURL = contentState.repostedPlaylistsNextPageURL
            let page = try await model.artistPlaylistReposts(for: details.user, pageURL: pageURL)
            try Task.checkCancellation()
            if let nextURL = page.nextURL,
               nextURL == pageURL || contentState.loadedRepostedPlaylistsPageURLs.contains(nextURL) {
                throw SoundCloudError.invalidData
            }
            var knownURNs = Set(contentState.repostedPlaylists.map(\.urn))
            contentState.repostedPlaylists.append(contentsOf: page.playlists.filter {
                knownURNs.insert($0.urn).inserted
            })
            if let pageURL { contentState.loadedRepostedPlaylistsPageURLs.insert(pageURL) }
            contentState.repostedPlaylistsNextPageURL = page.nextURL
            contentState.hasLoadedRepostedPlaylists = true
        } catch {
            guard !Task.isCancelled else { return }
            contentState.repostedPlaylistsErrorMessage = error.localizedDescription
        }
    }

    private func loadLikedPlaylists() async {
        guard !contentState.isLoadingLikedPlaylists, let details,
              !contentState.hasLoadedLikedPlaylists || contentState.likedPlaylistsNextPageURL != nil else { return }
        contentState.isLoadingLikedPlaylists = true
        contentState.likedPlaylistsErrorMessage = nil
        defer { contentState.isLoadingLikedPlaylists = false }
        do {
            let pageURL = contentState.likedPlaylistsNextPageURL
            let page = try await model.artistPlaylistLikes(for: details.user, pageURL: pageURL)
            try Task.checkCancellation()
            if let nextURL = page.nextURL,
               nextURL == pageURL || contentState.loadedLikedPlaylistsPageURLs.contains(nextURL) {
                throw SoundCloudError.invalidData
            }
            var knownURNs = Set(contentState.likedPlaylists.map(\.urn))
            contentState.likedPlaylists.append(contentsOf: page.playlists.filter {
                knownURNs.insert($0.urn).inserted
            })
            if let pageURL { contentState.loadedLikedPlaylistsPageURLs.insert(pageURL) }
            contentState.likedPlaylistsNextPageURL = page.nextURL
            contentState.hasLoadedLikedPlaylists = true
        } catch {
            guard !Task.isCancelled else { return }
            contentState.likedPlaylistsErrorMessage = error.localizedDescription
        }
    }

    private func loadReposts() async {
        guard !contentState.isLoadingReposts, let details,
              !contentState.hasLoadedReposts || contentState.repostsNextPageURL != nil else { return }
        contentState.isLoadingReposts = true
        contentState.repostsErrorMessage = nil
        defer { contentState.isLoadingReposts = false }
        do {
            let pageURL = contentState.repostsNextPageURL
            let page = try await model.artistReposts(for: details.user, pageURL: pageURL)
            try Task.checkCancellation()
            if let nextURL = page.nextURL,
               nextURL == pageURL || contentState.loadedRepostsPageURLs.contains(nextURL) {
                throw SoundCloudError.invalidData
            }
            var knownURNs = Set(contentState.reposts.map(\.urn))
            contentState.reposts.append(contentsOf: page.tracks.filter {
                knownURNs.insert($0.urn).inserted
            })
            if let pageURL { contentState.loadedRepostsPageURLs.insert(pageURL) }
            contentState.repostsNextPageURL = page.nextURL
            contentState.hasLoadedReposts = true
        } catch {
            guard !Task.isCancelled else { return }
            contentState.repostsErrorMessage = error.localizedDescription
        }
    }
    private func loadLikes() async {
        guard !contentState.isLoadingLikes, let details,
              !contentState.hasLoadedLikes || contentState.likesNextPageURL != nil else { return }
        contentState.isLoadingLikes = true
        contentState.likesErrorMessage = nil
        defer { contentState.isLoadingLikes = false }
        do {
            let pageURL = contentState.likesNextPageURL
            let page = try await model.artistLikes(for: details.user, pageURL: pageURL)
            try Task.checkCancellation()
            if let nextURL = page.nextURL,
               nextURL == pageURL || contentState.loadedLikesPageURLs.contains(nextURL) {
                throw SoundCloudError.invalidData
            }
            var knownURNs = Set(contentState.likes.map(\.urn))
            contentState.likes.append(contentsOf: page.tracks.filter {
                knownURNs.insert($0.urn).inserted
            })
            if let pageURL { contentState.loadedLikesPageURLs.insert(pageURL) }
            contentState.likesNextPageURL = page.nextURL
            contentState.hasLoadedLikes = true
        } catch {
            guard !Task.isCancelled else { return }
            contentState.likesErrorMessage = error.localizedDescription
        }
    }
}

@Observable
final class ArtistTabSelection {
    var tab: ArtistDetailView.ContentTab = .tracks
}

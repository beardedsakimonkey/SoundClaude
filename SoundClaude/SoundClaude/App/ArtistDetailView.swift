import AppKit
import SwiftUI

struct ArtistDetailView: View {
    private enum ContentTab: String, CaseIterable, Identifiable {
        case tracks = "Tracks"
        case reposts = "Reposts"

        var id: Self { self }
    }

    @Environment(\.colorScheme) private var colorScheme

    let artist: SoundCloudUser
    @ObservedObject var model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void

    @State private var headerImage: NSImage?
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
    @State private var isShowingArtwork = false
    @State private var isHoveringArtwork = false
    @State private var cachedFullSizeArtwork: CachedFullSizeArtwork?

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
        let cached = model.cachedArtistDetails(for: artist)
        _details = State(initialValue: cached)
        _isLoading = State(initialValue: cached == nil)
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
        .task(id: artist.permalinkURL) { await load() }
        .task(id: artist.permalinkURL) {
            headerImage = nil
            guard let url = try? await model.artistHeaderURL(for: artist),
                  let data = try? await model.artworkLoader.data(for: url),
                  !Task.isCancelled else { return }
            headerImage = NSImage(data: data)
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
            artworkURL: details?.user.avatarURL ?? artist.avatarURL,
            loader: model.artworkLoader
        )
        .frame(height: 340)

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
                                .textSelection(.enabled)
                            let location = [details.city, details.country]
                                .compactMap(nonempty).joined(separator: ", ")
                            if !location.isEmpty {
                                Text(location)
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            }
                            Link(destination: details.user.permalinkURL) {
                                Label("Open in SoundCloud", systemImage: "arrow.up.right.square")
                            }
                            .help("Open this artist in your web browser")
                        }
                    }

                    HStack(spacing: 24) {
                        statistic(details.followersCount, label: "followers")
                        statistic(details.followingsCount, label: "following")
                        statistic(details.trackCount, label: "tracks")
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
                                .overlay {
                                    LinearGradient(
                                        colors: [.black.opacity(0.65), .black.opacity(0.2)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                }
                        }
                        .accessibilityHidden(true)
                    }
                }
                .environment(\.colorScheme, headerImage == nil ? colorScheme : .dark)
                .padding(.horizontal, -24)
                .padding(.top, -24)

                if let description = nonempty(details.description) {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("About").font(.headline)
                        ExpandableDescriptionText(
                            description: description,
                            onSelectArtist: onSelectArtist
                        )
                        .id(artist.permalinkURL)
                    }
                }

                Divider()
                Picker("Artist content", selection: $selectedTab) {
                    ForEach(ContentTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                switch selectedTab {
                case .tracks:
                    trackList
                case .reposts:
                    repostList
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
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
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .onHover { isHoveringArtwork = $0 }
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
}

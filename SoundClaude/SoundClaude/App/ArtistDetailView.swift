import SwiftUI

struct ArtistDetailView: View {
    let artist: SoundCloudUser
    @ObservedObject var model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void

    @State private var details: SoundCloudArtistDetails?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var tracks: [SoundCloudTrack] = []
    @State private var nextPageURL: URL?
    @State private var hasLoadedTracks = false
    @State private var isLoadingTracks = false
    @State private var tracksErrorMessage: String?
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
                Text("Tracks").font(.headline)
                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                trackList
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

        if avatarURL != nil {
            Button {
                isShowingArtwork = true
            } label: {
                thumbnail
                    .artworkExpandIndicator(isHovering: isHoveringArtwork)
            }
            .buttonStyle(.plain)
            .contentShape(RoundedRectangle(cornerRadius: 6))
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
            if isLoadingTracks {
                ProgressView("Loading tracks")
                    .frame(maxWidth: .infinity)
            } else if nextPageURL != nil, tracksErrorMessage == nil {
                Button("Load more") { Task { await loadTracks() } }
                    .frame(maxWidth: .infinity)
            } else if hasLoadedTracks, tracks.isEmpty, tracksErrorMessage == nil {
                ContentUnavailableView(
                    "No playable tracks",
                    systemImage: "music.note",
                    description: Text("This artist has no tracks available for playback here.")
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
            let page = try await model.artistTracks(for: details.user, pageURL: nextPageURL)
            try Task.checkCancellation()
            var knownURNs = Set(tracks.map(\.urn))
            tracks.append(contentsOf: page.tracks.filter { knownURNs.insert($0.urn).inserted })
            nextPageURL = page.nextURL
            hasLoadedTracks = true
        } catch {
            guard !Task.isCancelled else { return }
            tracksErrorMessage = error.localizedDescription
        }
    }
}

import SwiftUI

struct StationDetailView: View {
    let urn: String
    let seedTrack: SoundCloudTrack?
    let seedArtistName: String?
    @ObservedObject var model: AppModel
    @ObservedObject var likes: LikesController
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void

    @AppStorage("playlistTrackLayout") private var trackLayout = TrackLayout.list
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var station: SoundCloudStation?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var loadAttempt = 0
    @State private var isShowingArtwork = false
    @State private var isHoveringStationTitle = false
    @State private var isHoveringStationRow = false
    @State private var isOpeningSource = false
    @State private var sourceErrorMessage: String?
    @State private var cachedFullSizeArtwork: CachedFullSizeArtwork?

    init(
        urn: String,
        seedTrack: SoundCloudTrack?,
        seedArtistName: String?,
        model: AppModel,
        likes: LikesController,
        onSelectTrack: @escaping (SoundCloudTrack) -> Void,
        onSelectArtist: @escaping (SoundCloudUser) -> Void
    ) {
        self.urn = urn
        self.seedTrack = seedTrack
        self.seedArtistName = seedArtistName
        self.model = model
        self.likes = likes
        self.onSelectTrack = onSelectTrack
        self.onSelectArtist = onSelectArtist
        _station = State(initialValue: model.cachedStation(urn: urn))
    }

    private var seedTrackURN: String? { seedTrack?.urn }
    private var tracks: [SoundCloudTrack] { station?.tracks ?? [] }
    private var title: String { station?.title ?? seedTrack?.title ?? seedArtistName ?? "Station" }
    private var stationType: String {
        let components = urn.split(separator: ":")
        if components.contains("artist-stations") { return "Artist station" }
        if components.contains("track-stations") { return "Track station" }
        return "Station"
    }
    private var currentStationTrack: SoundCloudTrack? {
        guard model.queue.source == .station(urn) else { return nil }
        return model.playback.currentTrack
    }
    private var startingTrack: SoundCloudTrack? { tracks.first }

    private var displayedTrack: SoundCloudTrack? {
        if let currentStationTrack { return currentStationTrack }
        if let seedTrackURN, let currentTrack = model.playback.currentTrack,
           currentTrack.urn == seedTrackURN {
            return currentTrack
        }
        return startingTrack ?? seedTrack
    }
    private var artworkURL: URL? {
        artworkTrack?.displayArtworkURL
    }
    private var artworkTitle: String { artworkTrack?.title ?? title }

    private var artworkTrack: SoundCloudTrack? { displayedTrack ?? seedTrack }

    var body: some View {
        ScrollbarReservedScrollView { _ in
            VStack(alignment: .leading, spacing: 24) {
                header
                VStack(alignment: .leading, spacing: trackLayout == .list ? 8 : 24) {
                    HStack {
                        CountedSectionHeader(title: "Tracks", count: station?.trackCount ?? tracks.count)
                        Spacer()
                        TrackLayoutPicker(trackLayout: $trackLayout)
                    }
                    .modifier(FadeInOnAppear())
                    if let message = model.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color.accentColor)
                    }
                    LazyVStack(alignment: .leading, spacing: 0) {
                        TrackCollectionTracks(
                            tracks: tracks, trackLayout: trackLayout, model: model,
                            onSelectTrack: onSelectTrack, onSelectArtist: onSelectArtist,
                            onPlayTrack: playTrack,
                            fadesInTracks: true
                        )
                        if let errorMessage {
                            Text(errorMessage).foregroundStyle(.secondary)
                            Button("Try Again") { loadAttempt += 1 }
                                .disabled(isLoading)
                        }
                        if isLoading {
                            LoadingSpinner()
                                .accessibilityLabel("Loading station")
                                .frame(maxWidth: .infinity)
                        } else if station != nil, tracks.isEmpty, errorMessage == nil {
                            EmptyStateView("No playable tracks")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .background(alignment: .top) {
            TrackCollectionBackdrop(artworkURL: artworkURL, loader: model.artworkLoader)
                .ignoresSafeArea(edges: .top)
        }
        .navigationTitle(title)
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible, placement: .primaryAction)
            } else {
                ToolbarItem(placement: .primaryAction) { Spacer() }
            }
            ToolbarItem(placement: .primaryAction) {
                OpenInSoundCloudButton(url: station?.permalinkURL)
                    .contentHelp("Open this station in your web browser")
            }
        }
        .task(id: loadAttempt) { await load() }
        .task(id: urn) {
            do {
                try await likes.loadStationLikes()
            } catch {
                guard !Task.isCancelled else { return }
                model.likeErrorMessage = error.localizedDescription
            }
        }
        .task(id: isOpeningSource) {
            guard isOpeningSource else { return }
            defer { isOpeningSource = false }
            do {
                let source = try await model.stationSource(urn: urn)
                try Task.checkCancellation()
                switch source {
                case let .track(track): onSelectTrack(track)
                case let .artist(artist): onSelectArtist(artist)
                }
            } catch {
                guard !Task.isCancelled else { return }
                sourceErrorMessage = error.localizedDescription
            }
        }
        .alert("Could not open station source", isPresented: Binding(
            get: { sourceErrorMessage != nil },
            set: { if !$0 { sourceErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { sourceErrorMessage = nil }
        } message: {
            Text(sourceErrorMessage ?? "Please try again.")
        }
        .sheet(isPresented: $isShowingArtwork) {
            FullSizeArtworkView(
                title: artworkTitle, artworkURL: artworkURL,
                loader: model.artworkLoader, cachedArtwork: $cachedFullSizeArtwork
            )
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            ZStack {
                DetailArtworkView(
                    artworkURL: artworkURL, title: artworkTitle,
                    loader: model.artworkLoader, size: 250,
                    cornerRadius: 12,
                    track: artworkTrack,
                    likes: model.likes,
                    onAddToQueue: model.addToQueue,
                    onShowArtwork: { isShowingArtwork = true }
                )
                .id(artworkTrack?.urn)
                .transition(DetailArtworkTransition(playback: model.playback, reduceMotion: reduceMotion))
            }
            .modifier(DetailArtworkTrackAnimation(trackURN: artworkTrack?.urn))
            .modifier(DetailArtworkRotation(
                isShowingArtwork: isShowingArtwork,
                flattensOnHover: true
            ))
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    stationTitle
                    stationLikeButton
                        .opacity(isHoveringStationRow ? 1 : 0)
                        .animation(
                            .easeInOut(duration: 0.2),
                            value: isHoveringStationRow
                        )
                }
                .contentShape(Rectangle())
                .onContentHover { isHoveringStationRow = $0 }
                .modifier(FadeInOnAppear())
                Group {
                    if let displayedTrack {
                        DetailTrackHeadingSlot(
                            track: displayedTrack,
                            isCollection: true,
                            collectionURN: urn,
                            artworkLoader: model.artworkLoader,
                            onSelectTrack: onSelectTrack,
                            onSelectArtist: onSelectArtist
                        )
                    } else {
                        Color.clear
                    }
                }
                .frame(minHeight: 64, alignment: .leading)
                playbackControls
                    .padding(.top, 10)
                    .modifier(FadeInOnAppear())
            }
            .modifier(DetailWaveformHeader(
                track: displayedTrack,
                isStation: true,
                onPlayTrack: playTrack
            ))
        }
    }

    private var stationTitle: some View {
        Button {
            if let seedTrack {
                onSelectTrack(seedTrack)
            } else {
                isOpeningSource = true
            }
        } label: {
            Label {
                Text("Station: \(title)")
                    .underline(isHoveringStationTitle)
            } icon: {
                Image(systemName: "dot.radiowaves.left.and.right")
            }
                .labelStyle(.titleAndIcon)
                .font(.body)
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onContentHover { isHoveringStationTitle = $0 }
        .disabled(isOpeningSource)
        .contentHelp(stationType == "Artist station" ? "View station artist" : "View station track")
        .accessibilityLabel("\(stationType == "Artist station" ? "View artist" : "View track"): \(title)")
    }

    private var stationLikeButton: some View {
        let isLiked = likes.likedStationURNs.contains(urn)
        let isUpdating = likes.isLoadingStationLikes || likes.updatingStationURNs.contains(urn)
        let actionLabel = "\(isLiked ? "Unlike" : "Like") station: \(title)"
        return Button {
            Task {
                do {
                    try await likes.toggleStationLike(urn: urn, title: title)
                } catch {
                    model.likeErrorMessage = error.localizedDescription
                }
            }
        } label: {
            Image(systemName: isLiked ? "heart.fill" : "heart")
                .foregroundStyle(.secondary)
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isUpdating)
        .contentHelp(actionLabel)
        .accessibilityLabel(actionLabel)
        .accessibilityValue(isUpdating ? "Updating" : (isLiked ? "Liked" : "Not liked"))
    }

    private var playbackControls: some View {
        ViewThatFits(in: .horizontal) {
            playbackControls(iconOnly: false)
                .labelStyle(.titleAndIcon)
                .fixedSize(horizontal: true, vertical: false)
            playbackControls(iconOnly: true)
                .labelStyle(.iconOnly)
        }
    }

    private func playbackControls(iconOnly: Bool) -> some View {
        let isStarting = currentStationTrack == nil
        let isPlaying = !isStarting && model.playback.isPlaybackActive
        return HStack(spacing: 12) {
            DetailPlayButtonSlot(configuration: DetailPlayButtonConfiguration(
                trackURN: displayedTrack?.urn, isCollection: true,
                isStarting: isStarting, isPlaying: isPlaying,
                isEnabled: currentStationTrack != nil || !tracks.isEmpty,
                iconOnly: iconOnly, subject: "station"
            )) {
                if currentStationTrack != nil {
                    model.playback.togglePlayPause()
                } else if let seedTrackURN, model.playback.currentTrack?.urn == seedTrackURN {
                    model.continuePlaybackInStation(
                        urn: urn, title: title, tracks: tracks, continuingTrackURN: seedTrackURN
                    )
                } else if let track = startingTrack {
                    Task { await playTrack(track) }
                }
            }
            Group {
                Button {
                    navigateTrack(backward: true)
                } label: {
                    Label("Previous track", systemImage: "backward.fill")
                        .frame(width: 44, height: 24)
                }
                .contentHelp("Previous track")
                Button {
                    navigateTrack(backward: false)
                } label: {
                    Label("Next track", systemImage: "forward.fill")
                        .frame(width: 44, height: 24)
                }
                .contentHelp("Next track")
            }
            .labelStyle(.iconOnly)
            .disabled(currentStationTrack == nil && tracks.isEmpty)
            if let track = displayedTrack {
                DetailLikeButton(
                    isLiked: likes.isLiked(track),
                    isUpdating: likes.updatingTrackURNs.contains(track.urn),
                    likeCount: likes.likeCount(for: track),
                    iconOnly: iconOnly,
                    subject: "track: \(track.title)"
                ) {
                    Task {
                        do {
                            try await likes.toggleLike(track)
                        } catch {
                            model.likeErrorMessage = error.localizedDescription
                        }
                    }
                }
                .detailSlot(trackURN: track.urn, isCollection: true)
            }
        }
        .font(.title3.weight(.semibold))
        .buttonStyle(TrackActionButtonStyle(fill: .primary.opacity(0.12)))
    }

    private func navigateTrack(backward: Bool) {
        if currentStationTrack != nil {
            if backward {
                model.playback.previous()
                if !model.playback.isPlaybackActive {
                    model.playback.togglePlayPause()
                }
            } else {
                model.playback.next()
            }
        } else if let track = displayedTrack {
            model.navigateTrack(from: track, offset: backward ? -1 : 1, queue: TrackQueue(
                source: .station(urn), tracks: [track] + tracks, stationTitle: title
            ))
        }
    }

    private func playTrack(_ track: SoundCloudTrack) async {
        await model.play(track, queue: TrackQueue(source: .station(urn), tracks: tracks, stationTitle: title))
    }

    private func load() async {
        if let cached = model.cachedStation(urn: urn) {
            station = cached
            errorMessage = nil
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await model.station(urn: urn)
            try Task.checkCancellation()
            station = result
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}

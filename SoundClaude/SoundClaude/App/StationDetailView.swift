import SwiftUI

struct StationDetailView: View {
    let urn: String
    let seedTrack: SoundCloudTrack?
    let seedArtistName: String?
    let model: AppModel
    @ObservedObject var likes: LikesController
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void

    @State private var station: SoundCloudStation?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var loadAttempt = 0
    @State private var isOpeningSource = false
    @State private var sourceErrorMessage: String?

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

    private var tracks: [SoundCloudTrack] { station?.tracks ?? [] }
    private var title: String { station?.title ?? seedTrack?.title ?? seedArtistName ?? "Station" }
    private var stationType: String {
        let components = urn.split(separator: ":")
        if components.contains("artist-stations") { return "Artist station" }
        if components.contains("track-stations") { return "Track station" }
        return "Station"
    }
    private var collection: TrackCollection {
        TrackCollection(kind: .station, urn: urn, title: title, tracks: tracks, seedTrack: seedTrack)
    }

    var body: some View {
        ScrollbarReservedScrollView { _ in
            VStack(alignment: .leading, spacing: 24) {
                header
                TrackCollectionSection(
                    count: station?.trackCount ?? tracks.count,
                    errorMessage: model.errorMessage
                ) { trackLayout in
                    LazyVStack(alignment: .leading, spacing: 0) {
                        TrackCollectionTrackList(
                            collection: collection, trackLayout: trackLayout, model: model,
                            onSelectTrack: onSelectTrack, onSelectArtist: onSelectArtist
                        )
                        .equatable()
                        TrackCollectionLoadStatus(
                            errorMessage: errorMessage,
                            isLoading: isLoading,
                            isEmpty: station != nil && tracks.isEmpty,
                            loadingLabel: "Loading station",
                            emptyMessage: "No playable tracks",
                            onRetry: { loadAttempt += 1 }
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(24)
        }
        .background(alignment: .top) {
            TrackCollectionBackdrop(collection: collection, model: model)
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
            // Load failures are shown with a retry action in the sidebar.
            try? await likes.loadStationLikes()
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
        #if DEBUG
        .debugViewUpdates("StationDetailView")
        #endif
    }

    private var header: some View {
        TrackCollectionHeader(
            collection: collection,
            model: model,
            likes: likes,
            showsControls: station != nil || seedTrack != nil,
            titleSpacing: 8,
            onSelectTrack: onSelectTrack,
            onSelectArtist: onSelectArtist
        ) {
            TrackCollectionTitleRow {
                Label {
                    StationSourceButton(
                        title: title,
                        isArtistStation: stationType == "Artist station",
                        isOpeningSource: isOpeningSource
                    ) {
                        if let seedTrack {
                            onSelectTrack(seedTrack)
                        } else {
                            isOpeningSource = true
                        }
                    }
                } icon: {
                    StationPlayingIcon(playback: model.playback, isCurrent: model.queue.source == .station(urn))
                }
            } actions: {
                TrackCollectionLikeButton(
                    isLiked: likes.likedStationURNs.contains(urn),
                    isUpdating: likes.isLoadingStationLikes || likes.updatingStationURNs.contains(urn),
                    subject: "station: \(title)"
                ) {
                    Task {
                        do {
                            try await likes.toggleStationLike(urn: urn, title: title)
                        } catch {
                            model.likeErrorMessage = error.localizedDescription
                        }
                    }
                }
            }
        } controlsFooter: {
            EmptyView()
        }
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

// Keep hover state local so pointer movement does not invalidate the detail header.
private struct StationSourceButton: View {
    let title: String
    let isArtistStation: Bool
    let isOpeningSource: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(Color.primary)
                .opacity(0.9)
                .underline(isHovered)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onContentHover { isHovered = $0 }
        .disabled(isOpeningSource)
        .contentHelp(isArtistStation ? "View station artist" : "View station track")
        .accessibilityLabel("\(isArtistStation ? "View artist" : "View track"): \(title)")
    }
}

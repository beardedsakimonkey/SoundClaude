import SwiftUI

// Reads playback state in its own body so track changes do not invalidate the page.
struct TrackCollectionBackdrop: View {
    let collection: TrackCollection
    let model: AppModel

    var body: some View {
        let backdrop = TrackArtworkBackdropView(
            artworkURL: collection.artworkURL(in: model),
            loader: model.artworkLoader,
            fadesToBottom: false,
            animatesChanges: true
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
}

// Owns the track layout preference so toggling it re-renders only this section.
struct TrackCollectionSection<Content: View>: View {
    let count: Int
    let errorMessage: String?
    @ViewBuilder let content: (TrackLayout) -> Content

    @AppStorage("playlistTrackLayout") private var trackLayout = TrackLayout.list

    var body: some View {
        VStack(alignment: .leading, spacing: trackLayout == .list ? 8 : 12) {
            HStack {
                CountedSectionHeader(title: "Tracks", count: count)
                Spacer()
                TrackLayoutPicker(trackLayout: $trackLayout)
            }
            .modifier(FadeInOnAppear())
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.accentColor)
            }
            content(trackLayout)
        }
    }
}

struct TrackCollectionTracks: View {
    let tracks: [SoundCloudTrack]
    let trackLayout: TrackLayout
    let model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    let onPlayTrack: (SoundCloudTrack) async -> Void
    var fadesInTracks = false
    var onRemoveFromPlaylist: ((SoundCloudTrack) -> Void)? = nil
    var isUpdatingPlaylist = false
    var removingTrackURN: String? = nil

    var body: some View {
        if trackLayout == .grid {
            TrackArtworkGrid(tracks: tracks, loader: model.artworkLoader) { track in
                TrackGridTile(
                    track: track,
                    playback: model.playback,
                    analyzer: model.analyzer,
                    artworkLoader: model.artworkLoader,
                    likes: model.likes,
                    onAddToQueue: model.addToQueue,
                    onRemoveFromPlaylist: onRemoveFromPlaylist,
                    isUpdatingPlaylist: isUpdatingPlaylist,
                    onSelectTrack: onSelectTrack,
                    onSelectArtist: onSelectArtist,
                    onPlayTrack: onPlayTrack
                )
                .opacity(removingTrackURN == track.urn ? 0.4 : 1)
                .animation(
                    .easeInOut(duration: 0.2),
                    value: removingTrackURN == track.urn
                )
                .modifier(FadeInOnAppear(isEnabled: fadesInTracks))
            }
            .padding(.bottom, 16)
        } else {
            TrackArtworkList(tracks: tracks, loader: model.artworkLoader) { track in
                TrackListRow(
                    track: track,
                    playback: model.playback,
                    analyzer: model.analyzer,
                    artworkLoader: model.artworkLoader,
                    likes: model.likes,
                    onAddToQueue: model.addToQueue,
                    onRemoveFromPlaylist: onRemoveFromPlaylist,
                    isUpdatingPlaylist: isUpdatingPlaylist,
                    onSelectTrack: onSelectTrack,
                    onSelectArtist: onSelectArtist,
                    onPlayTrack: onPlayTrack
                )
                .opacity(removingTrackURN == track.urn ? 0.4 : 1)
                .animation(
                    .easeInOut(duration: 0.2),
                    value: removingTrackURN == track.urn
                )
                .modifier(FadeInOnAppear(isEnabled: fadesInTracks))
            }
        }
    }
}

struct TrackCollection: Equatable {
    enum Kind { case playlist, station }

    let kind: Kind
    let urn: String
    let title: String
    let tracks: [SoundCloudTrack]
    var nextPageURL: URL? = nil
    var seedTrack: SoundCloudTrack? = nil
    var fallbackArtworkURL: URL? = nil

    var source: TrackQueue.Source { kind == .playlist ? .playlist(urn) : .station(urn) }
    var subject: String { kind == .playlist ? "playlist" : "station" }

    // These read playback state; call them from a body that should observe it.
    @MainActor func currentTrack(in model: AppModel) -> SoundCloudTrack? {
        guard model.queue.source == source else { return nil }
        return model.playback.currentTrack
    }

    @MainActor func displayedTrack(in model: AppModel) -> SoundCloudTrack? {
        if let currentTrack = currentTrack(in: model) { return currentTrack }
        if let seedTrack, let currentTrack = model.playback.currentTrack,
           currentTrack.urn == seedTrack.urn {
            return currentTrack
        }
        return tracks.first ?? seedTrack
    }

    @MainActor func artworkURL(in model: AppModel) -> URL? {
        guard let track = displayedTrack(in: model) else { return fallbackArtworkURL }
        return track.displayArtworkURL
    }

    func queue(leadingTrack: SoundCloudTrack? = nil) -> TrackQueue {
        // The queue drops the leading track if the collection already contains it.
        TrackQueue(
            source: source, tracks: (leadingTrack.map { [$0] } ?? []) + tracks,
            nextPageURL: nextPageURL, sourceTitle: title
        )
    }
}

// Starting playback re-renders this header only; the page body and track list do
// not read playback state.
struct TrackCollectionHeader<TitleRow: View, ControlsFooter: View>: View {
    private let artworkSize: CGFloat = 250

    let collection: TrackCollection
    let model: AppModel
    @ObservedObject var likes: LikesController
    // Controls also show while the collection is playing.
    var showsControls = true
    var titleSpacing: CGFloat = 10
    var onRemoveFromPlaylist: ((SoundCloudTrack) -> Void)? = nil
    var isUpdatingPlaylist = false
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    @ViewBuilder let titleRow: () -> TitleRow
    @ViewBuilder let controlsFooter: () -> ControlsFooter

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingArtwork = false
    @State private var cachedFullSizeArtwork: CachedFullSizeArtwork?

    var body: some View {
        let currentTrack = collection.currentTrack(in: model)
        let displayedTrack = collection.displayedTrack(in: model)
        let artworkURL = collection.artworkURL(in: model)
        let artworkTitle = displayedTrack?.title ?? collection.title

        HStack(alignment: .top, spacing: 24) {
            ZStack {
                DetailArtworkView(
                    artworkURL: artworkURL,
                    title: artworkTitle,
                    loader: model.artworkLoader,
                    size: artworkSize,
                    cornerRadius: 12,
                    track: displayedTrack,
                    likes: model.likes,
                    onAddToQueue: model.addToQueue,
                    onRemoveFromPlaylist: onRemoveFromPlaylist,
                    isUpdatingPlaylist: isUpdatingPlaylist,
                    onShowArtwork: { isShowingArtwork = true }
                )
                .id(displayedTrack?.urn)
                .transition(DetailArtworkTransition(playback: model.playback, reduceMotion: reduceMotion))
            }
            .modifier(DetailArtworkTrackAnimation(trackURN: displayedTrack?.urn))
            .modifier(DetailArtworkRotation(
                isShowingArtwork: isShowingArtwork,
                flattensOnHover: true
            ))

            VStack(alignment: .leading, spacing: 0) {
                titleRow()
                    .modifier(FadeInOnAppear())
                Group {
                    if let displayedTrack {
                        DetailTrackHeadingSlot(
                            track: displayedTrack,
                            isCollection: true,
                            collectionURN: collection.urn,
                            artworkLoader: model.artworkLoader,
                            onSelectTrack: onSelectTrack,
                            onSelectArtist: onSelectArtist
                        )
                    } else {
                        Color.clear
                    }
                }
                .frame(minHeight: 64, alignment: .leading)
                .padding(.top, titleSpacing)
                if showsControls || currentTrack != nil {
                    VStack(alignment: .leading, spacing: 16) {
                        ViewThatFits(in: .horizontal) {
                            playbackControls(currentTrack: currentTrack, displayedTrack: displayedTrack, iconOnly: false)
                                .labelStyle(.titleAndIcon)
                                .fixedSize(horizontal: true, vertical: false)
                            playbackControls(currentTrack: currentTrack, displayedTrack: displayedTrack, iconOnly: true)
                                .labelStyle(.iconOnly)
                            playbackControls(
                                currentTrack: currentTrack, displayedTrack: displayedTrack,
                                iconOnly: true, showsShuffle: false
                            )
                            .labelStyle(.iconOnly)
                        }
                        // Overflowing controls must not widen the column.
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        controlsFooter()
                    }
                    .padding(.top, 18)
                    .modifier(FadeInOnAppear())
                }
            }
            .modifier(DetailWaveformHeader(
                track: displayedTrack,
                isCollection: true,
                onPlayTrack: playTrack
            ))
        }
        .sheet(isPresented: $isShowingArtwork) {
            FullSizeArtworkView(
                title: artworkTitle,
                artworkURL: artworkURL,
                loader: model.artworkLoader,
                cachedArtwork: $cachedFullSizeArtwork
            )
        }
    }

    private func playbackControls(
        currentTrack: SoundCloudTrack?,
        displayedTrack: SoundCloudTrack?,
        iconOnly: Bool,
        showsShuffle: Bool = true
    ) -> some View {
        HStack(spacing: 12) {
            CollectionPlayButtonSlot(
                playback: model.playback,
                trackURN: displayedTrack?.urn,
                isStarting: currentTrack == nil,
                isEnabled: currentTrack != nil || !collection.tracks.isEmpty,
                iconOnly: iconOnly, subject: collection.subject
            ) {
                play(currentTrack: currentTrack)
            }
            if showsShuffle {
                shuffleButton
            }
            Group {
                Button {
                    navigateTrack(backward: true, currentTrack: currentTrack, displayedTrack: displayedTrack)
                } label: {
                    Label("Previous track", systemImage: "backward.fill")
                        .frame(width: 44, height: 24)
                }
                .contentHelp("Previous track")

                Button {
                    navigateTrack(backward: false, currentTrack: currentTrack, displayedTrack: displayedTrack)
                } label: {
                    Label("Next track", systemImage: "forward.fill")
                        .frame(width: 44, height: 24)
                }
                .contentHelp("Next track")
            }
            .labelStyle(.iconOnly)
            .disabled(currentTrack == nil && collection.tracks.isEmpty)
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

    private var shuffleButton: some View {
        Button {
            guard let track = collection.tracks.randomElement() else { return }
            if !model.playback.isShuffleEnabled {
                model.toggleShuffle()
            }
            Task {
                await model.play(track, queue: collection.queue(), loadRemainingTracks: true)
            }
        } label: {
            Label("Shuffle \(collection.subject)", systemImage: "shuffle")
                .frame(width: 44, height: 24)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(TrackActionButtonStyle(fill: .clear, hoverFill: .primary.opacity(0.12)))
        .contentHelp("Shuffle this \(collection.subject)")
        .disabled(collection.tracks.isEmpty)
    }

    private func play(currentTrack: SoundCloudTrack?) {
        if currentTrack != nil {
            model.playback.togglePlayPause()
        } else if let seedTrack = collection.seedTrack,
                  model.playback.currentTrack?.urn == seedTrack.urn {
            model.continuePlaybackInStation(
                urn: collection.urn, title: collection.title,
                tracks: collection.tracks, continuingTrackURN: seedTrack.urn
            )
        } else if let track = collection.tracks.first {
            Task { await playTrack(track) }
        }
    }

    private func navigateTrack(
        backward: Bool,
        currentTrack: SoundCloudTrack?,
        displayedTrack: SoundCloudTrack?
    ) {
        if currentTrack != nil {
            if backward {
                model.playback.previous()
                if !model.playback.isPlaybackActive {
                    model.playback.togglePlayPause()
                }
            } else {
                model.playback.next()
            }
        } else if let track = displayedTrack {
            model.navigateTrack(
                from: track, offset: backward ? -1 : 1,
                queue: collection.queue(leadingTrack: track)
            )
        }
    }

    private func playTrack(_ track: SoundCloudTrack) async {
        await model.play(track, queue: collection.queue())
    }
}

// Keep hover state local so pointer movement does not invalidate the detail header.
struct TrackCollectionTitleRow<Title: View, Actions: View>: View {
    @ViewBuilder let title: () -> Title
    @ViewBuilder let actions: () -> Actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            title()
                .labelStyle(.titleAndIcon)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            actions()
                .opacity(isHovered ? 1 : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isHovered)
        }
        .contentShape(Rectangle())
        .onContentHover { isHovered = $0 }
    }
}

struct TrackCollectionLikeButton: View {
    let isLiked: Bool
    let isUpdating: Bool
    // Names the liked item, e.g. "playlist: Title".
    let subject: String
    let action: () -> Void

    var body: some View {
        let actionLabel = "\(isLiked ? "Unlike" : "Like") \(subject)"
        Button(action: action) {
            Image(systemName: isLiked ? "heart.fill" : "heart")
        }
        .buttonStyle(TrackCollectionHeaderButtonStyle())
        .disabled(isUpdating)
        .contentHelp(actionLabel)
        .accessibilityLabel(actionLabel)
        .accessibilityValue(isUpdating ? "Updating" : (isLiked ? "Liked" : "Not liked"))
    }
}

private struct TrackCollectionHeaderButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let isHighlighted = isEnabled && (isHovered || configuration.isPressed)
        configuration.label
            .foregroundStyle(isHighlighted ? .primary : .secondary)
            .padding(4)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.5)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHighlighted)
            .onContentHover { isHovered = $0 }
            .onDisappear { isHovered = false }
    }
}

// Starting playback invalidates the page header. Compare only the inputs the row
// closures capture so the rows are not re-rendered with fresh closures.
struct TrackCollectionTrackList: View, Equatable {
    let collection: TrackCollection
    let trackLayout: TrackLayout
    let model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    var onRemoveFromPlaylist: ((SoundCloudTrack) -> Void)? = nil
    var isUpdatingPlaylist = false
    var removingTrackURN: String? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.collection == rhs.collection && lhs.trackLayout == rhs.trackLayout
            && (lhs.onRemoveFromPlaylist == nil) == (rhs.onRemoveFromPlaylist == nil)
            && lhs.isUpdatingPlaylist == rhs.isUpdatingPlaylist
            && lhs.removingTrackURN == rhs.removingTrackURN
    }

    var body: some View {
        TrackCollectionTracks(
            tracks: collection.tracks, trackLayout: trackLayout, model: model,
            onSelectTrack: onSelectTrack, onSelectArtist: onSelectArtist,
            onPlayTrack: playTrack,
            fadesInTracks: true,
            onRemoveFromPlaylist: onRemoveFromPlaylist,
            isUpdatingPlaylist: isUpdatingPlaylist,
            removingTrackURN: removingTrackURN
        )
    }

    private func playTrack(_ track: SoundCloudTrack) async {
        await model.play(track, queue: collection.queue())
    }
}

struct TrackCollectionLoadStatus: View {
    let errorMessage: String?
    let isLoading: Bool
    let isEmpty: Bool
    let loadingLabel: String
    let emptyMessage: LocalizedStringKey
    let onRetry: () -> Void

    var body: some View {
        if let errorMessage {
            Text(errorMessage).foregroundStyle(.secondary)
            Button("Try Again", action: onRetry)
                .disabled(isLoading)
        }
        if isLoading {
            LoadingSpinner()
                .accessibilityLabel(loadingLabel)
                .frame(maxWidth: .infinity)
        } else if isEmpty, errorMessage == nil {
            EmptyStateView(emptyMessage)
        }
    }
}

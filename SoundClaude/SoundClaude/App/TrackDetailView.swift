import AppKit
import Foundation
import SwiftUI

struct TrackDetailView: View {
    let track: SoundCloudTrack
    let model: AppModel
    @ObservedObject private var reposts: RepostsController
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    let onSelectStation: (String, SoundCloudTrack) -> Void

    @State private var details: SoundCloudTrackDetails?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var repostErrorMessage: String?

    init(
        track: SoundCloudTrack,
        model: AppModel,
        onSelectTrack: @escaping (SoundCloudTrack) -> Void,
        onSelectArtist: @escaping (SoundCloudUser) -> Void,
        onSelectStation: @escaping (String, SoundCloudTrack) -> Void
    ) {
        self.track = track
        self.model = model
        _reposts = ObservedObject(wrappedValue: model.reposts)
        self.onSelectTrack = onSelectTrack
        self.onSelectArtist = onSelectArtist
        self.onSelectStation = onSelectStation

        let cachedDetails = model.cachedTrackDetails(for: track)
        _details = State(initialValue: cachedDetails)
        _isLoading = State(initialValue: cachedDetails == nil)
    }

    var body: some View {
        detailsView
        .preference(
            key: DetailBackdropPreferenceKey.self,
            value: .track(artworkURL: details?.track.displayArtworkURL ?? track.displayArtworkURL)
        )
        .navigationTitle(details?.track.title ?? track.title)
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible, placement: .primaryAction)
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Spacer()
                }
            }
            ToolbarItem(placement: .primaryAction) {
                OpenInSoundCloudButton(url: details?.track.permalinkURL ?? track.permalinkURL)
                    .contentHelp("Open this track in your web browser")
            }
        }
        .task(id: track.urn) {
            await load()
        }
        .task(id: track.urn) {
            await model.prefetchPlaybackWhileViewing(track)
        }
        .task {
            // Retry on click and show any error there.
            try? await reposts.load()
        }
        .alert("Could not update repost", isPresented: Binding(
            get: { repostErrorMessage != nil },
            set: { if !$0 { repostErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { repostErrorMessage = nil }
        } message: {
            Text(repostErrorMessage ?? "Please try again.")
        }
        #if DEBUG
        .debugViewUpdates("TrackDetailView")
        #endif
    }

    private var displayedTrack: SoundCloudTrack { details?.track ?? track }

    // Keep the header mounted while the request fills in the rest of the page.
    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            TrackDetailArtwork(track: displayedTrack, model: model)

            VStack(alignment: .leading, spacing: 10) {
                if displayedTrack.access == .preview {
                    TrackPreviewBadge(font: .callout)
                }
                DetailTrackHeadingSlot(
                    track: displayedTrack,
                    artworkLoader: model.artworkLoader,
                    onSelectTrack: onSelectTrack,
                    onSelectArtist: onSelectArtist
                )
                ViewThatFits(in: .horizontal) {
                    trackActions(for: displayedTrack, iconOnly: false)
                        .labelStyle(.titleAndIcon)
                        .fixedSize(horizontal: true, vertical: false)
                    trackActions(for: displayedTrack, iconOnly: true)
                        .labelStyle(.iconOnly)
                }
                // Overflowing controls must not widen the column.
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .modifier(FadeInOnAppear())
            }
            .modifier(DetailWaveformHeader(
                track: displayedTrack,
                showsWaveform: displayedTrack.waveformURL != nil
            ))
        }
    }

    private var detailsView: some View {
        ScrollbarReservedScrollView { _ in
            VStack(alignment: .leading, spacing: 24) {
                header

                if let details {
                    if let description = nonempty(details.description) {
                        ExpandableDescriptionText(
                            description: description,
                            onSelectArtist: onSelectArtist
                        )
                        .modifier(FadeInOnAppear())
                        .id(track.urn)
                    }

                    let genre = nonempty(details.genre)
                    let tags = details.tags.filter { tag in
                        guard let genre else { return true }
                        return tag.trimmingCharacters(in: .whitespacesAndNewlines)
                            .caseInsensitiveCompare(genre) != .orderedSame
                    }
                    if genre != nil || !tags.isEmpty {
                        TagLayout {
                            if let genre {
                                GenrePill(genre: genre)
                            }
                            ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                                TagPill(tag: tag)
                            }
                        }
                        .modifier(FadeInOnAppear())
                    }

                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(alignment: .firstTextBaseline) {
                                CountedSectionHeader(
                                    title: "Comments",
                                    count: details.commentCount
                                )
                                Spacer()
                                CommentSortMenu()
                            }
                            .modifier(FadeInOnAppear())

                            TrackCommentsView(
                                track: details.track,
                                model: model,
                                onSelectArtist: onSelectArtist,
                                onCommentCountChange: { change in
                                    if let count = self.details?.commentCount {
                                        self.details?.commentCount = max(0, count + change)
                                    }
                                }
                            )
                            .id(track.urn)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)

                        TrackDetailRelatedTracks(
                            track: track,
                            model: model,
                            onSelectTrack: onSelectTrack,
                            onSelectArtist: onSelectArtist
                        )
                        .id(track.urn)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                } else if isLoading {
                    LoadingSpinner()
                        .accessibilityLabel("Loading track")
                        .frame(maxWidth: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("Could not load track", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage ?? "An unknown error occurred.")
                    } actions: {
                        Button("Try Again") {
                            Task { await load() }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(24)
            .remembersScrollPosition()
        }
    }

    private func trackActions(for track: SoundCloudTrack, iconOnly: Bool) -> some View {
        HStack(spacing: 12) {
            playButton(for: track, iconOnly: iconOnly)
            likeButton(for: track, iconOnly: iconOnly)
            repostButton(for: track, iconOnly: iconOnly)
                .detailSwapSlot(id: "repost", trackURN: track.urn)
            if let stationURN = nonempty(track.stationURN) {
                TrackDetailStationButton(urn: stationURN) {
                    onSelectStation(stationURN, details?.track ?? track)
                }
                .detailSwapSlot(id: "station", trackURN: track.urn)
            }
        }
    }

    private func playButton(for track: SoundCloudTrack, iconOnly: Bool) -> some View {
        TrackDetailPlayButton(track: track, model: model, iconOnly: iconOnly)
    }

    private func likeButton(for track: SoundCloudTrack, iconOnly: Bool) -> some View {
        DetailLikeButton(track: track, likes: model.likes, iconOnly: iconOnly, subject: "track") { error in
            model.likeErrorMessage = error.localizedDescription
        }
        .detailSlot(trackURN: track.urn)
    }

    private func repostButton(for track: SoundCloudTrack, iconOnly: Bool) -> some View {
        TrackDetailRepostButton(track: track, reposts: reposts, iconOnly: iconOnly) { error in
            repostErrorMessage = error.localizedDescription
        }
    }

    private func nonempty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func load() async {
        if let cachedDetails = model.cachedTrackDetails(for: track) {
            details = cachedDetails
            isLoading = false
            errorMessage = nil
            return
        }

        isLoading = true
        errorMessage = nil
        do {
            let result = try await model.trackDetails(for: track)
            try Task.checkCancellation()
            details = result
        } catch {
            guard !Task.isCancelled else { return }
            details = nil
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

// Keep hover and sheet state local so artwork interactions do not rebuild the page.
private struct TrackDetailArtwork: View {
    private let artworkSize: CGFloat = 250
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let track: SoundCloudTrack
    let model: AppModel

    @State private var isShowingArtwork = false
    @State private var isHoveringArtwork = false

    private var isArtworkHoverActive: Bool { isHoveringArtwork || isShowingArtwork }

    var body: some View {
        DetailArtworkView(
            artworkURL: track.displayArtworkURL,
            title: track.title,
            loader: model.artworkLoader,
            size: artworkSize,
            animatesChanges: true,
            showsPlaceholderIcon: false,
            cornerRadius: 12,
            artworkLift: isArtworkHoverActive && !reduceMotion ? DetailArtworkMotion.hoverLift : 0,
            hoverStyle: .lift,
            isShowingArtwork: isShowingArtwork,
            onImageHover: { isHoveringArtwork = $0 },
            track: track,
            likes: model.likes,
            onAddToQueue: model.addToQueue,
            onShowArtwork: { isShowingArtwork = true }
        )
        .modifier(DetailArtworkRotation(
            artworkSize: artworkSize,
            isRotated: false,
            isShowingArtwork: isShowingArtwork,
            imageHover: isHoveringArtwork
        ))
        .animation(
            reduceMotion ? nil : (isArtworkHoverActive
                ? DetailArtworkMotion.hoverIn : DetailArtworkMotion.hoverOut),
            value: isArtworkHoverActive
        )
        .animation(
            reduceMotion ? nil : (isArtworkHoverActive
                ? DetailArtworkMotion.hoverIn : DetailArtworkMotion.hoverOut)
        ) { content in
            content.scaleEffect(isArtworkHoverActive && !reduceMotion ? DetailArtworkMotion.hoverScale : 1)
        }
        .modifier(DetailArtworkFootprint(size: artworkSize))
        .sheet(isPresented: $isShowingArtwork) {
            FullSizeArtworkView(
                title: track.title,
                artworkURL: track.displayArtworkURL,
                loader: model.artworkLoader
            )
        }
    }
}

private struct TrackDetailStationButton: View {
    let urn: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Open track station", systemImage: "dot.radiowaves.left.and.right")
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 24)
        }
        .buttonStyle(TrackActionButtonStyle(fill: .primary.opacity(0.12)))
        .contentHelp("Open this track’s station")
        // Only the visible copy is hovered, not the page's hidden sizing copy.
        .prefetch(.station(urn))
    }
}

// Observe transport state here so loading and playback changes do not rebuild
// the detail header, description, tags, and comment list.
private struct TrackDetailPlayButton: View {
    let track: SoundCloudTrack
    let model: AppModel
    let iconOnly: Bool

    var body: some View {
        let playback = model.playback
        let isCurrentTrack = playback.currentTrack?.urn == track.urn
        let isPlaying = isCurrentTrack && playback.isPlaybackActive

        DetailPlayButtonSlot(configuration: DetailPlayButtonConfiguration(
            trackURN: track.urn, isPlaying: isPlaying,
            isEnabled: track.access != .protected, iconOnly: iconOnly
        )) {
            if playback.currentTrack?.urn == track.urn {
                playback.togglePlayPause()
            } else {
                Task { await model.play(track) }
            }
        }
    }
}

// Pagination changes only this column, keeping the header and comments out of its updates.
private struct TrackDetailRelatedTracks: View {
    let track: SoundCloudTrack
    let model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void

    @State private var relatedTracks: [SoundCloudTrack] = []
    @State private var nextPageURL: URL?
    @State private var loadedPageURLs: Set<URL> = []
    @State private var hasLoadedRelatedTracks = false
    @State private var isLoadingRelatedTracks = false
    // Owned by the list, not the spinner, so scrolling the spinner away does not cancel it.
    @State private var pageTask: Task<Void, Never>?
    @State private var relatedTracksErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Related tracks")
                .font(.sectionHeading)
                .opacity(0.96)
                .modifier(FadeInOnAppear())
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.accentColor)
                    .modifier(FadeInOnAppear())
            }
            relatedTrackList
        }
        .task(id: track.urn) {
            if !hasLoadedRelatedTracks { await loadRelatedTracks() }
        }
        .onDisappear { pageTask?.cancel() }
    }

    private var relatedTrackList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            TrackArtworkList(tracks: relatedTracks, loader: model.artworkLoader) { relatedTrack in
                TrackListRow(
                    track: relatedTrack,
                    playback: model.playback,
                    analyzer: model.analyzer,
                    artworkLoader: model.artworkLoader,
                    likes: model.likes,
                    onAddToQueue: model.addToQueue,
                    onSelectTrack: onSelectTrack,
                    onSelectArtist: onSelectArtist,
                    onPlayTrack: { selected in
                        await model.play(selected, queue: TrackQueue(
                            source: .related(track.urn),
                            tracks: relatedTracks,
                            nextPageURL: nextPageURL,
                            sourceTrack: track
                        ))
                    }
                )
                .modifier(FadeInOnAppear())
            }
            if let relatedTracksErrorMessage {
                Text(relatedTracksErrorMessage).foregroundStyle(.secondary)
                    .modifier(FadeInOnAppear())
                Button("Try Again") { Task { await loadRelatedTracks() } }
                    .disabled(isLoadingRelatedTracks)
                    .modifier(FadeInOnAppear())
            }
            if isLoadingRelatedTracks || (nextPageURL != nil && relatedTracksErrorMessage == nil) {
                LoadingSpinner()
                    .accessibilityLabel("Loading related tracks")
                    .frame(maxWidth: .infinity)
                    .modifier(FadeInOnAppear())
                    .task {
                        guard nextPageURL != nil, relatedTracksErrorMessage == nil else { return }
                        startLoadingRelatedTracks()
                    }
                    // A new spinner per page. Reusing the first-load spinner would
                    // request the next page while it is still built but off screen.
                    .id(nextPageURL)
            } else if hasLoadedRelatedTracks, relatedTracks.isEmpty,
                      relatedTracksErrorMessage == nil {
                EmptyStateView("No related tracks")
                    .modifier(FadeInOnAppear())
            }
        }
    }

    private func startLoadingRelatedTracks() {
        guard pageTask == nil else { return }
        pageTask = Task {
            await loadRelatedTracks()
            pageTask = nil
        }
    }

    private func loadRelatedTracks() async {
        guard !isLoadingRelatedTracks,
              !hasLoadedRelatedTracks || nextPageURL != nil else { return }
        isLoadingRelatedTracks = true
        relatedTracksErrorMessage = nil
        defer { isLoadingRelatedTracks = false }
        do {
            let pageURL = nextPageURL
            let page = try await model.relatedTracks(for: track, pageURL: pageURL)
            try Task.checkCancellation()
            if let nextURL = page.nextURL,
               nextURL == pageURL || loadedPageURLs.contains(nextURL) {
                throw SoundCloudError.invalidData
            }
            var knownURNs = Set(relatedTracks.map(\.urn))
            knownURNs.insert(track.urn)
            relatedTracks.append(contentsOf: page.tracks.filter {
                knownURNs.insert($0.urn).inserted
            })
            if let pageURL { loadedPageURLs.insert(pageURL) }
            nextPageURL = page.nextURL
            hasLoadedRelatedTracks = true
        } catch {
            guard !Task.isCancelled else { return }
            relatedTracksErrorMessage = error.localizedDescription
        }
    }
}

struct TrackActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    let fill: Color
    var hoverFill: Color? = nil
    var hoverForeground: Color? = nil
    // Solid fills dim on hover instead of gaining a translucent layer behind them.
    var dimsOnHover = false

    func makeBody(configuration: Configuration) -> some View {
        let isHovered = isHovering && isEnabled
        configuration.label
            .foregroundStyle(isHovered ? (hoverForeground ?? .primary) : .primary)
            .animation(hoverForeground == nil ? nil : .easeInOut(duration: 0.15), value: isHovered)
            .padding(.vertical, 10)
            .background {
                Capsule()
                    .fill(fill.opacity(dimsOnHover && isHovered ? 0.8 : 1))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovered)
            }
            .background {
                Capsule()
                    .fill((hoverFill ?? fill).opacity(!dimsOnHover && isHovered ? 0.7 : 0))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovered)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.5)
            .pressBounce(configuration.isPressed)
            // Keep the click area at its original size while the label scales.
            .contentShape(Capsule())
            .onContentHover { isHovering = $0 }
    }
}

private struct TrackDetailRepostButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let track: SoundCloudTrack
    @ObservedObject var reposts: RepostsController
    let iconOnly: Bool
    let onError: (Error) -> Void

    @State private var repostTaps = 0

    private var isReposted: Bool { reposts.isReposted(track) }
    // The initial load decides whether a tap adds or removes the repost.
    private var isUpdating: Bool { reposts.isLoading || reposts.isUpdating(trackURN: track.urn) }
    private var repostCount: Int? { reposts.repostCount(for: track) }

    private var hasCount: Bool { !iconOnly && (repostCount ?? 0) != 0 }
    private var actionLabel: String { isReposted ? "Undo repost" : "Repost track" }

    var body: some View {
        Button {
            guard !reposts.isLoading else { return }
            if !isReposted { repostTaps += 1 }
            Task {
                do {
                    try await reposts.toggleRepost(track)
                } catch is CancellationError {
                } catch {
                    onError(error)
                }
            }
        } label: {
            ZStack {
                label
                    .opacity(isReposted ? 0 : 1)
                    .accessibilityHidden(isReposted)
                label
                    .foregroundStyle(Color.green)
                    .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? 0 : repostTaps)
                    .opacity(isReposted ? 1 : 0)
                    .accessibilityHidden(!isReposted)
            }
            .labelStyle(.titleAndIcon)
            .font(.title3.weight(.semibold))
            .padding(.horizontal, hasCount ? 24 : 0)
            .frame(width: hasCount ? nil : 44)
            .frame(minHeight: 24)
        }
        .buttonStyle(TrackActionButtonStyle(
            fill: isReposted ? .green.opacity(0.12) : .primary.opacity(0.12)
        ))
        // Keep the button enabled so a pending request cannot interrupt its release spring.
        .opacity(isUpdating ? 0.5 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isReposted)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isUpdating)
        .contentHelp(actionLabel)
        .accessibilityLabel(actionLabel)
        .accessibilityValue(isUpdating ? "Updating" : (isReposted ? "Reposted" : "Not reposted"))
    }

    @ViewBuilder
    private var label: some View {
        if hasCount, let repostCount {
            Label(repostCount.formatted(.number), systemImage: "arrow.2.squarepath")
        } else {
            Image(systemName: "arrow.2.squarepath")
        }
    }
}

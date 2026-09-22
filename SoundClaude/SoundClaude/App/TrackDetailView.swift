import AppKit
import Foundation
import SwiftUI

struct TrackDetailView: View {
    private let artworkSize: CGFloat = 250

    let track: SoundCloudTrack
    @ObservedObject var model: AppModel
    @ObservedObject private var likes: LikesController
    @ObservedObject private var reposts: RepostsController
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    let onSelectStation: (String, SoundCloudTrack) -> Void

    @State private var relatedTracks: [SoundCloudTrack] = []
    @State private var nextPageURL: URL?
    @State private var loadedPageURLs: Set<URL> = []
    @State private var hasLoadedRelatedTracks = false
    @State private var isLoadingRelatedTracks = false
    @State private var relatedTracksErrorMessage: String?
    @State private var details: SoundCloudTrackDetails?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var repostErrorMessage: String?
    @State private var isShowingArtwork = false
    @State private var cachedFullSizeArtwork: CachedFullSizeArtwork?

    init(
        track: SoundCloudTrack,
        model: AppModel,
        onSelectTrack: @escaping (SoundCloudTrack) -> Void,
        onSelectArtist: @escaping (SoundCloudUser) -> Void,
        onSelectStation: @escaping (String, SoundCloudTrack) -> Void
    ) {
        self.track = track
        self.model = model
        _likes = ObservedObject(wrappedValue: model.likes)
        _reposts = ObservedObject(wrappedValue: model.reposts)
        self.onSelectTrack = onSelectTrack
        self.onSelectArtist = onSelectArtist
        self.onSelectStation = onSelectStation

        let cachedDetails = model.cachedTrackDetails(for: track)
        _details = State(initialValue: cachedDetails)
        _isLoading = State(initialValue: cachedDetails == nil)
    }

    var body: some View {
        ZStack(alignment: .top) {
            artworkBackdrop
                .ignoresSafeArea(edges: .top)

            Group {
                if let details {
                    detailsView(details)
                } else if isLoading {
                    ProgressView()
                        .accessibilityLabel("Loading track")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label(
                            "Could not load track",
                            systemImage: "exclamationmark.triangle"
                        )
                    } description: {
                        Text(errorMessage ?? "An unknown error occurred.")
                    } actions: {
                        Button("Try Again") {
                            Task { await load() }
                        }
                    }
                }
            }
        }
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
                    .help("Open this track in your web browser")
            }
        }
        .task(id: track.urn) {
            await load()
        }
        .task(id: track.urn) {
            if !hasLoadedRelatedTracks { await loadRelatedTracks() }
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
        .sheet(isPresented: $isShowingArtwork) {
            FullSizeArtworkView(
                title: details?.track.title ?? track.title,
                artworkURL: details?.track.displayArtworkURL ?? track.displayArtworkURL,
                loader: model.artworkLoader,
                cachedArtwork: $cachedFullSizeArtwork
            )
        }
    }

    @ViewBuilder
    private var artworkBackdrop: some View {
        let backdrop = TrackArtworkBackdropView(
            artworkURL: details?.track.displayArtworkURL ?? track.displayArtworkURL,
            loader: model.artworkLoader,
            fadesToBottom: false
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

    private func detailsView(_ details: SoundCloudTrackDetails) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 24) {
                    DetailArtworkView(
                        artworkURL: details.track.displayArtworkURL,
                        title: details.track.title,
                        loader: model.artworkLoader,
                        size: artworkSize,
                        animatesChanges: true,
                        showsPlaceholderIcon: false,
                        cornerRadius: 12,
                        dragTrack: details.track,
                        onShowArtwork: { isShowingArtwork = true }
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        if details.track.access == .preview {
                            TrackPreviewBadge(font: .callout)
                        }
                        Text(details.track.title)
                            .font(.system(size: 36, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .foregroundStyle(.primary)
                            .opacity(0.9)
                            .textSelection(.enabled)
                            .modifier(FadeInOnAppear())
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            ArtistLink(
                                artist: details.track.artist,
                                artworkLoader: model.artworkLoader,
                                onSelect: onSelectArtist
                            )

                            RelativeTimestampView(
                                timestamp: details.createdAt,
                                accessibilityPrefix: "Created"
                            )
                        }
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .modifier(FadeInOnAppear())
                        ViewThatFits(in: .horizontal) {
                            trackActions(for: details.track, iconOnly: false)
                                .labelStyle(.titleAndIcon)
                                .fixedSize(horizontal: true, vertical: false)
                            trackActions(for: details.track, iconOnly: true)
                                .labelStyle(.iconOnly)
                        }
                        .padding(.top, 8)
                        .modifier(FadeInOnAppear())

                        if details.track.waveformURL != nil {
                            Spacer(minLength: 6)
                            TrackWaveformView(track: details.track, model: model)
                                .offset(y: -2)
                        }
                    }
                    // Put the waveform ground at the artwork's bottom edge.
                    .frame(
                        minHeight: details.track.waveformURL != nil
                            ? artworkSize + TrackWaveformView.Layout.detail.reflectionHeight : nil,
                        alignment: .topLeading
                    )
                }

                if let description = nonempty(details.description) {
                    ExpandableDescriptionText(
                        description: description,
                        onSelectArtist: onSelectArtist
                    )
                    .id(track.urn)
                }

                if !details.tags.isEmpty {
                    TrackTagLayout {
                        ForEach(Array(details.tags.enumerated()), id: \.offset) { _, tag in
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
                            onCommentAdded: {
                                if let count = self.details?.commentCount {
                                    self.details?.commentCount = count + 1
                                }
                            }
                        )
                        .id(track.urn)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                    VStack(alignment: .leading, spacing: 16) {
                        Text("Related tracks")
                            .font(.headline)
                            .opacity(0.96)
                            .modifier(FadeInOnAppear())
                        if let message = model.errorMessage {
                            Label(message, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(Color.accentColor)
                                .modifier(FadeInOnAppear())
                        }
                        relatedTrackList
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    private var relatedTrackList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(relatedTracks) { relatedTrack in
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
                            nextPageURL: nextPageURL
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
                ProgressView()
                    .accessibilityLabel("Loading related tracks")
                    .frame(maxWidth: .infinity)
                    .modifier(FadeInOnAppear())
                    .task(id: nextPageURL) {
                        guard nextPageURL != nil, relatedTracksErrorMessage == nil else { return }
                        await loadRelatedTracks()
                    }
            } else if hasLoadedRelatedTracks, relatedTracks.isEmpty,
                      relatedTracksErrorMessage == nil {
                EmptyStateView("No related tracks")
                .modifier(FadeInOnAppear())
            }
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

    private func trackActions(for track: SoundCloudTrack, iconOnly: Bool) -> some View {
        HStack(spacing: 12) {
            playButton(for: track, iconOnly: iconOnly)
            likeButton(for: track, iconOnly: iconOnly)
            repostButton(for: track, iconOnly: iconOnly)
            if let stationURN = nonempty(track.stationURN) {
                stationButton(urn: stationURN)
            }
        }
    }

    private func playButton(for track: SoundCloudTrack, iconOnly: Bool) -> some View {
        playButtonLabel(for: track, iconOnly: iconOnly)
            .buttonStyle(TrackActionButtonStyle(fill: .primary.opacity(0.12)))
    }

    private func playButtonLabel(for track: SoundCloudTrack, iconOnly: Bool) -> some View {
        let playback = model.playback
        let isCurrentTrack = playback.currentTrack?.urn == track.urn
        let isPlaying = isCurrentTrack && playback.isPlaybackActive

        return Button {
            if playback.currentTrack?.urn == track.urn {
                playback.togglePlayPause()
            } else {
                Task { await model.play(track) }
            }
        } label: {
            ZStack {
                Label("Play", systemImage: "play.fill")
                    .opacity(isPlaying ? 0 : 1)
                    .accessibilityHidden(isPlaying)
                Label("Pause", systemImage: "pause.fill")
                    .opacity(isPlaying ? 1 : 0)
                    .accessibilityHidden(!isPlaying)
            }
                .font(.title3.weight(.semibold))
                .padding(.horizontal, iconOnly ? 0 : 24)
                .frame(width: iconOnly ? 44 : nil)
                .frame(minHeight: 24)
        }
        .help(isPlaying ? "Pause" : "Play")
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }

    private func likeButton(for track: SoundCloudTrack, iconOnly: Bool) -> some View {
        DetailLikeButton(
            isLiked: likes.isLiked(track),
            isUpdating: likes.updatingTrackURNs.contains(track.urn),
            likeCount: likes.likeCount(for: track),
            iconOnly: iconOnly,
            subject: "track"
        ) {
            Task {
                do {
                    try await likes.toggleLike(track)
                } catch {
                    model.likeErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func repostButton(for track: SoundCloudTrack, iconOnly: Bool) -> some View {
        let isReposted = reposts.isReposted(track)
        let repostCount = reposts.repostCount(for: track)
        let hasCount = !iconOnly && (repostCount ?? 0) != 0

        return Button {
            Task {
                do {
                    try await reposts.toggleRepost(track)
                } catch is CancellationError {
                } catch {
                    repostErrorMessage = error.localizedDescription
                }
            }
        } label: {
            Group {
                if hasCount, let repostCount {
                    Label(repostCount.formatted(.number), systemImage: "arrow.2.squarepath")
                } else {
                    Image(systemName: "arrow.2.squarepath")
                }
            }
                .foregroundStyle(isReposted ? Color.green : Color.primary)
                .labelStyle(.titleAndIcon)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, hasCount ? 24 : 0)
                .frame(width: hasCount ? nil : 44)
                .frame(minHeight: 24)
        }
        .buttonStyle(TrackActionButtonStyle(
            fill: isReposted ? .green.opacity(0.12) : .primary.opacity(0.12)
        ))
        .disabled(reposts.isLoading || reposts.updatingTrackURNs.contains(track.urn))
        .help(isReposted ? "Undo repost" : "Repost track")
        .accessibilityLabel(isReposted ? "Undo repost" : "Repost track")
        .accessibilityValue(isReposted ? "Reposted" : "Not reposted")
    }

    private func stationButton(urn: String) -> some View {
        Button {
            onSelectStation(urn, details?.track ?? track)
        } label: {
            Label("Open track station", systemImage: "dot.radiowaves.left.and.right")
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 24)
        }
        .buttonStyle(TrackActionButtonStyle(fill: .primary.opacity(0.12)))
        .help("Open this track’s station")
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
            details = try await model.trackDetails(for: track)
        } catch {
            details = nil
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct TrackActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    let fill: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .padding(.vertical, 10)
            .background(fill, in: Capsule())
            .background {
                Capsule()
                    .fill(fill.opacity(isHovering && isEnabled ? 0.7 : 0))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovering && isEnabled)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.5)
            .scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? 0.86 : 1)
            .animation(
                reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.65),
                value: configuration.isPressed && isEnabled
            )
            // Keep the click area at its original size while the label scales.
            .contentShape(Capsule())
            .onContentHover { isHovering = $0 }
    }
}

/// Wrap tags onto a new row when they exceed the available width.
private struct TrackTagLayout: Layout {
    private let spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrangement(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + layout.origins[index].x, y: bounds.minY + layout.origins[index].y),
                proposal: ProposedViewSize(width: bounds.width, height: nil)
            )
        }
    }

    private func arrangement(width: CGFloat?, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        let availableWidth = width ?? .infinity
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var contentWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0 && x + size.width > availableWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            contentWidth = max(contentWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width ?? contentWidth, height: y + rowHeight), origins)
    }
}

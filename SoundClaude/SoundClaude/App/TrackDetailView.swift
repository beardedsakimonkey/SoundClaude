import AppKit
import Foundation
import SwiftUI

struct TrackDetailView: View {

    let track: SoundCloudTrack
    @ObservedObject var model: AppModel
    @ObservedObject private var likes: LikesController
    @ObservedObject private var reposts: RepostsController
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void

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
    @State private var isHoveringArtwork = false
    @State private var cachedFullSizeArtwork: CachedFullSizeArtwork?

    init(
        track: SoundCloudTrack,
        model: AppModel,
        onSelectTrack: @escaping (SoundCloudTrack) -> Void,
        onSelectArtist: @escaping (SoundCloudUser) -> Void
    ) {
        self.track = track
        self.model = model
        _likes = ObservedObject(wrappedValue: model.likes)
        _reposts = ObservedObject(wrappedValue: model.reposts)
        self.onSelectTrack = onSelectTrack
        self.onSelectArtist = onSelectArtist

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
                    ProgressView("Loading track")
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
                    artworkView(for: details.track)

                    VStack(alignment: .leading, spacing: 10) {
                        if details.track.access == .preview {
                            TrackPreviewBadge(font: .callout)
                        }
                        Text(details.track.title)
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundStyle(.primary)
                            .opacity(0.9)
                            .textSelection(.enabled)
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
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: 12) {
                                playButton(for: details.track)
                                likeButton(for: details.track)
                                repostButton(for: details.track)
                            }

                            if details.track.waveformURL != nil {
                                TrackWaveformView(track: details.track, model: model)
                            }
                        }
                        .padding(.top, 8)
                    }
                }

                if let description = nonempty(details.description) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Description")
                            .font(.headline)
                            .opacity(0.96)
                        ExpandableDescriptionText(
                            description: description,
                            onSelectArtist: onSelectArtist
                        )
                        .id(track.urn)
                    }
                }

                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 16) {
                        CountedSectionHeader(
                            title: "Comments",
                            count: details.commentCount
                        )

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
                        if let message = model.errorMessage {
                            Label(message, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
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
            }
            if let relatedTracksErrorMessage {
                Text(relatedTracksErrorMessage).foregroundStyle(.secondary)
                Button("Try Again") { Task { await loadRelatedTracks() } }
                    .disabled(isLoadingRelatedTracks)
            }
            if isLoadingRelatedTracks || (nextPageURL != nil && relatedTracksErrorMessage == nil) {
                ProgressView("Loading related tracks")
                    .frame(maxWidth: .infinity)
                    .task(id: nextPageURL) {
                        guard nextPageURL != nil, relatedTracksErrorMessage == nil else { return }
                        await loadRelatedTracks()
                    }
            } else if hasLoadedRelatedTracks, relatedTracks.isEmpty,
                      relatedTracksErrorMessage == nil {
                ContentUnavailableView(
                    "No related tracks",
                    systemImage: "music.note",
                    description: Text("No related tracks are available for playback here.")
                )
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

    @ViewBuilder
    private func artworkView(for track: SoundCloudTrack) -> some View {
        let cornerRadius: CGFloat = 6;
        if track.displayArtworkURL != nil {
            Button {
                isShowingArtwork = true
            } label: {
                artworkThumbnail(for: track, cornerRadius: cornerRadius)
                    .artworkExpandIndicator(isHovering: isHoveringArtwork)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            }
            .buttonStyle(.plain)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .onContentHover { isHoveringArtwork = $0 }
            .help("View full-size artwork")
            .accessibilityLabel(
                "View full-size artwork for \(track.title)"
            )
        } else {
            artworkThumbnail(for: track, cornerRadius: cornerRadius)
        }
    }

    private func artworkThumbnail(for track: SoundCloudTrack, cornerRadius: CGFloat) -> some View {
        TrackArtworkView(
            artworkURL: track.displayArtworkURL,
            loader: model.artworkLoader,
            size: 250,
            rendition: .square500,
            shape: RoundedRectangle(cornerRadius: cornerRadius)
        )
    }

    private func playButton(for track: SoundCloudTrack) -> some View {
        playButtonLabel(for: track)
            .buttonStyle(TrackActionButtonStyle(fill: .primary.opacity(0.12)))
            .modifier(SpringPressEffect())
    }

    private func playButtonLabel(for track: SoundCloudTrack) -> some View {
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
                .labelStyle(.titleAndIcon)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 24)
                .frame(minHeight: 24)
        }
        .help(isPlaying ? "Pause" : "Play")
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }

    private func likeButton(for track: SoundCloudTrack) -> some View {
        likeButtonLabel(for: track)
            .buttonStyle(TrackActionButtonStyle(
                fill: likes.isLiked(track) ? .accentColor.opacity(0.12) : .primary.opacity(0.12)
            ))
            .modifier(SpringPressEffect())
    }

    private func likeButtonLabel(for track: SoundCloudTrack) -> some View {
        let isLiked = likes.isLiked(track)
        let likeCount = likes.likeCount(for: track)?.formatted(.number)

        return Button {
            Task {
                do {
                    try await likes.toggleLike(track)
                } catch {
                    model.likeErrorMessage = error.localizedDescription
                }
            }
        } label: {
            ZStack {
                Label(likeCount ?? "Like", systemImage: "heart")
                    .opacity(isLiked ? 0 : 1)
                    .accessibilityHidden(isLiked)
                Label(likeCount ?? "Unlike", systemImage: "heart.fill")
                    .foregroundStyle(.orange)
                    .opacity(isLiked ? 1 : 0)
                    .accessibilityHidden(!isLiked)
            }
                .labelStyle(.titleAndIcon)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 24)
                .frame(minHeight: 24)
        }
        .disabled(likes.updatingTrackURNs.contains(track.urn))
        .help(isLiked ? "Unlike track" : "Like track")
        .accessibilityLabel(isLiked ? "Unlike track" : "Like track")
        .accessibilityValue(isLiked ? "Liked" : "Not liked")
    }

    private func repostButton(for track: SoundCloudTrack) -> some View {
        let isReposted = reposts.isReposted(track)
        let repostCount = reposts.repostCount(for: track)

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
                if repostCount == 0 {
                    Image(systemName: "arrow.2.squarepath")
                } else {
                    Label(repostCount?.formatted(.number) ?? "Repost", systemImage: "arrow.2.squarepath")
                }
            }
                .foregroundStyle(isReposted ? Color.green : Color.primary)
                .labelStyle(.titleAndIcon)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 24)
                .frame(minHeight: 24)
        }
        .buttonStyle(TrackActionButtonStyle(
            fill: isReposted ? .green.opacity(0.12) : .primary.opacity(0.12)
        ))
        .modifier(SpringPressEffect())
        .disabled(reposts.isLoading || reposts.updatingTrackURNs.contains(track.urn))
        .help(isReposted ? "Undo repost" : "Repost track")
        .accessibilityLabel(isReposted ? "Undo repost" : "Repost track")
        .accessibilityValue(isReposted ? "Reposted" : "Not reposted")
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
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.5)
            .onContentHover { isHovering = $0 }
    }
}

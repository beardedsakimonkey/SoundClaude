import AppKit
import Foundation
import SwiftUI

struct TrackDetailView: View {
    @Environment(\.openURL) private var openURL

    let track: SoundCloudTrack
    @ObservedObject var model: AppModel
    @ObservedObject private var likes: LikesController
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
                Button {
                    openURL(details?.track.permalinkURL ?? track.permalinkURL)
                } label: {
                    Label("Open in SoundCloud", systemImage: "arrow.up.right.square")
                        .labelStyle(.iconOnly)
                        .frame(width: 20, height: 20)
                }
                .help("Open this track in your web browser")
            }
        }
        .task(id: track.urn) {
            await load()
        }
        .task(id: track.urn) {
            if !hasLoadedRelatedTracks { await loadRelatedTracks() }
        }
        .sheet(isPresented: $isShowingArtwork) {
            FullSizeArtworkView(
                title: details?.track.title ?? track.title,
                artworkURL: details?.track.artworkURL ?? track.artworkURL,
                loader: model.artworkLoader,
                cachedArtwork: $cachedFullSizeArtwork
            )
        }
    }

    @ViewBuilder
    private var artworkBackdrop: some View {
        let backdrop = TrackArtworkBackdropView(
            artworkURL: details?.track.artworkURL ?? track.artworkURL,
            loader: model.artworkLoader
        )
        .frame(height: 410)

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
                        Button {
                            Task { await model.play(details.track) }
                        } label: {
                            Text(details.track.title)
                                .font(.system(size: 36, weight: .semibold))
                                .foregroundStyle(.primary)
                                .opacity(0.9)
                        }
                        .buttonStyle(.plain)
                        .help("Play this track")
                        .accessibilityLabel("Play \(details.track.title)")
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            ArtistLink(
                                artist: details.track.artist,
                                artworkLoader: model.artworkLoader,
                                onSelect: onSelectArtist
                            )

                            if let createdAt = creationDate(from: details.createdAt) {
                                Text("·")
                                    .accessibilityHidden(true)
                                Text(createdAt.formatted(.relative(presentation: .numeric, unitsStyle: .wide)))
                                    .help(createdAt.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: 12) {
                                playButton(for: details.track)
                                likeButton(for: details.track)
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
        if track.artworkURL != nil {
            Button {
                isShowingArtwork = true
            } label: {
                artworkThumbnail(for: track)
                    .artworkExpandIndicator(isHovering: isHoveringArtwork)
            }
            .buttonStyle(.plain)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onContentHover { isHoveringArtwork = $0 }
            .help("View full-size artwork")
            .accessibilityLabel(
                "View full-size artwork for \(track.title)"
            )
        } else {
            artworkThumbnail(for: track)
        }
    }

    private func artworkThumbnail(for track: SoundCloudTrack) -> some View {
        TrackArtworkView(
            artworkURL: track.artworkURL,
            loader: model.artworkLoader,
            size: 250,
            rendition: .square500
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

    private func creationDate(from value: String?) -> Date? {
        guard let value else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }

        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss Z"
        return formatter.date(from: value)
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

private struct TrackActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    let fill: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .padding(.vertical, 10)
            .background(fill, in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.5)
    }
}

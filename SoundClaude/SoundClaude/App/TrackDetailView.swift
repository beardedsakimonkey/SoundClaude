import AppKit
import Foundation
import SwiftUI

struct TrackDetailView: View {
    let track: SoundCloudTrack
    @ObservedObject var model: AppModel
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
    @State private var isShowingComments = false
    @State private var isHoveringComments = false
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
        .sheet(isPresented: $isShowingComments) {
            TrackCommentsView(
                track: details?.track ?? track,
                model: model,
                onSelectArtist: onSelectArtist
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
                        }
                        .buttonStyle(.plain)
                        .help("Play this track")
                        .accessibilityLabel("Play \(details.track.title)")
                        ArtistLink(
                            artist: details.track.artist,
                            artworkLoader: model.artworkLoader,
                            onSelect: onSelectArtist
                        )
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Link(destination: details.track.permalinkURL) {
                            Label("Open in SoundCloud", systemImage: "arrow.up.right.square")
                        }
                        .help("Open this track in your web browser")

                        HStack(alignment: .top, spacing: 16) {
                            playButton(for: details.track)
                                .frame(height: TrackWaveformView.Layout.detail.height)

                                if details.track.waveformURL != nil {
                                    TrackWaveformView(track: details.track, model: model)
                                }
                        }
                    }
                }

                HStack(spacing: 24) {
                    statistic(details.playbackCount, label: "plays")
                    statistic(details.favoritingsCount, label: "likes")
                    Button {
                        isShowingComments = true
                    } label: {
                        Text(details.commentCount.map {
                            "\($0.formatted()) \($0 == 1 ? "comment" : "comments")"
                        } ?? "Comments")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .underline(isHoveringComments)
                    }
                    .buttonStyle(.plain)
                    .onContentHover { isHoveringComments = $0 }
                    .help("Read track comments")
                    .accessibilityLabel("Read comments on \(details.track.title)")
                }

                if let description = nonempty(details.description) {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Description")
                            .font(.headline)
                        ExpandableDescriptionText(
                            description: description,
                            onSelectArtist: onSelectArtist
                        )
                        .id(track.urn)
                    }
                }

                Divider()
                Text("Related tracks").font(.headline)
                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                relatedTrackList
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

    @ViewBuilder
    private func statistic(_ count: Int?, label: String) -> some View {
        if let count {
            Text("\(count.formatted()) \(label)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func playButton(for track: SoundCloudTrack) -> some View {
        Group {
            if #available(macOS 26.0, *) {
                playButtonLabel(for: track)
                    .buttonStyle(SpringGlassButtonStyle())
            } else {
                playButtonLabel(for: track)
                    .buttonStyle(.bordered)
            }
        }
        .buttonBorderShape(.circle)
        .controlSize(.large)
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
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 28, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .help(isPlaying ? "Pause" : "Play")
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
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

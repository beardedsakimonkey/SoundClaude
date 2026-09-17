import SwiftUI

struct StationDetailView: View {
    let urn: String
    @ObservedObject var model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void

    @AppStorage("playlistTrackLayout") private var trackLayout = TrackLayout.list
    @State private var station: SoundCloudStation?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var loadAttempt = 0
    @State private var isShowingArtwork = false
    @State private var cachedFullSizeArtwork: CachedFullSizeArtwork?

    private var tracks: [SoundCloudTrack] { station?.tracks ?? [] }
    private var title: String { station?.title ?? "Station" }
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
    private var artworkURL: URL? {
        currentStationTrack?.displayArtworkURL
            ?? tracks.first(where: { $0.displayArtworkURL != nil })?.displayArtworkURL
    }
    private var artworkTitle: String { currentStationTrack?.title ?? title }

    var body: some View {
        ZStack(alignment: .top) {
            TrackCollectionBackdrop(artworkURL: artworkURL, loader: model.artworkLoader)
                .ignoresSafeArea(edges: .top)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    HStack {
                        CountedSectionHeader(title: "Tracks", count: station?.trackCount ?? tracks.count)
                        Spacer()
                        TrackLayoutPicker(trackLayout: $trackLayout)
                    }
                    if let message = model.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    LazyVStack(alignment: .leading, spacing: 0) {
                        TrackCollectionTracks(
                            tracks: tracks, trackLayout: trackLayout, model: model,
                            onSelectTrack: onSelectTrack, onSelectArtist: onSelectArtist,
                            onPlayTrack: playTrack
                        )
                        if let errorMessage {
                            Text(errorMessage).foregroundStyle(.secondary)
                            Button("Try Again") { loadAttempt += 1 }
                                .disabled(isLoading)
                        }
                        if isLoading {
                            ProgressView("Loading station").frame(maxWidth: .infinity)
                        } else if station != nil, tracks.isEmpty, errorMessage == nil {
                            ContentUnavailableView(
                                "No playable tracks",
                                systemImage: "dot.radiowaves.left.and.right",
                                description: Text("This station has no tracks available for playback here.")
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
        }
        .navigationTitle(title)
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible, placement: .primaryAction)
            } else {
                ToolbarItem(placement: .primaryAction) { Spacer() }
            }
            if let url = station?.permalinkURL {
                ToolbarItem(placement: .primaryAction) {
                    OpenInSoundCloudButton(url: url)
                        .help("Open this station in your web browser")
                }
            }
        }
        .task(id: loadAttempt) { await load() }
        .sheet(isPresented: $isShowingArtwork) {
            FullSizeArtworkView(
                title: artworkTitle, artworkURL: artworkURL,
                loader: model.artworkLoader, cachedArtwork: $cachedFullSizeArtwork
            )
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            DetailArtworkView(
                artworkURL: artworkURL, title: artworkTitle,
                loader: model.artworkLoader, size: 250, animatesChanges: true,
                onShowArtwork: { isShowingArtwork = true }
            )
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .accessibilityLabel("Station")
                    Text(title).textSelection(.enabled)
                }
                .font(.system(size: 28, weight: .semibold))
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(stationType)
                    RelativeTimestampView(
                        timestamp: station?.lastUpdated,
                        accessibilityPrefix: "Last updated", prefix: "Updated"
                    )
                }
                .font(.title3)
                .foregroundStyle(.secondary)
                playbackControls.padding(.top, 8)
                if let track = currentStationTrack {
                    Spacer(minLength: 6)
                    TrackWaveformView(
                        track: track, model: model,
                        invertsBarsOnTrackChange: true, collapsesBarsWhenPaused: true
                    )
                    .offset(y: -2)
                }
            }
            .frame(
                maxWidth: .infinity,
                minHeight: currentStationTrack != nil
                    ? 250 + TrackWaveformView.Layout.detail.reflectionHeight : nil,
                alignment: .topLeading
            )
        }
    }

    private var playbackControls: some View {
        let isPlaying = currentStationTrack != nil && model.playback.isPlaybackActive
        return HStack(spacing: 12) {
            Button {
                if currentStationTrack != nil {
                    model.playback.togglePlayPause()
                } else if let track = tracks.first {
                    Task { await playTrack(track) }
                }
            } label: {
                ZStack {
                    Label("Play", systemImage: "play.fill")
                        .opacity(isPlaying ? 0 : 1).accessibilityHidden(isPlaying)
                    Label("Pause", systemImage: "pause.fill")
                        .opacity(isPlaying ? 1 : 0).accessibilityHidden(!isPlaying)
                }
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 24)
                .frame(minHeight: 24)
            }
            .disabled(currentStationTrack == nil && tracks.isEmpty)
            .help(isPlaying ? "Pause station" : "Play station")
            .accessibilityLabel(isPlaying ? "Pause station" : "Play station")
            Group {
                Button(action: model.playback.previous) {
                    Label("Previous track", systemImage: "backward.fill")
                        .frame(width: 44, height: 24)
                }
                .help("Previous track")
                Button(action: model.playback.next) {
                    Label("Next track", systemImage: "forward.fill")
                        .frame(width: 44, height: 24)
                }
                .help("Next track")
            }
            .labelStyle(.iconOnly)
            .disabled(currentStationTrack == nil)
        }
        .font(.title3.weight(.semibold))
        .buttonStyle(TrackActionButtonStyle(fill: .primary.opacity(0.12)))
    }

    private func playTrack(_ track: SoundCloudTrack) async {
        await model.play(track, queue: TrackQueue(source: .station(urn), tracks: tracks))
    }

    private func load() async {
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

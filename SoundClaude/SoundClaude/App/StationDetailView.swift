import SwiftUI

struct StationDetailView: View {
    let urn: String
    let seedTrack: SoundCloudTrack?
    let seedArtistName: String?
    @ObservedObject var model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void

    @AppStorage("playlistTrackLayout") private var trackLayout = TrackLayout.list
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false
    @State private var station: SoundCloudStation?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var loadAttempt = 0
    @State private var isShowingArtwork = false
    @State private var isHoveringStationTitle = false
    @State private var isOpeningSource = false
    @State private var sourceErrorMessage: String?
    @State private var cachedFullSizeArtwork: CachedFullSizeArtwork?

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
    private var artworkURL: URL? {
        currentStationTrack?.displayArtworkURL
            ?? seedTrack?.displayArtworkURL
            ?? tracks.first(where: { $0.displayArtworkURL != nil })?.displayArtworkURL
    }
    private var artworkTitle: String { currentStationTrack?.title ?? title }

    private var initialExpandedWaveform: SoundCloudWaveform? {
        guard currentStationTrack == nil,
              let seedTrack,
              model.playback.currentTrack?.urn == seedTrack.urn,
              model.playback.isPlaybackActive else { return nil }
        return model.cachedWaveform(for: seedTrack)
    }

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
                            ProgressView()
                                .accessibilityLabel("Loading station")
                                .frame(maxWidth: .infinity)
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
            ToolbarItem(placement: .primaryAction) {
                OpenInSoundCloudButton(url: station?.permalinkURL)
                    .help("Open this station in your web browser")
            }
        }
        .task(id: loadAttempt) { await load() }
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
            DetailArtworkView(
                artworkURL: artworkURL, title: artworkTitle,
                loader: model.artworkLoader, size: 250, animatesChanges: true,
                cornerRadius: 12,
                onShowArtwork: { isShowingArtwork = true }
            )
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        if seedTrack == nil || reduceMotion || hasAppeared {
                            Label(stationType, systemImage: "dot.radiowaves.left.and.right")
                                .labelStyle(.titleAndIcon)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .transition(.opacity)
                        }
                        stationTitle
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: hasAppeared)
                .onAppear { hasAppeared = true }
                .modifier(FadeInOnAppear(isEnabled: seedTrack == nil))
                playbackControls
                    .padding(.top, 8)
                    .modifier(FadeInOnAppear())
                NowPlayingTrackRow(
                    track: currentStationTrack,
                    isPlaying: model.playback.isPlaying,
                    isLoading: model.playback.isLoading,
                    analyzer: model.analyzer,
                    onSelectTrack: onSelectTrack,
                    onSelectArtist: onSelectArtist,
                    appearanceDelay: .milliseconds(350)
                )
                .offset(y: 8)
                Spacer(minLength: 6)
                TrackWaveformView(
                    track: currentStationTrack, model: model,
                    invertsBarsOnTrackChange: true, collapsesBarsWhenPaused: true,
                    keepsBarsVisible: true,
                    initialExpandedWaveform: initialExpandedWaveform
                )
                .offset(y: -2)
            }
            .frame(
                maxWidth: .infinity,
                minHeight: 250 + TrackWaveformView.Layout.detail.reflectionHeight,
                alignment: .topLeading
            )
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
            Text(title)
                .font(.system(size: 36, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(.primary)
                .opacity(0.9)
                .underline(isHoveringStationTitle)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onContentHover { isHoveringStationTitle = $0 }
        .disabled(isOpeningSource)
        .help(stationType == "Artist station" ? "View station artist" : "View station track")
        .accessibilityLabel("\(stationType == "Artist station" ? "View artist" : "View track"): \(title)")
    }

    private var playbackControls: some View {
        let isPlaying = currentStationTrack != nil && model.playback.isPlaybackActive
        return HStack(spacing: 12) {
            Button {
                if currentStationTrack != nil {
                    model.playback.togglePlayPause()
                } else if let seedTrackURN, model.playback.currentTrack?.urn == seedTrackURN {
                    model.continuePlaybackInStation(
                        urn: urn, title: title, tracks: tracks, continuingTrackURN: seedTrackURN
                    )
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
        await model.play(track, queue: TrackQueue(source: .station(urn), tracks: tracks, stationTitle: title))
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

import SwiftUI

struct PlaylistDetailView: View {
    private let artworkSize: CGFloat = 250

    let playlist: SoundCloudPlaylist
    @ObservedObject var model: AppModel
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    let onDeletePlaylist: (SoundCloudPlaylist) -> Void

    @ObservedObject var playlists: PlaylistsController

    private var contents: PlaylistContents? { playlists.cache.contents[playlist.urn] }
    private var tracks: [SoundCloudTrack] { contents?.tracks ?? [] }
    private var nextPageURL: URL? { contents?.nextPageURL }
    private var hasLoadedTracks: Bool { contents?.hasLoadedPage == true }
    private var isLoading: Bool { playlists.loadingPlaylistURNs.contains(playlist.urn) }
    private var errorMessage: String? { playlists.playlistErrors[playlist.urn] }
    @AppStorage("playlistTrackLayout") private var trackLayout = TrackLayout.list
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingArtwork = false
    @State private var cachedFullSizeArtwork: CachedFullSizeArtwork?
    @State private var likeErrorMessage: String?
    @State private var editingPlaylist: SoundCloudPlaylist?
    @State private var playlistDeletion = PlaylistDeletionState()
    @State private var removeTrackErrorMessage: String?

    #if DEBUG
    @State private var glassParameters = PlayerArtworkGlassParameters()
    @State private var isShowingGlassControls = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    #endif

    private var isOwnedByCurrentUser: Bool {
        guard case let .signedIn(user) = model.auth.state,
              let urn = user.urn else { return false }
        return displayedPlaylist.owner.urn == urn
    }

    private var displayedPlaylist: SoundCloudPlaylist { contents?.playlist ?? playlist }
    private var currentPlaylistTrack: SoundCloudTrack? {
        guard let track = model.playback.currentTrack,
              model.queue.source == .playlist(playlist.urn)
                || tracks.contains(where: { $0.urn == track.urn }) else { return nil }
        return track
    }

    private var artworkURL: URL? {
        if let track = currentPlaylistTrack {
            return track.displayArtworkURL
        }
        return displayedPlaylist.artworkURL ?? tracks.first(where: { $0.displayArtworkURL != nil })?.displayArtworkURL
    }

    private var artworkTitle: String { currentPlaylistTrack?.title ?? displayedPlaylist.title }

    private var artworkTrack: SoundCloudTrack? {
        if let currentPlaylistTrack { return currentPlaylistTrack }
        guard displayedPlaylist.artworkURL == nil else { return nil }
        return tracks.first(where: { $0.displayArtworkURL != nil })
    }

    var body: some View {
        ZStack(alignment: .top) {
            artworkBackdrop
                .ignoresSafeArea(edges: .top)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    #if DEBUG
                    if isShowingGlassControls {
                        glassControls
                    }
                    #endif
                    if let description = displayedPlaylist.description?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
                        ExpandableDescriptionText(
                            description: description,
                            onSelectArtist: onSelectArtist
                        )
                    }
                    HStack {
                        CountedSectionHeader(
                            title: "Tracks",
                            count: displayedPlaylist.trackCount ?? tracks.count
                        )
                        Spacer()
                        TrackLayoutPicker(trackLayout: $trackLayout)
                    }
                    if let message = model.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color.accentColor)
                    }
                    trackList
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
        }
        .navigationTitle(displayedPlaylist.title)
        .toolbar {
            #if DEBUG
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingGlassControls.toggle()
                } label: {
                    Label("Artwork glass", systemImage: "slider.horizontal.3")
                }
                .help("Adjust artwork glass shader (development only)")
            }
            #endif
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible, placement: .primaryAction)
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Spacer()
                }
            }
            if isOwnedByCurrentUser {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            editingPlaylist = displayedPlaylist
                        } label: {
                            Label("Edit playlist", systemImage: "pencil")
                        }
                        .disabled(playlists.updatingPlaylistURNs.contains(playlist.urn)
                            || playlistDeletion.deletingURNs.contains(playlist.urn))
                        DeletePlaylistButton(playlist: displayedPlaylist, state: $playlistDeletion)
                    } label: {
                        Label("Playlist actions", systemImage: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                    .disabled(playlistDeletion.deletingURNs.contains(playlist.urn))
                    .help("Playlist actions")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                OpenInSoundCloudButton(url: displayedPlaylist.permalinkURL)
                    .help("Open this playlist in your web browser")
            }
        }
        .task(id: playlist.urn) {
            await load()
        }
        .task(id: displayedPlaylist.isPrivate) {
            if !displayedPlaylist.isPrivate { await playlists.loadLikes() }
        }
        .alert("Could not update playlist like", isPresented: Binding(
            get: { likeErrorMessage != nil },
            set: { if !$0 { likeErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { likeErrorMessage = nil }
        } message: {
            Text(likeErrorMessage ?? "Please try again.")
        }
        .sheet(item: $editingPlaylist) { playlist in
            PlaylistEditorView(playlists: playlists, playlist: playlist)
        }
        .modifier(PlaylistDeletionModifier(
            state: $playlistDeletion, playlists: playlists, onDeleted: onDeletePlaylist
        ))
        .alert("Could not remove track", isPresented: Binding(
            get: { removeTrackErrorMessage != nil },
            set: { if !$0 { removeTrackErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { removeTrackErrorMessage = nil }
        } message: {
            Text(removeTrackErrorMessage ?? "Please try again.")
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

    private var artworkBackdrop: some View {
        TrackCollectionBackdrop(artworkURL: artworkURL, loader: model.artworkLoader)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            playlistArtwork
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "music.note.list")
                            .foregroundStyle(.primary.opacity(0.6))
                            .accessibilityHidden(true)
                        Text(displayedPlaylist.title)
                            .foregroundStyle(.primary)
                            .opacity(currentPlaylistTrack != nil ? 0.6 : 0.9)
                            .animation(.easeInOut(duration: 0.2), value: currentPlaylistTrack != nil)
                            .textSelection(.enabled)
                            .accessibilityLabel("Playlist, \(displayedPlaylist.title)")
                    }
                    .font(.system(size: 24, weight: .semibold))

                    if displayedPlaylist.isPrivate {
                        Text("Private")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .overlay {
                                Capsule()
                                    .strokeBorder(.secondary.opacity(0.35), lineWidth: 1)
                            }
                            .fixedSize()
                            .help("Private playlist")
                            .accessibilityLabel("Private playlist")
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ArtistLink(
                        artist: displayedPlaylist.owner,
                        artworkLoader: model.artworkLoader,
                        showsAvatarBorder: true,
                        onSelect: onSelectArtist
                    )

                    RelativeTimestampView(
                        timestamp: displayedPlaylist.lastModified,
                        accessibilityPrefix: "Last updated",
                        prefix: "Updated"
                    )

                }
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                VStack(alignment: .leading, spacing: 16) {
                    ViewThatFits(in: .horizontal) {
                        playbackControls(iconOnly: false)
                            .labelStyle(.titleAndIcon)
                            .fixedSize(horizontal: true, vertical: false)
                        playbackControls(iconOnly: true)
                            .labelStyle(.iconOnly)
                    }
                    if !displayedPlaylist.isPrivate, let error = playlists.likesErrorMessage {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                        Button("Retry likes") { Task { await playlists.loadLikes() } }
                    }
                }
                .padding(.top, 8)

                NowPlayingTrackRow(
                    track: currentPlaylistTrack,
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
                    track: currentPlaylistTrack,
                    model: model,
                    invertsBarsOnTrackChange: true,
                    collapsesBarsWhenPaused: true,
                    keepsBarsVisible: true
                )
                .offset(y: -2)
            }
            // Match the track detail header's waveform ground and reflection.
            .frame(
                maxWidth: .infinity,
                minHeight: artworkSize + TrackWaveformView.Layout.detail.reflectionHeight,
                alignment: .topLeading
            )
        }
    }

    private var playlistArtwork: some View {
        ZStack {
            DetailArtworkView(
                artworkURL: artworkURL,
                title: artworkTitle,
                loader: model.artworkLoader,
                size: artworkSize,
                animatesChanges: true,
                cornerRadius: 12,
                scalesOnHover: false,
                track: artworkTrack,
                likes: model.likes,
                onAddToQueue: model.addToQueue,
                onRemoveFromPlaylist: isOwnedByCurrentUser ? removeTrack : nil,
                isUpdatingPlaylist: playlists.updatingPlaylistURNs.contains(playlist.urn),
                onShowArtwork: { isShowingArtwork = true }
            )
            #if DEBUG
            .environment(\.playerArtworkGlassParameters, glassParameters)
            #endif
            .id(artworkTrack?.urn)
            .transition(DetailArtworkTransition(playback: model.playback, reduceMotion: reduceMotion))
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.2 : 0.45), value: artworkTrack?.urn)
        .modifier(DetailArtworkRotation(isShowingArtwork: isShowingArtwork))
    }

    #if DEBUG
    private var glassControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Artwork glass").font(.headline)
                Toggle("Enable shader", isOn: $glassParameters.isEnabled)
                Spacer()
                Button("Reset") { glassParameters = PlayerArtworkGlassParameters() }
                Button("Hide") { isShowingGlassControls = false }
            }
            if reduceTransparency {
                Text("Reduce Transparency is on. Turn it off in System Settings to preview the shader.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 24)], spacing: 12) {
                glassSlider("Rim width (pt)", value: $glassParameters.rimWidth, range: 0.5...30, step: 0.1)
                glassSlider("Refraction (pt)", value: $glassParameters.refraction, range: 0...20, step: 0.1)
                glassSlider("Color dispersion (pt)", value: $glassParameters.dispersion, range: 0...5, step: 0.05)
                glassSlider("Light angle (°)", value: $glassParameters.lightAngle, range: -180...180, step: 1)
                glassSlider("Edge darkening", value: $glassParameters.edgeDarkening, range: 0...1, step: 0.01)
                glassSlider("Lip position (pt)", value: $glassParameters.lipPosition, range: 0...10, step: 0.1)
                glassSlider("Lip width (pt)", value: $glassParameters.lipWidth, range: 0.1...5, step: 0.05)
                glassSlider("Edge reflection", value: $glassParameters.reflectionStrength, range: 0...3, step: 0.05)
                glassSlider("Caustic strength", value: $glassParameters.causticStrength, range: 0...1, step: 0.01)
                glassSlider("Face reflection", value: $glassParameters.sweepStrength, range: 0...1, step: 0.005)
                glassSlider("Face reflection width", value: $glassParameters.sweepWidth, range: 0.01...1, step: 0.01)
                glassSlider("Face reflection position", value: $glassParameters.sweepPosition, range: -0.5...1.5, step: 0.01)
            }
            .disabled(!glassParameters.isEnabled || reduceTransparency)
        }
        .padding(20)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private func glassSlider(
        _ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue, format: .number.precision(.fractionLength(0...3)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step) {
                Text(title)
            }
        }
    }
    #endif

    private func playbackControls(iconOnly: Bool) -> some View {
        HStack(spacing: 12) {
            playButton(iconOnly: iconOnly)
            trackNavigationButtons
            if !displayedPlaylist.isPrivate { likeButton }
        }
    }

    private func playButton(iconOnly: Bool) -> some View {
        let isPlaying = currentPlaylistTrack != nil && model.playback.isPlaybackActive
        return Button {
            if currentPlaylistTrack != nil {
                model.playback.togglePlayPause()
            } else if let track = model.playback.isShuffleEnabled ? tracks.randomElement() : tracks.first {
                Task {
                    await model.play(track, queue: TrackQueue(
                        source: .playlist(playlist.urn), tracks: tracks, nextPageURL: nextPageURL
                    ))
                }
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
        .buttonStyle(TrackActionButtonStyle(fill: .primary.opacity(0.12)))
        .disabled(currentPlaylistTrack == nil && tracks.isEmpty)
        .help(isPlaying ? "Pause playlist" : "Play playlist")
        .accessibilityLabel(isPlaying ? "Pause playlist" : "Play playlist")
    }

    private var trackNavigationButtons: some View {
        Group {
            Button(action: model.playback.previous) {
                Label("Previous track", systemImage: "backward.fill")
                    .frame(width: 44, height: 24)
            }
            .help("Previous track")
            .accessibilityLabel("Previous track")

            Button(action: model.playback.next) {
                Label("Next track", systemImage: "forward.fill")
                    .frame(width: 44, height: 24)
            }
            .help("Next track")
            .accessibilityLabel("Next track")
        }
        .labelStyle(.iconOnly)
        .font(.title3.weight(.semibold))
        .buttonStyle(TrackActionButtonStyle(fill: .primary.opacity(0.12)))
        .disabled(currentPlaylistTrack == nil)
    }

    private var likeButton: some View {
        DetailLikeButton(
            isLiked: playlists.likedPlaylistURNs.contains(playlist.urn),
            subject: "playlist"
        ) {
            Task {
                do {
                    try await playlists.toggleLike(displayedPlaylist)
                } catch {
                    likeErrorMessage = error.localizedDescription
                }
            }
        }
        .disabled(!playlists.hasLoadedLikes || playlists.updatingLikeURNs.contains(playlist.urn))
    }

    private var trackList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            TrackCollectionTracks(
                tracks: tracks, trackLayout: trackLayout, model: model,
                onSelectTrack: onSelectTrack, onSelectArtist: onSelectArtist,
                onPlayTrack: playTrack,
                onRemoveFromPlaylist: isOwnedByCurrentUser ? removeTrack : nil,
                isUpdatingPlaylist: playlists.updatingPlaylistURNs.contains(playlist.urn)
            )
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.secondary)
                Button("Try Again") { Task { await load() } }
                    .disabled(isLoading)
            }
            if isLoading {
                ProgressView()
                    .accessibilityLabel("Loading playlist")
                    .frame(maxWidth: .infinity)
            } else if hasLoadedTracks, tracks.isEmpty, errorMessage == nil {
                EmptyStateView(displayedPlaylist.trackCount == 0 ? "Empty playlist" : "No playable tracks")
            }
        }
    }

    private func removeTrack(_ track: SoundCloudTrack) {
        Task {
            do {
                try await playlists.removeTrack(track, from: displayedPlaylist)
            } catch is CancellationError {
            } catch {
                removeTrackErrorMessage = error.localizedDescription
            }
        }
    }

    private func playTrack(_ track: SoundCloudTrack) async {
        await model.play(track, queue: TrackQueue(
            source: .playlist(playlist.urn),
            tracks: tracks,
            nextPageURL: nextPageURL
        ))
    }

    private func load() async {
        await playlists.loadPlaylist(playlist)
    }
}

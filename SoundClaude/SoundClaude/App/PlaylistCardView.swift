import SwiftUI

struct PlaylistCardView: View {
    let playlist: SoundCloudPlaylist
    let model: AppModel
    @ObservedObject var playlists: PlaylistsController
    let onSelectPlaylist: (SoundCloudPlaylist) -> Void
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void

    @State private var hasRequestedTracks = false
    @State private var isExpanded = false
    @State private var isHoveringTitle = false
    @State private var selectedTrackURN: String?

    private var contents: PlaylistContents? { playlists.cache.contents[playlist.urn] }
    private var displayedPlaylist: SoundCloudPlaylist { contents?.playlist ?? playlist }
    private var tracks: [SoundCloudTrack] { contents?.tracks ?? [] }
    private var isLoading: Bool { playlists.loadingPlaylistURNs.contains(playlist.urn) }
    private var errorMessage: String? { playlists.playlistErrors[playlist.urn] }
    private var artworkURL: URL? {
        displayedPlaylist.artworkURL ?? tracks.first(where: { $0.artworkURL != nil })?.artworkURL
    }
    private var waveformTrack: SoundCloudTrack? {
        tracks.first(where: { $0.urn == model.playback.currentTrack?.urn })
            ?? tracks.first(where: { $0.urn == selectedTrackURN })
            ?? tracks.first
    }
    private var trackCount: Int { max(displayedPlaylist.trackCount ?? 0, tracks.count) }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            Button {
                onSelectPlaylist(displayedPlaylist)
            } label: {
                TrackArtworkView(
                    artworkURL: artworkURL,
                    loader: model.artworkLoader,
                    size: 140,
                    rendition: .square500
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open playlist: \(displayedPlaylist.title)")

            VStack(alignment: .leading, spacing: 6) {
                Button {
                    onSelectPlaylist(displayedPlaylist)
                } label: {
                    Text(displayedPlaylist.title)
                        .font(.title2.weight(.semibold))
                        .underline(isHoveringTitle)
                        .multilineTextAlignment(.leading)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .onHover { isHoveringTitle = $0 }
                .help(displayedPlaylist.title)

                ArtistLink(artist: displayedPlaylist.owner, onSelect: onSelectArtist)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let track = waveformTrack {
                    HStack(spacing: 10) {
                        playButton(for: track)
                        TrackWaveformView(
                            track: track,
                            model: model,
                            layout: .compact,
                            onPlayTrack: play
                        )
                        .id(track.urn)
                        .frame(maxWidth: .infinity)
                    }
                }

                trackList
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .task(id: playlist.urn) {
            guard !hasRequestedTracks else { return }
            hasRequestedTracks = true
            await playlists.loadPlaylist(playlist)
        }
    }

    @ViewBuilder
    private var trackList: some View {
        if isExpanded {
            ScrollView {
                LazyVStack(spacing: 0) {
                    trackRows(limit: tracks.count)
                }
            }
            .frame(height: CGFloat(min(tracks.count, 8)) * 56)
        } else {
            VStack(spacing: 0) {
                trackRows(limit: 5)
            }
        }

        if isExpanded || trackCount > 5 {
            Button(isExpanded ? "View fewer tracks" : "View \(trackCount) tracks") {
                isExpanded.toggle()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.callout)
            .padding(.vertical, 8)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        }

        if let errorMessage {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Try Again") { Task { await playlists.loadPlaylist(playlist) } }
                .disabled(isLoading)
        }
        if isLoading {
            ProgressView("Loading playlist")
                .controlSize(.small)
        } else if contents?.hasLoadedPage == true, tracks.isEmpty, errorMessage == nil {
            Text(displayedPlaylist.trackCount == 0 ? "Empty playlist" : "No playable tracks")
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        }
    }

    private func trackRows(limit: Int) -> some View {
        ForEach(Array(tracks.prefix(limit).enumerated()), id: \.element.urn) { index, track in
            PlaylistTrackRow(
                track: track,
                number: index + 1,
                playback: model.playback,
                artworkLoader: model.artworkLoader,
                onSelectTrack: onSelectTrack,
                onPlayTrack: play
            )
        }
    }

    private func playButton(for track: SoundCloudTrack) -> some View {
        let isCurrentTrack = model.playback.currentTrack?.urn == track.urn
        let isPlaying = isCurrentTrack && model.playback.isPlaybackActive

        return Button {
            if isCurrentTrack {
                model.playback.togglePlayPause()
            } else {
                Task { await play(track) }
            }
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .help(isPlaying ? "Pause" : "Play")
        .accessibilityLabel("\(isPlaying ? "Pause" : "Play") \(track.title)")
    }

    private func play(_ track: SoundCloudTrack) async {
        selectedTrackURN = track.urn
        await model.play(track, queue: TrackQueue(
            source: .playlist(playlist.urn),
            tracks: tracks,
            nextPageURL: contents?.nextPageURL
        ))
    }
}

private struct PlaylistTrackRow: View {
    let track: SoundCloudTrack
    let number: Int
    let playback: PlaybackController
    let artworkLoader: ArtworkLoader
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onPlayTrack: (SoundCloudTrack) async -> Void

    @State private var isHovering = false
    @State private var isHoveringTitle = false
    @GestureState private var isPressed = false

    var body: some View {
        let isCurrentTrack = playback.currentTrack?.urn == track.urn

        HStack(spacing: 12) {
            TrackArtworkView(artworkURL: track.artworkURL, loader: artworkLoader, size: 44)
            Text(number.formatted())
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 20, alignment: .trailing)
            if isCurrentTrack {
                TrackPlaybackIndicator(isPlaying: playback.isPlaying)
            }
            Button {
                onSelectTrack(track)
            } label: {
                Text(track.title)
                    .foregroundStyle(isCurrentTrack ? Color.orange : Color.primary)
                    .underline(isHoveringTitle)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .onHover { isHoveringTitle = $0 }
            .help("Open track: \(track.title)")
            .accessibilityLabel("Open track: \(track.title)")
            if track.access == .preview {
                TrackPreviewBadge()
            }
            Spacer(minLength: 0)
            Text(duration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isHoveringTitle else { return }
            Task { await onPlayTrack(track) }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .updating($isPressed) { _, pressed, _ in
                    pressed = true
                }
        )
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(isPressed
                    ? Color.primary.opacity(0.12)
                    : Color.primary.opacity(isHovering ? 0.06 : 0))
                .animation(.easeInOut(duration: 0.15), value: isHovering)
        }
        .onHover { isHovering = $0 }
        .accessibilityAction(named: "Play") {
            Task { await onPlayTrack(track) }
        }
    }

    private var duration: String {
        let seconds = max(track.durationMilliseconds, 0) / 1_000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

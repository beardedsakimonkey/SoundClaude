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
    @State private var isHoveringTrackToggle = false
    @State private var selectedTrackURN: String?

    private var contents: PlaylistContents? { playlists.cache.contents[playlist.urn] }
    private var displayedPlaylist: SoundCloudPlaylist { contents?.playlist ?? playlist }
    private var tracks: [SoundCloudTrack] { contents?.tracks ?? [] }
    private var isLoading: Bool { playlists.loadingPlaylistURNs.contains(playlist.urn) }
    private var errorMessage: String? { playlists.playlistErrors[playlist.urn] }
    private var artworkURL: URL? {
        displayedPlaylist.artworkURL ?? tracks.first(where: { $0.displayArtworkURL != nil })?.displayArtworkURL
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
                .onContentHover { isHoveringTitle = $0 }
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
        // Keep the row hierarchy stable so toggling preserves loaded artwork.
        ScrollView {
            LazyVStack(spacing: 0) {
                trackRows(limit: isExpanded ? tracks.count : 5)
            }
        }
        .frame(height: CGFloat(min(tracks.count, isExpanded ? 8 : 5)) * 40)
        .scrollDisabled(!isExpanded)

        if isExpanded || trackCount > 5 {
            Button(isExpanded ? "View fewer tracks" : "View \(trackCount) tracks") {
                isExpanded.toggle()
            }
            .buttonStyle(.plain)
            .foregroundStyle(isHoveringTrackToggle ? Color.primary : Color.secondary)
            .font(.callout)
            .padding(.vertical, 8)
            .onContentHover { isHoveringTrackToggle = $0 }
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
            TrackListRow(
                track: track,
                playback: model.playback,
                analyzer: model.analyzer,
                artworkLoader: model.artworkLoader,
                likes: model.likes,
                showsArtist: false,
                isCompact: true,
                trackNumber: index + 1,
                onAddToQueue: model.addToQueue,
                onSelectTrack: onSelectTrack,
                onSelectArtist: onSelectArtist,
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
                let startingTrack = model.playback.isShuffleEnabled ? (tracks.randomElement() ?? track) : track
                Task { await play(startingTrack) }
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

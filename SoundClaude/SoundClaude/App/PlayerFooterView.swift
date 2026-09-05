import SwiftUI

struct PlayerFooterView: View {
    let artworkLoader: ArtworkLoader
    let onSelectTrack: (SoundCloudTrack) -> Void

    @State private var artworkTrack: SoundCloudTrack?
    @State private var cachedFullSizeArtwork: CachedFullSizeArtwork?
    @State private var isHoveringTitle = false

    @Bindable private var playback: PlaybackController

    init(
        playback: PlaybackController,
        artworkLoader: ArtworkLoader,
        onSelectTrack: @escaping (SoundCloudTrack) -> Void
    ) {
        self.artworkLoader = artworkLoader
        self.onSelectTrack = onSelectTrack
        self.playback = playback
    }

    var body: some View {
        HStack(spacing: 20) {
            trackIdentity
                .frame(minWidth: 200, idealWidth: 260, maxWidth: 280)
            playbackControls
                .frame(maxWidth: .infinity)
                .layoutPriority(1)
        }
        .padding(14)
        .sheet(item: $artworkTrack) { track in
            FullSizeArtworkView(
                title: track.title,
                artworkURL: track.artworkURL,
                loader: artworkLoader,
                cachedArtwork: $cachedFullSizeArtwork
            )
        }
    }

    private var trackIdentity: some View {
        HStack(spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                if let track = playback.currentTrack {
                    Button {
                        onSelectTrack(track)
                    } label: {
                        Text(track.title)
                            .underline(isHoveringTitle)
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .onHover { isHoveringTitle = $0 }
                    .help(track.title)
                } else {
                    Text("Select a track")
                }
                Text(playback.currentTrack?.uploader
                    ?? "Choose a track to start listening")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.headline)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let track = playback.currentTrack, track.artworkURL != nil {
            Button {
                artworkTrack = track
            } label: {
                artworkThumbnail
            }
            .buttonStyle(.plain)
            .help("View full-size artwork")
            .accessibilityLabel("View full-size artwork for \(track.title)")
        } else {
            artworkThumbnail
        }
    }

    private var artworkThumbnail: some View {
        TrackArtworkView(
            artworkURL: playback.currentTrack?.artworkURL,
            loader: artworkLoader,
            size: 80,
            rendition: .square500
        )
    }

    private var playbackControls: some View {
        VStack(spacing: 10) {
            Slider(
                value: Binding(
                    get: { playback.currentTime },
                    set: { playback.seek(to: $0) }
                ),
                in: 0...max(playback.duration, 1)
            )

            HStack(spacing: 16) {
                Text(format(seconds: playback.currentTime))
                    .font(.caption.monospacedDigit())
                    .frame(width: 48, alignment: .leading)
                Spacer()
                Button(action: playback.previous) {
                    Image(systemName: "backward.end.fill")
                }
                Button(action: playback.togglePlayPause) {
                    Image(systemName: playback.isPlaying
                        ? "pause.circle.fill"
                        : "play.circle.fill")
                        .font(.title)
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(playback.currentTrack == nil || playback.isLoading)
                Button(action: playback.next) {
                    Image(systemName: "forward.end.fill")
                }
                Spacer()
                Button(action: playback.toggleMute) {
                    Image(systemName: playback.isMuted
                        ? "speaker.slash.fill"
                        : "speaker.wave.2.fill")
                }
                Slider(value: $playback.volume, in: 0...1)
                    .frame(width: 110)
                Text(format(seconds: playback.duration))
                    .font(.caption.monospacedDigit())
                    .frame(width: 48, alignment: .trailing)
            }
            .buttonStyle(.borderless)

            if let playbackError = playback.errorMessage {
                Text(playbackError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func format(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

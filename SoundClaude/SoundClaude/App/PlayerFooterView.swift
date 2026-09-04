import SwiftUI

struct PlayerFooterView: View {
    let artworkLoader: ArtworkLoader

    @Bindable private var playback: PlaybackController

    init(playback: PlaybackController, artworkLoader: ArtworkLoader) {
        self.artworkLoader = artworkLoader
        self.playback = playback
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                TrackArtworkView(
                    artworkURL: playback.currentTrack?.artworkURL,
                    loader: artworkLoader,
                    size: 48
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(playback.currentTrack?.title ?? "Select a track")
                        .font(.headline)
                        .lineLimit(1)
                    Text(playback.currentTrack?.uploader
                        ?? "Choose a track to start listening")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }

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
        .padding(14)
    }

    private func format(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

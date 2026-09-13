import SwiftUI

struct VisualizerView: View {
    let playback: PlaybackController
    let spectrumBuffer: OpaquePointer
    let artworkLoader: ArtworkLoader

    var body: some View {
        ArtworkVisualizerView(
            spectrumBuffer: spectrumBuffer,
            artworkURL: playback.currentTrack?.displayArtworkURL,
            artworkLoader: artworkLoader
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipped()
        .accessibilityLabel("Audio visualizer")
    }
}

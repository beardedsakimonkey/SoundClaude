import SwiftUI

struct VisualizerView: View {
    let playback: PlaybackController
    let shader: VisualizerShader
    let spectrumBuffer: OpaquePointer
    let artworkLoader: ArtworkLoader
    let onClose: () -> Void

    @State private var inkPoolSettings = InkPoolSettings()
    @State private var isShowingControls = false

    var body: some View {
        ArtworkVisualizerView(
            shader: shader,
            inkPoolSettings: inkPoolSettings,
            spectrumBuffer: spectrumBuffer,
            artworkURL: playback.currentTrack?.displayArtworkURL,
            artworkLoader: artworkLoader
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture(perform: onClose)
        .overlay(alignment: .topTrailing) {
            if shader == .inkPool {
                Button {
                    isShowingControls.toggle()
                } label: {
                    Label("Ink Pool controls", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .padding(20)
                .popover(isPresented: $isShowingControls, arrowEdge: .bottom) {
                    inkPoolControls
                }
            }
        }
        .accessibilityLabel("Audio visualizer")
        .accessibilityValue(shader.title)
    }

    private var inkPoolControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Ink Pool").font(.headline)
                Spacer()
                Button("Reset") { inkPoolSettings = InkPoolSettings() }
            }
            ScrollView {
                VStack(spacing: 12) {
                    tuningSlider("Speed", value: $inkPoolSettings.speed, range: 0...1)
                    tuningSlider("Flow scale", value: $inkPoolSettings.flowScale, range: 0.5...8)
                    tuningSlider("Warp strength", value: $inkPoolSettings.warpStrength, range: 0...1.5)
                    tuningSlider("Bass response", value: $inkPoolSettings.bassResponse, range: 0...3)
                    tuningSlider("Ripple frequency", value: $inkPoolSettings.rippleFrequency, range: 0...80)
                    tuningSlider("Ripple strength", value: $inkPoolSettings.rippleStrength, range: 0...0.6)
                    tuningSlider("Surface depth", value: $inkPoolSettings.surfaceDepth, range: 0...1.5)
                    tuningSlider("Artwork scale", value: $inkPoolSettings.artworkScale, range: 0.02...0.6)
                    tuningSlider("Refraction", value: $inkPoolSettings.refraction, range: 0...3)
                    tuningSlider("Sheen", value: $inkPoolSettings.sheen, range: 0...1)
                    tuningSlider("Treble glints", value: $inkPoolSettings.glints, range: 0...8)
                }
            }
            .frame(maxHeight: 480)
        }
        .padding(20)
        .frame(width: 320)
    }

    private func tuningSlider(
        _ title: String, value: Binding<Float>, range: ClosedRange<Float>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue, specifier: "%.2f")")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range) { Text(title) }
        }
    }
}

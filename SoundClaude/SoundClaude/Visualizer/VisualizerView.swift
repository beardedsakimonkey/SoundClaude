import SwiftUI

struct VisualizerView: View {
    let playback: PlaybackController
    let shader: VisualizerShader
    let spectrumBuffer: OpaquePointer
    let artworkLoader: ArtworkLoader
    let onClose: () -> Void

    @State private var clothSettings = ClothSettings()
    @State private var clothCamera = ClothCamera()
    @State private var orbitStart: ClothCamera?
    @State private var inkPoolSettings = InkPoolSettings()
    @State private var isShowingControls = false

    var body: some View {
        ArtworkVisualizerView(
            shader: shader,
            inkPoolSettings: inkPoolSettings,
            clothSettings: clothSettings,
            clothCamera: $clothCamera,
            spectrumBuffer: spectrumBuffer,
            artworkURL: playback.currentTrack?.displayArtworkURL,
            artworkLoader: artworkLoader
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if orbitStart == nil { orbitStart = clothCamera }
                    guard let start = orbitStart else { return }
                    clothCamera.yaw = start.yaw + Float(value.translation.width) * 0.008
                    clothCamera.pitch = min(1.45, max(-1.45,
                        start.pitch + Float(value.translation.height) * 0.008))
                }
                .onEnded { _ in orbitStart = nil },
            including: shader == .cloth ? .all : .none
        )
        .onChange(of: shader) { _, _ in
            isShowingControls = false
            orbitStart = nil
        }
        .overlay(alignment: .topTrailing) {
            HStack {
                if shader == .inkPool || shader == .cloth {
                    Button {
                        isShowingControls.toggle()
                    } label: {
                        Label("\(shader.title) controls", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)
                    .popover(isPresented: $isShowingControls, arrowEdge: .bottom) {
                        if shader == .cloth { clothControls } else { inkPoolControls }
                    }
                }
                Button(action: onClose) {
                    Label("Close visualizer", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .help("Close visualizer (Escape)")
            }
            .padding(20)
        }
        .accessibilityLabel("Audio visualizer")
        .accessibilityValue(shader.title)
    }

    private var clothControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Cloth").font(.headline)
                Spacer()
                Button("Reset") {
                    clothSettings = ClothSettings()
                    clothCamera = ClothCamera()
                    orbitStart = nil
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    tuningSlider("Columns", value: $clothSettings.columns, range: 8...257)
                    tuningSlider("Rows", value: $clothSettings.rows, range: 8...257)
                    tuningSlider("Size", value: $clothSettings.width, range: 2...10)
                    Text("The cloth matches the artwork's proportions. Changing the mesh size resets the cloth.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    tuningSlider("Damping", value: $clothSettings.damping, range: 0.001...0.1, format: "%.3f")
                    tuningSlider("Stiffness", value: $clothSettings.stiffness, range: 0.1...1)
                    tuningSlider("Gravity", value: $clothSettings.gravity, range: 0...3)
                    tuningSlider("Bass impulse", value: $clothSettings.impulseStrength, range: 0...2)
                    tuningSlider("Impulse radius", value: $clothSettings.impulseRadius, range: 0.3...5)
                    Stepper("Solver passes: \(clothSettings.iterations)", value: $clothSettings.iterations, in: 2...10)
                    Divider()
                    tuningSlider("Shine intensity", value: $clothSettings.shineIntensity, range: 0...2)
                    tuningSlider("Gridline opacity", value: $clothSettings.gridlineOpacity, range: 0...1)
                    Text("Move the pointer to ripple the cloth. Drag to orbit. Scroll to zoom.")
                        .font(.caption).foregroundStyle(.secondary)
                    tuningSlider("Camera distance", value: $clothCamera.zoom, range: 0.2...2)
                    Button("Reset camera") {
                        clothCamera = ClothCamera()
                        orbitStart = nil
                    }
                }
            }
            .frame(maxHeight: 520)
        }
        .padding(20)
        .frame(width: 320)
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
        _ title: String, value: Binding<Int>, range: ClosedRange<Int>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue.formatted())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Int($0.rounded()) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 1
            ) { Text(title) }
        }
    }

    private func tuningSlider(
        _ title: String, value: Binding<Float>, range: ClosedRange<Float>, format: String = "%.2f"
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range) { Text(title) }
        }
    }
}

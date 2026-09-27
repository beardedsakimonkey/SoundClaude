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
    @State private var isShowingControls = false

    var body: some View {
        ArtworkVisualizerView(
            shader: shader,
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
                if shader == .cloth {
                    Button {
                        isShowingControls.toggle()
                    } label: {
                        Label("\(shader.title) controls", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)
                    .popover(isPresented: $isShowingControls, arrowEdge: .bottom) {
                        clothControls
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
                    tuningSlider("Stretch compliance", value: $clothSettings.compliance, range: 0...0.001, format: "%.1e")
                    tuningSlider("Bend compliance", value: $clothSettings.bendCompliance, range: 0...1, format: "%.3f")
                    Text("Higher compliance makes the cloth softer. Zero is rigid.")
                        .font(.caption).foregroundStyle(.secondary)
                    tuningSlider("Gravity", value: $clothSettings.gravity, range: 0...10)
                    tuningSlider("Bass impulse", value: $clothSettings.impulseStrength, range: 0...5)
                    tuningSlider("Impulse radius", value: $clothSettings.impulseRadius, range: 0.3...5)
                    Stepper("Solver passes: \(clothSettings.iterations)", value: $clothSettings.iterations, in: 1...10)
                    Divider()
                    Toggle("Show mesh (debug)", isOn: $clothSettings.showMesh)
                    tuningSlider("Shine intensity", value: $clothSettings.shineIntensity, range: 0...2)
                    tuningSlider("Chromatic aberration", value: $clothSettings.chromaticAberration, range: 0...1)
                    tuningSlider("Iridescence", value: $clothSettings.iridescence, range: 0...1)
                    tuningSlider("Ripple thickness", value: $clothSettings.rippleThickness, range: 0.25...4)
                    Text("Drag to orbit. Scroll to zoom.")
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
            .labelsHidden()
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
                .labelsHidden()
        }
    }
}

import SwiftUI

struct VisualizerView: View {
    let playback: PlaybackController
    let shader: VisualizerShader
    let spectrumBuffer: OpaquePointer
    let artworkLoader: ArtworkLoader
    let onClose: () -> Void

    @State private var pistonSettings = PistonSettings()
    @State private var clothSettings = ClothSettings()
    @State private var clothCamera = ClothCamera()
    @State private var orbitStart: ClothCamera?
    @State private var isShowingControls = false

    var body: some View {
        ArtworkVisualizerView(
            shader: shader,
            clothSettings: clothSettings,
            pistonSettings: pistonSettings,
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
                    let pitchRange = shader.cameraPitchRange
                    if orbitStart == nil {
                        clothCamera.pitch = min(pitchRange.upperBound, max(pitchRange.lowerBound, clothCamera.pitch))
                        orbitStart = clothCamera
                    }
                    guard let start = orbitStart else { return }
                    clothCamera.yaw = start.yaw + Float(value.translation.width) * 0.008
                    clothCamera.pitch = min(pitchRange.upperBound, max(pitchRange.lowerBound,
                        start.pitch + Float(value.translation.height) * 0.008))
                }
                .onEnded { _ in orbitStart = nil },
            including: shader.isSpatial ? .all : .none
        )
        .onChange(of: shader) { _, _ in
            isShowingControls = false
            orbitStart = nil
        }
        .overlay(alignment: .topTrailing) {
            HStack {
                if shader.isSpatial {
                    Button {
                        isShowingControls.toggle()
                    } label: {
                        Label("\(shader.title) controls", systemImage: "slider.horizontal.3")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .popover(isPresented: $isShowingControls, arrowEdge: .bottom) {
                        if shader == .pistons {
                            pistonControls
                        } else {
                            clothControls
                        }
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

    private var pistonControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Pistons").font(.headline)
                Spacer()
                Button("Reset") {
                    pistonSettings = PistonSettings()
                    clothCamera = ClothCamera()
                    orbitStart = nil
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    tuningSlider("Strings per piston", value: $pistonSettings.stringsPerPiston, range: 4...64, step: 2)
                    Text("String counts stay even so adjacent strings alternate colors. Changing the count resets the ropes.")
                        .font(.caption).foregroundStyle(.secondary)
                    tuningSlider("Rope length", value: $pistonSettings.ropeLength, range: 0.5...5)
                    tuningSlider("Rope thickness", value: $pistonSettings.ropeThickness, range: 0.004...0.08, format: "%.3f")
                    tuningSlider("Damping", value: $pistonSettings.damping, range: 0.001...0.08, format: "%.3f")
                    Text("Higher damping makes the strings settle faster. Long strings collect on the floor.")
                        .font(.caption).foregroundStyle(.secondary)
                    tuningSlider("Gravity", value: $pistonSettings.gravity, range: 0...20)
                    Divider()
                    tuningSlider("Piston travel", value: $pistonSettings.travel, range: 0...5)
                    Text("Low frequencies are on the left; high frequencies are on the right.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Text("Cylinder stripes").font(.subheadline.bold())
                    tuningSlider("Stripe thickness", value: $pistonSettings.stripeThickness, range: 0...0.08, format: "%.3f")
                    tuningSlider("Stripe frequency", value: $pistonSettings.stripeFrequency, range: 1...12)
                    ColorPicker("Stripe color", selection: pistonStripeColor, supportsOpacity: false)
                    Text("Higher frequency adds more stripes. Zero thickness hides them.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    tuningSlider("Camera distance", value: $clothCamera.zoom, range: 0.2...2)
                    Text("Drag to orbit. Scroll to zoom.")
                        .font(.caption).foregroundStyle(.secondary)
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

    private var pistonStripeColor: Binding<Color> {
        Binding(
            get: {
                let rgb = pistonSettings.stripeColor
                return Color(.sRGBLinear, red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
            },
            set: { color in
                guard let cgSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
                      let space = NSColorSpace(cgColorSpace: cgSpace),
                      let rgb = NSColor(color).usingColorSpace(space) else { return }
                pistonSettings.stripeColor = SIMD3(Float(rgb.redComponent), Float(rgb.greenComponent), Float(rgb.blueComponent))
            }
        )
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
        _ title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1
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
                step: Double(step)
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

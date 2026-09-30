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
    @State private var pistonCamera = PistonGroundControls.defaultCamera
    @State private var orbitStart: ClothCamera?
    @State private var isShowingControls = false
    @State private var viewportSize = CGSize.zero

    private var camera: ClothCamera {
        get { shader == .pistons ? pistonCamera : clothCamera }
        nonmutating set {
            if shader == .pistons {
                pistonCamera = newValue
            } else {
                clothCamera = newValue
            }
        }
    }

    var body: some View {
        ArtworkVisualizerView(
            shader: shader,
            clothSettings: clothSettings,
            pistonSettings: pistonSettings,
            trackProgress: playback.duration > 0 ? playback.currentTime / playback.duration : 0,
            hasTrack: playback.currentTrack != nil,
            clothCamera: Binding(get: { camera }, set: { camera = $0 }),
            spectrumBuffer: spectrumBuffer,
            artworkURL: playback.currentTrack?.displayArtworkURL,
            artworkLoader: artworkLoader
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipped()
        .contentShape(Rectangle())
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewportSize = $0 }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    let pitchRange = shader.cameraPitchRange
                    if orbitStart == nil {
                        camera.pitch = min(pitchRange.upperBound, max(pitchRange.lowerBound, camera.pitch))
                        orbitStart = camera
                    }
                    guard let start = orbitStart else { return }
                    camera.yaw = start.yaw + Float(value.translation.width) * 0.008
                    camera.pitch = min(pitchRange.upperBound, max(pitchRange.lowerBound,
                        start.pitch + Float(value.translation.height) * 0.008))
                }
                .onEnded { _ in orbitStart = nil }
                .exclusively(before: SpatialTapGesture().onEnded { value in
                    guard shader == .pistons, playback.currentTrack != nil else { return }
                    let camera = PistonGroundControls.camera(
                        size: viewportSize, yaw: camera.yaw,
                        pitch: camera.pitch, zoom: camera.zoom)
                    switch PistonGroundControls.hit(at: value.location, size: viewportSize, camera: camera) {
                    case .previous: playback.previous()
                    case .next: playback.next()
                    case .seek(let fraction): playback.seek(toFraction: fraction)
                    case nil: break
                    }
                })
        )
        .onChange(of: shader) { _, _ in
            isShowingControls = false
            orbitStart = nil
        }
        .overlay(alignment: .topTrailing) {
            HStack {
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
        .accessibilityActions {
            if shader == .pistons, playback.currentTrack != nil {
                Button("Previous track") { playback.previous() }
                Button("Next track") { playback.next() }
            }
        }
    }

    private var pistonControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Pistons").font(.headline)
                Spacer()
                Button("Reset") {
                    pistonSettings = PistonSettings()
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    tuningSlider("Ropes per piston", value: $pistonSettings.stringsPerPiston, range: 4...64, step: 2)
                    tuningSlider("Rope length", value: $pistonSettings.ropeLength, range: 0.5...5)
                    tuningSlider("Rope stretchiness", value: $pistonSettings.ropeStretchiness, range: 0...1)
                    tuningSlider("Rope thickness", value: $pistonSettings.ropeThickness, range: 0.004...0.08, format: "%.3f")
                    tuningSlider("Neutral rope glow", value: $pistonSettings.neutralRopeGlow, range: 0...1)
                    tuningSlider("Bloom strength", value: $pistonSettings.bloomStrength, range: 0...3)
                    tuningSlider("Damping", value: $pistonSettings.damping, range: 0.001...0.08, format: "%.3f")
                    tuningSlider("Gravity", value: $pistonSettings.gravity, range: 0...20)
                    Divider()
                    tuningSlider("Piston travel", value: $pistonSettings.travel, range: 0...5)
                    tuningSlider("Piston smoothing", value: $pistonSettings.smoothing, range: 0...10, format: "%.2f×")
                        .help("Softens sudden large amplitude changes. Small and gradual changes follow immediately. 0 disables smoothing; higher values soften large changes more.")
                    tuningSlider("Head twist", value: $pistonSettings.headTwist, range: -360...360, format: "%.0f°")
                    Divider()
                    Text("Cylinder stripes").font(.subheadline.bold())
                    tuningSlider("Stripe thickness", value: $pistonSettings.stripeThickness, range: 0...0.08, format: "%.3f")
                    tuningSlider("Stripe frequency", value: $pistonSettings.stripeFrequency, range: 1...12)
                    ColorPicker("Stripe color", selection: pistonColor(\.stripeColor), supportsOpacity: false)
                    Divider()
                    Text("Cylinder material").font(.subheadline.bold())
                    ColorPicker("Steel color", selection: pistonColor(\.metalColor), supportsOpacity: false)
                    ColorPicker("Base color", selection: pistonColor(\.baseColor), supportsOpacity: false)
                    tuningSlider("Roughness", value: $pistonSettings.roughness, range: 0.08...0.8)
                    tuningSlider("Metallic", value: $pistonSettings.metallic, range: 0...1)
                    tuningSlider("Reflections", value: $pistonSettings.reflectionStrength, range: 0...3)
                    tuningSlider("Edge softness", value: $pistonSettings.edgeSoftness, range: 0...0.05, format: "%.3f")
                }
            }
            .frame(maxHeight: 520)
        }
        .padding(20)
        .frame(width: 320)
    }

    private func pistonColor(_ keyPath: WritableKeyPath<PistonSettings, SIMD3<Float>>) -> Binding<Color> {
        Binding(
            get: {
                let rgb = pistonSettings[keyPath: keyPath]
                return Color(.sRGBLinear, red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
            },
            set: { color in
                guard let cgSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
                      let space = NSColorSpace(cgColorSpace: cgSpace),
                      let rgb = NSColor(color).usingColorSpace(space) else { return }
                pistonSettings[keyPath: keyPath] = SIMD3(Float(rgb.redComponent), Float(rgb.greenComponent), Float(rgb.blueComponent))
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
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    tuningSlider("Columns", value: $clothSettings.columns, range: 8...257)
                    tuningSlider("Rows", value: $clothSettings.rows, range: 8...257)
                    tuningSlider("Size", value: $clothSettings.width, range: 2...10)
                    Divider()
                    tuningSlider("Damping", value: $clothSettings.damping, range: 0.001...0.1, format: "%.3f")
                    tuningSlider("Stretch compliance", value: $clothSettings.compliance, range: 0...0.001, format: "%.1e")
                    tuningSlider("Bend compliance", value: $clothSettings.bendCompliance, range: 0...1, format: "%.3f")
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

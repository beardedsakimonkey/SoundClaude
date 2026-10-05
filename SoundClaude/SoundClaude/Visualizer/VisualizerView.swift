import SwiftUI

struct VisualizerView: View {
    let playback: PlaybackController
    let shader: VisualizerShader
    let spectrumBuffer: OpaquePointer
    let artworkLoader: ArtworkLoader
    let onClose: () -> Void

    @State private var smokeSettings = SmokeSettings()
    @State private var pistonSettings = PistonSettings()
    @State private var clothSettings = ClothSettings()
    @State private var clothCamera = ClothCamera()
    @State private var pistonCamera = PistonGroundControls.defaultCamera
    @State private var orbitTranslation = CGSize.zero
    @GestureState private var isOrbiting = false
    @State private var isShowingControls = false
    @State private var artworkAspect: Float = 1
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
            smokeSettings: smokeSettings,
            pistonSettings: pistonSettings,
            trackProgress: playback.duration > 0 ? playback.currentTime / playback.duration : 0,
            hasTrack: playback.currentTrack != nil,
            clothCamera: Binding(get: { camera }, set: { camera = $0 }),
            spectrumBuffer: spectrumBuffer,
            artworkURL: playback.currentTrack?.displayArtworkURL,
            artworkLoader: artworkLoader,
            onArtworkAspectChange: { artworkAspect = $0 }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipped()
        .contentShape(Rectangle())
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewportSize = $0 }
        .gesture(
            DragGesture(minimumDistance: 2)
                .updating($isOrbiting) { _, active, _ in active = true }
                .onChanged { value in
                    guard shader != .smoke else { return }
                    let delta = CGSize(width: value.translation.width - orbitTranslation.width,
                                       height: value.translation.height - orbitTranslation.height)
                    orbitTranslation = value.translation
                    camera.orbit(
                        delta: SIMD2(Float(delta.width), Float(delta.height)),
                        viewport: SIMD2(Float(viewportSize.width), Float(viewportSize.height)),
                        pitchRange: shader == .pistons
                            ? PistonGroundControls.orbitPitchRange(size: viewportSize, zoom: camera.zoom)
                            : shader.cameraPitchRange,
                        pitchDirection: shader == .cloth ? -1 : 1)
                }
                .onEnded { _ in orbitTranslation = .zero }
                .exclusively(before: SpatialTapGesture().onEnded { value in
                    guard playback.currentTrack != nil else { return }
                    let hit: PistonGroundControls.Hit?
                    if shader == .cloth {
                        let projection = ClothGroundControls.camera(size: viewportSize, camera: camera,
                                                                    artworkAspect: artworkAspect)
                        hit = ClothGroundControls.hit(at: value.location, size: viewportSize,
                            camera: projection, height: clothSettings.width / max(1, artworkAspect))
                    } else {
                        let projection = PistonGroundControls.camera(size: viewportSize, yaw: camera.yaw,
                                                                     pitch: camera.pitch, zoom: camera.zoom)
                        hit = PistonGroundControls.hit(at: value.location, size: viewportSize, camera: projection,
                                                       artworkAspect: artworkAspect)
                    }
                    switch hit {
                    case .playPause: playback.togglePlayPause()
                    case .previous: playback.previous()
                    case .next: playback.next()
                    case .seek(let fraction): playback.seek(toFraction: fraction)
                    case nil: break
                    }
                })
        )
        .onChange(of: isOrbiting) { _, active in
            if !active { orbitTranslation = .zero }
        }
        .onChange(of: shader) { _, _ in
            isShowingControls = false
            orbitTranslation = .zero
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
                    } else if shader == .smoke {
                        smokeControls
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
            if playback.currentTrack != nil {
                if shader == .pistons {
                    Button(playback.isPlaying ? "Pause" : "Play") { playback.togglePlayPause() }
                }
                Button("Previous track") { playback.previous() }
                Button("Next track") { playback.next() }
            }
        }
    }

    private var smokeControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Fluid").font(.headline)
                Spacer()
                Button("Reset") { smokeSettings = SmokeSettings() }
            }
            HStack {
                Text("Presets").font(.subheadline.bold())
                Spacer()
                Button("Liquid") { smokeSettings = .liquid }
                Button("Smoke") { smokeSettings = SmokeSettings() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Emission").font(.subheadline.bold())
                    tuningSlider("Sensitivity", value: $smokeSettings.sensitivity, range: 0.25...3)
                    tuningSlider("Size", value: $smokeSettings.puffSize, range: 0.3...6)
                    tuningSlider("Force", value: $smokeSettings.force, range: 0...6)
                    tuningSlider("Turbulence", value: $smokeSettings.turbulence, range: 0...3)
                    tuningSlider("Spread", value: $smokeSettings.spread, range: 0...1)
                        .help("How much of the view puffs spawn within, centered.")
                    Divider()
                    Text("Fluid dynamics").font(.subheadline.bold())
                    tuningSlider("Swirl", value: $smokeSettings.swirl, range: 0...60, format: "%.1f")
                        .help("Vorticity confinement: keeps curls and wisps from smoothing out.")
                    tuningSlider("Drag", value: $smokeSettings.drag, range: 0...4)
                        .help("Slows the flow over time. 0 lets motion persist.")
                    tuningSlider("Viscosity", value: $smokeSettings.viscosity, range: 0...30)
                        .help("Smooths differences in flow velocity. Higher values soften small eddies; 0 disables it.")
                    tuningSlider("Diffusion", value: $smokeSettings.diffusion, range: 0...12)
                        .help("Blends density and color into nearby cells. 0 keeps sharper color boundaries.")
                    tuningSlider("Decay", value: $smokeSettings.decay, range: 0...1.5)
                        .help("Controls how quickly color fades. Lower values leave longer trails; 0 disables fading.")
                    tuningSlider("Pressure iterations", value: $smokeSettings.pressureIterations, range: 4...60, step: 1)
                        .help("Higher values reduce fluid compression but use more GPU time.")
                    tuningSlider("Resolution", value: $smokeSettings.resolution, range: 256...1024, step: 64)
                        .help("Longest side of the simulation grid. Changing it restarts the fluid.")
                    Divider()
                    Text("Color").font(.subheadline.bold())
                    tuningSlider("Hue shift", value: $smokeSettings.hueShift, range: 0...360, format: "%.0f°")
                        .help("Starting hue offset for newly emitted color.")
                    tuningSlider("Hue speed", value: $smokeSettings.hueSpeed, range: 0...30, format: "%.1f°/s")
                        .help("Gradually cycles the color of new fluid. 0 stops the cycle.")
                    tuningSlider("Hue spread", value: $smokeSettings.hueSpread, range: 0...1.5)
                        .help("Hue difference between frequency groups. Applies to newly emitted color.")
                    tuningSlider("Saturation", value: $smokeSettings.saturation, range: 0...2.4)
                        .help("Applies to newly emitted color.")
                    tuningSlider("Brightness", value: $smokeSettings.brightness, range: 0.25...8)
                    tuningSlider("Hot cores", value: $smokeSettings.hotCores, range: 0...1)
                        .help("Turns the brightest fluid toward white while keeping faint fluid colorful. 0 disables it.")
                    tuningSlider("Glow", value: $smokeSettings.glow, range: 0...6)
                    tuningSlider("Glow radius", value: $smokeSettings.glowRadius, range: 1...48, format: "%.1f")
                    tuningSlider("Bloom", value: $smokeSettings.bloomStrength, range: 0...4)
                        .help("Soft light around bright fluid. 0 disables bloom.")
                    tuningSlider("Bloom radius", value: $smokeSettings.bloomRadius, range: 1...64, format: "%.1f")
                    tuningSlider("Outer bloom", value: $smokeSettings.bloomWideStrength, range: 0...2)
                        .help("Adds a soft halo at three times the bloom radius. 0 keeps only the tight bloom.")
                    tuningSlider("Bloom threshold", value: $smokeSettings.bloomThreshold, range: 0...4)
                        .help("Only fluid brighter than this value produces bloom.")
                }
            }
            .frame(maxHeight: 520)
        }
        .padding(20)
        .frame(width: 320)
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
                    tuningSlider("Sudden-change smoothing", value: $pistonSettings.suddenChangeSmoothing, range: 0...10, format: "%.2f×")
                        .help("Softens sudden large amplitude changes. This control adds no delay to small and gradual changes. 0 disables it; higher values soften large changes more.")
                    tuningSlider("Motion smoothing", value: $pistonSettings.motionSmoothing, range: 0...1, format: "%.2f×")
                        .help("Smooths every piston movement, with faster rises and slower falls. 0 disables it; 1× uses the original smoothing rates. Works together with sudden-change smoothing.")
                    tuningSlider("Head twist", value: $pistonSettings.headTwist, range: -360...360, format: "%.0f°")
                    Divider()
                    Text("Cylinder stripes").font(.subheadline.bold())
                    tuningSlider("Stripe thickness", value: $pistonSettings.stripeThickness, range: 0...0.08, format: "%.3f")
                    tuningSlider("Stripe frequency", value: $pistonSettings.stripeFrequency, range: 1...12)
                    ColorPicker("Stripe color", selection: pistonColor(\.stripeColor), supportsOpacity: false)
                    Divider()
                    Text("Scene colors").font(.subheadline.bold())
                    ColorPicker("Ground color", selection: pistonColor(\.groundColor), supportsOpacity: false)
                    ColorPicker("Background color", selection: pistonColor(\.backgroundColor), supportsOpacity: false)
                    ColorPicker("Background glow", selection: pistonColor(\.backgroundGlowColor), supportsOpacity: false)
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
                    tuningSlider("Size", value: $clothSettings.width, range: 2...20)
                    Divider()
                    tuningSlider("Damping", value: $clothSettings.damping, range: 0.001...0.1, format: "%.3f")
                    tuningSlider("Stretch compliance", value: $clothSettings.compliance, range: 0...0.001, format: "%.1e")
                    tuningSlider("Bend compliance", value: $clothSettings.bendCompliance, range: 0...1, format: "%.3f")
                    tuningSlider("Gravity", value: $clothSettings.gravity, range: 0...10)
                    tuningSlider("Bass impulse", value: $clothSettings.impulseStrength, range: 0...20)
                    tuningSlider("Treble impulse", value: $clothSettings.trebleImpulseStrength, range: 0...1, format: "%.2f")
                    tuningSlider("Impulse radius", value: $clothSettings.impulseRadius, range: 0.3...5)
                    Stepper("Solver passes: \(clothSettings.iterations)", value: $clothSettings.iterations, in: 1...10)
                    Divider()
                    Toggle("Show mesh (debug)", isOn: $clothSettings.showMesh)
                    tuningSlider("Shine intensity", value: $clothSettings.shineIntensity, range: 0...2)
                    tuningSlider("Impulse flash brightness", value: $clothSettings.flashBrightness, range: 0...3)
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

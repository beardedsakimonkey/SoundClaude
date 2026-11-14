import SwiftUI

struct VisualizerView: View {
    let playback: PlaybackController
    // Keep shader selection and its updates local to the visualizer.
    @AppStorage("visualizerShader") private var shader: VisualizerShader = .pistons
    let spectrumBuffer: OpaquePointer
    let artworkLoader: ArtworkLoader
    let onClose: () -> Void

    @State private var pistonSettings = PistonSettings()
    @State private var pistonCamera = PistonCameraProjection.defaultCamera
    @State private var orbitTranslation = CGSize.zero
    @GestureState private var isOrbiting = false
    @State private var orbitCoast: Task<Void, Never>?
    @State private var isShowingControls = false
    @State private var viewportSize = CGSize.zero

    var body: some View {
        ArtworkVisualizerView(
            shader: shader,
            pistonSettings: pistonSettings,
            pistonCamera: $pistonCamera,
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
                .updating($isOrbiting) { _, active, _ in active = true }
                .onChanged { value in
                    guard !movesWindow(value) else { return }
                    orbitCoast?.cancel()
                    let delta = CGSize(width: value.translation.width - orbitTranslation.width,
                                       height: value.translation.height - orbitTranslation.height)
                    orbitTranslation = value.translation
                    orbit(by: delta)
                }
                .onEnded { value in
                    orbitTranslation = .zero
                    guard !movesWindow(value) else { return }
                    coastOrbit(velocity: value.velocity)
                }
        )
        .onChange(of: isOrbiting) { _, active in
            if !active { orbitTranslation = .zero }
        }
        .onChange(of: shader) { _, _ in
            isShowingControls = false
            orbitTranslation = .zero
            orbitCoast?.cancel()
        }
        .onDisappear { orbitCoast?.cancel() }
        .overlay(alignment: .topTrailing) {
            HStack {
                #if DEBUG
                Button {
                    isShowingControls.toggle()
                } label: {
                    Label("\(shader.title) controls", systemImage: "slider.horizontal.3")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .popover(isPresented: $isShowingControls, arrowEdge: .bottom) {
                    pistonControls
                }
                #endif
                Button(action: onClose) {
                    Label("Close visualizer", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .help("Close visualizer (Escape)")
            }
            // The scene is always dark, so match the buttons to it in light mode.
            .environment(\.colorScheme, .dark)
            .padding(20)
        }
        .accessibilityLabel("Audio visualizer")
        .accessibilityValue(shader.title)
        .background {
            Button("Dismiss visualizer controls or close visualizer") {
                if isShowingControls {
                    isShowingControls = false
                } else {
                    onClose()
                }
            }
            .keyboardShortcut(.cancelAction)
            .hidden()
            .accessibilityHidden(true)
        }
        .accessibilityActions {
            if playback.currentTrack != nil {
                Button(playback.isPlaying ? "Pause" : "Play") { playback.togglePlayPause() }
                Button("Previous track") { playback.previous() }
                Button("Next track") { playback.next() }
            }
        }
        #if DEBUG
        .debugViewUpdates("VisualizerView")
        #endif
    }

    /// The scene extends under the hidden title bar, where a drag moves the window.
    private func movesWindow(_ drag: DragGesture.Value) -> Bool {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return false }
        return drag.startLocation.y < window.frame.height - window.contentLayoutRect.height
    }

    private func orbit(by delta: CGSize) {
        pistonCamera.orbit(
            delta: SIMD2(Float(delta.width), Float(delta.height)),
            viewport: SIMD2(Float(viewportSize.width), Float(viewportSize.height)),
            pitchRange: PistonCameraProjection.orbitPitchRange(
                size: viewportSize, zoom: pistonCamera.zoom, targetHeight: pistonCamera.target.y))
    }

    /// Keeps the orbit turning after a drag is released, slowing to a stop.
    private func coastOrbit(velocity: CGSize) {
        orbitCoast?.cancel()
        // A flick can report extreme speeds; cap it at a brisk spin.
        let speed = hypot(velocity.width, velocity.height)
        guard speed > 40 else { return }
        let limit = min(1, 3000 / speed)
        var velocity = CGSize(width: velocity.width * limit, height: velocity.height * limit)
        orbitCoast = Task { @MainActor in
            var last = ContinuousClock.now
            var expected = pistonCamera
            while hypot(velocity.width, velocity.height) > 8 {
                try? await Task.sleep(for: .milliseconds(8))
                // Stop if a camera reset or another change moved the orbit meanwhile.
                guard !Task.isCancelled, pistonCamera.yaw == expected.yaw,
                      pistonCamera.pitch == expected.pitch else { return }
                let now = ContinuousClock.now
                let elapsed = min(0.05, (now - last) / .seconds(1))
                last = now
                orbit(by: CGSize(width: velocity.width * elapsed, height: velocity.height * elapsed))
                expected = pistonCamera
                // Lose about 95% of the speed each second.
                let decay = exp(-3 * elapsed)
                velocity = CGSize(width: velocity.width * decay, height: velocity.height * decay)
            }
        }
    }

    #if DEBUG
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
                    tuningSlider("Resting rope brightness", value: $pistonSettings.restingRopeBrightness, range: 0...1)
                        .help("Rope brightness while a piston rests at the bottom. Ropes fade to full brightness over the first 10% of its travel.")
                    tuningSlider("Resting rope glow", value: $pistonSettings.restingRopeGlow, range: 0...1)
                        .help("Rope halo strength while a piston rests at the bottom. The halo fades to full strength over the first 10% of its travel.")
                    tuningSlider("Bloom strength", value: $pistonSettings.bloomStrength, range: 0...3)
                    tuningSlider("Spotlight strength", value: $pistonSettings.spotlightStrength, range: 0...3)
                        .help("Brightness of every spotlight, regardless of piston height.")
                    tuningSlider("Spotlight size", value: $pistonSettings.spotlightSize, range: 0.1...3, format: "%.2f×")
                    tuningSlider("Light tint", value: $pistonSettings.lightTint, range: 0...1)
                        .help("How strongly the background glow's color tints the scene lighting. 0 keeps it white.")
                    tuningSlider("Light Y offset", value: $pistonSettings.lightYOffset, range: -0.6...3)
                        .help("Raises or lowers the scene light. Lower lights rake across the pistons and cast longer shadows.")
                    tuningSlider("Light Z offset", value: $pistonSettings.lightZOffset, range: -3...3)
                        .help("Moves the scene light toward the default view (positive) or further behind the pistons (negative).")
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
                    Text("Environment").font(.subheadline.bold())
                    tuningSlider("Sky glow", value: $pistonSettings.skyGlow, range: 0...2)
                        .help("Afterglow along the horizon in the artwork's color. It brightens with the music.")
                    tuningSlider("Stars", value: $pistonSettings.skyStars, range: 0...2)
                    tuningSlider("Nebula", value: $pistonSettings.skyNebula, range: 0...2)
                    tuningSlider("Floor reflection", value: $pistonSettings.groundReflection, range: 0...1)
                    tuningSlider("Floor rope light", value: $pistonSettings.groundRopeLight, range: 0...2)
                        .help("Colored light the glowing ropes cast on the floor.")
                    tuningSlider("Floor tile seams", value: $pistonSettings.groundTileSeams, range: 0...1)
                    Divider()
                    Text("Cylinder material").font(.subheadline.bold())
                    ColorPicker("Steel color", selection: pistonColor(\.metalColor), supportsOpacity: false)
                    ColorPicker("Base color", selection: pistonColor(\.baseColor), supportsOpacity: false)
                    tuningSlider("Roughness", value: $pistonSettings.roughness, range: 0.08...0.8)
                    tuningSlider("Metallic", value: $pistonSettings.metallic, range: 0...1)
                    tuningSlider("Reflections", value: $pistonSettings.reflectionStrength, range: 0...3)
                    tuningSlider("Edge softness", value: $pistonSettings.edgeSoftness, range: 0...0.05, format: "%.3f")
                    Divider()
                    gradeControls($pistonSettings.grade)
                }
            }
            .frame(maxHeight: 520)
        }
        .padding(20)
        .frame(width: 320)
    }

    private func pistonColor(_ keyPath: WritableKeyPath<PistonSettings, SIMD3<Float>>) -> Binding<Color> {
        linearColor($pistonSettings[dynamicMember: keyPath])
    }

    private func linearColor(_ value: Binding<SIMD3<Float>>) -> Binding<Color> {
        Binding(
            get: {
                let rgb = value.wrappedValue
                return Color(.sRGBLinear, red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
            },
            set: { color in
                guard let cgSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
                      let space = NSColorSpace(cgColorSpace: cgSpace),
                      let rgb = NSColor(color).usingColorSpace(space) else { return }
                value.wrappedValue = SIMD3(Float(rgb.redComponent), Float(rgb.greenComponent), Float(rgb.blueComponent))
            }
        )
    }

    @ViewBuilder
    private func gradeControls(_ grade: Binding<VisualizerGrade>) -> some View {
        Text("Color grading").font(.subheadline.bold())
        tuningSlider("Amount", value: grade.amount, range: 0...1)
            .help("Blend between the original and graded frame. 0 turns grading off.")
        tuningSlider("Contrast", value: grade.contrast, range: 0.5...2)
        tuningSlider("Saturation", value: grade.saturation, range: 0...2)
        ColorPicker("Shadow tint", selection: linearColor(grade.shadowTint), supportsOpacity: false)
            .help("Hue for dark areas. White is neutral; tints keep brightness unchanged.")
        ColorPicker("Highlight tint", selection: linearColor(grade.highlightTint), supportsOpacity: false)
            .help("Hue for bright areas. White is neutral; tints keep brightness unchanged.")
        tuningSlider("Vignette", value: grade.vignette, range: 0...1)
        tuningSlider("Grain", value: grade.grain, range: 0...0.2, format: "%.3f")
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
    #endif
}

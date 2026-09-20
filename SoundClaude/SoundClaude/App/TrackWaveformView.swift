import AppKit
import SwiftUI

struct TrackWaveformView: View {
    enum Layout {
        case detail
        case compact

        var height: CGFloat { self == .compact ? 60 : 100 }
        var reflectionHeight: CGFloat { self == .detail ? floor(height * 0.32) : 0 }

        func availableBarHeight(for height: CGFloat) -> CGFloat {
            self == .compact ? height - 4 : height - reflectionHeight - 2
        }
    }

    let track: SoundCloudTrack?
    let model: AppModel
    let layout: Layout
    let height: CGFloat
    let animatesBarTransitions: Bool
    let invertsBarsOnTrackChange: Bool
    let collapsesBarsWhenPaused: Bool
    let keepsBarsVisible: Bool
    let onPlayTrack: ((SoundCloudTrack) async -> Void)?

    private let playback: PlaybackController
    @State private var gradientCache = WaveformGradientCache()
    @State private var waveform: SoundCloudWaveform?
    @State private var waveformTrackURN: String?
    @State private var barDirection: Double = 1
    @State private var errorMessage: String?
    @State private var artworkAccent: ArtworkAccent?
    @State private var accentArtworkURL: URL?
    @State private var hoverFraction: Double = 0
    @State private var isHovering = false
    @Environment(\.contentAnimationsPaused) private var contentAnimationsPaused
    @Environment(\.contentHoverEnabled) private var contentHoverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    init(
        track: SoundCloudTrack?,
        model: AppModel,
        layout: Layout = .detail,
        height: CGFloat? = nil,
        animatesBarTransitions: Bool = true,
        invertsBarsOnTrackChange: Bool = false,
        collapsesBarsWhenPaused: Bool? = nil,
        keepsBarsVisible: Bool = false,
        onPlayTrack: ((SoundCloudTrack) async -> Void)? = nil
    ) {
        self.track = track
        self.model = model
        self.layout = layout
        self.height = height ?? layout.height
        self.animatesBarTransitions = animatesBarTransitions
        self.invertsBarsOnTrackChange = invertsBarsOnTrackChange
        self.collapsesBarsWhenPaused = collapsesBarsWhenPaused ?? (layout == .detail)
        self.keepsBarsVisible = keepsBarsVisible
        self.onPlayTrack = onPlayTrack
        playback = model.playback
        let cachedWaveform = track.flatMap { model.cachedWaveform(for: $0) }
        _waveform = State(initialValue: cachedWaveform)
        _waveformTrackURN = State(initialValue: cachedWaveform == nil ? nil : track?.urn)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if contentAnimationsPaused {
                    // Opacity alone leaves playback observation and Canvas work active.
                    // Keep layout and loaded state, but remove the drawing subtree
                    // (including its progress labels) while the visualizer covers it.
                    Color.clear
                        .frame(height: height)
                } else if layout == .compact || keepsBarsVisible || track == nil {
                    waveformView(waveform)
                        .overlay {
                            if waveform == nil, let errorMessage {
                                Text(errorMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                                    .background(.background)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                } else if let waveform {
                    waveformView(waveform)
                } else if let errorMessage {
                    Label(errorMessage, systemImage: "waveform.slash")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: height)
                } else {
                    Color.clear
                        .frame(height: height)
                }
            }
        }
        .task(id: [track?.urn ?? "", track?.waveformURL?.absoluteString ?? ""]) {
            await load()
        }
        .task(id: track?.displayArtworkURL) {
            artworkAccent = nil
            accentArtworkURL = nil
            guard let url = track?.displayArtworkURL,
                  let accent = try? await model.artworkLoader.accentColor(for: url),
                  !Task.isCancelled else { return }
            artworkAccent = accent
            accentArtworkURL = url
        }
    }

    private func waveformView(_ waveform: SoundCloudWaveform?) -> some View {
        HStack(spacing: 8) {
            GeometryReader { proxy in
                let amplitudes = barAmplitudes(waveform, width: proxy.size.width)
                let trackChangeAnimation = reduceMotion || !animatesBarTransitions ? nil : Animation(
                    WaveformStaggeredSpring(
                        reversesStagger: isCurrentTrack && playback.trackChangeDirection == .backward
                    )
                )
                // Read observed state before entering Canvas. Direct observation
                // in its renderer can redraw with target bar heights while the
                // animatable view is still interpolating them.
                let renderedProgress = progress
                let renderedProgressColor = progressColor
                let renderedHoverFraction = hoverFraction
                let hoverStrength = colorScheme == .light
                    && renderedHoverFraction >= renderedProgress ? 0.4 : 0.3
                WaveformAnimatedCanvas(
                    amplitudes: amplitudes,
                    hoverOpacity: showsHoverPreview ? hoverStrength : 0
                ) { context, size, amplitudes, hoverOpacity in
                    guard size.width > 0, size.height > 0 else { return }
                    let bars = waveformBars(amplitudes, size: size)
                    let path = CGMutablePath()
                    for bar in bars {
                        if layout == .compact {
                            path.addRoundedRect(in: bar, cornerWidth: 1, cornerHeight: 1)
                            continue
                        }
                        // Bar coordinates start at the bottom. Keep the
                        // ground edge square and round only the top corners.
                        let radius = min(1, bar.width / 2, bar.height / 2)
                        path.move(to: CGPoint(x: bar.minX, y: bar.minY))
                        path.addLine(to: CGPoint(x: bar.maxX, y: bar.minY))
                        path.addArc(
                            tangent1End: CGPoint(x: bar.maxX, y: bar.maxY),
                            tangent2End: CGPoint(x: bar.midX, y: bar.maxY),
                            radius: radius
                        )
                        path.addArc(
                            tangent1End: CGPoint(x: bar.minX, y: bar.maxY),
                            tangent2End: CGPoint(x: bar.minX, y: bar.minY),
                            radius: radius
                        )
                        path.closeSubpath()
                    }
                    let backgroundOpacity = layout == .compact ? 0.3 : 0.5
                    let backgroundStrength = colorScheme == .light
                        && colorSchemeContrast != .increased ? 0.6 : 1.0
                    let background = Color.secondary.opacity(backgroundOpacity * backgroundStrength)
                        .resolve(in: context.environment).cgColor
                    let color = renderedProgressColor.opacity(layout == .compact ? 0.8 : 1)
                        .resolve(in: context.environment).cgColor
                    // In light mode, retain the accent in the seek preview.
                    let highlight = Color.white.opacity(colorScheme == .dark ? 0.9 : 0.12)
                        .resolve(in: context.environment).cgColor
                    let shadow = Color.black.opacity(0.9)
                        .resolve(in: context.environment).cgColor
                    let progress = renderedProgress

                    // Clip once outside the color layer so progress and hover
                    // cannot change antialiasing along the bar outline.
                    let drawBars: (inout GraphicsContext) -> Void = { drawing in
                        drawing.clip(to: Path(path))
                        drawing.drawLayer { layer in
                            layer.withCGContext { cg in
                                cg.setShouldAntialias(false)
                                fillBars(background, in: cg, bars: bars, rect: CGRect(origin: .zero, size: size))
                                fillBars(color, in: cg, bars: bars, rect: CGRect(
                                    x: 0, y: 0,
                                    width: size.width * progress,
                                    height: size.height
                                ))

                                if hoverOpacity > 0 {
                                    let hoverRegion = CGRect(
                                        x: size.width * min(progress, renderedHoverFraction),
                                        y: 0,
                                        width: size.width * abs(renderedHoverFraction - progress),
                                        height: size.height
                                    )
                                    cg.saveGState()
                                    cg.setAlpha(hoverOpacity)
                                    cg.beginTransparencyLayer(auxiliaryInfo: nil)
                                    if renderedHoverFraction < progress {
                                        cg.setFillColor(shadow)
                                        cg.fill(hoverRegion)
                                    } else {
                                        fillBars(color, in: cg, bars: bars, rect: hoverRegion)
                                        fillBars(highlight, in: cg, bars: bars, rect: hoverRegion)
                                    }
                                    cg.endTransparencyLayer()
                                    cg.restoreGState()
                                }
                            }
                        }
                    }
                    // Canvas records drawing commands. No CPU bitmap allocation
                    // or image snapshot is needed for animated bar heights.
                    context.translateBy(x: 0, y: size.height)
                    context.scaleBy(x: 1, y: -1)
                    var main = context
                    drawBars(&main)
                    if layout == .detail {
                        addGroundReflection(in: &context, size: size, drawBars: drawBars)
                    }
                }
                // Resampling during window resizing must not start or extend a spring.
                .animation(nil, value: proxy.size)
                .animation(
                    trackChangeAnimation,
                    value: waveform
                )
                .animation(
                    trackChangeAnimation,
                    value: barDirection
                )
                .animation(
                    reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.3),
                    value: showsHoverPreview
                )
                .animation(
                    reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.3),
                    value: hoverFraction
                )
                .animation(
                    reduceMotion || !animatesBarTransitions ? nil : .spring(duration: 0.35, bounce: 0.3),
                    value: barsAreCollapsed
                )
                .modifier(WaveformLoadingOpacity(
                    isPulsing: shouldPulseBars,
                    idleOpacity: shouldDimBars ? 0.5 : 1
                ))
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.3),
                    value: shouldDimBars
                )
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoverFraction = fraction(
                            at: location.x,
                            width: proxy.size.width
                        )
                        isHovering = true
                    case .ended:
                        isHovering = false
                    }
                }
                .onDisappear { isHovering = false }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard isCurrentTrack else { return }
                            seek(
                                to: fraction(
                                    at: value.location.x,
                                    width: proxy.size.width
                                )
                            )
                        }
                        .onEnded { value in
                            seek(
                                to: fraction(
                                    at: value.location.x,
                                    width: proxy.size.width
                                )
                            )
                        }
                )
                .help(
                    track == nil ? "Start playback to see the waveform."
                        : isCurrentTrack ? "Click or drag to seek."
                        : "Click to play from this position."
                )
            }
            .frame(height: height)

            if layout == .detail {
                let reflectionHeight = layout.reflectionHeight
                VStack(alignment: .trailing, spacing: 0) {
                    Text(format(seconds: displayedCurrentTime))
                        .bold()
                        .padding(.bottom, 2)
                        .frame(height: height - reflectionHeight, alignment: .bottom)
                    Text(format(seconds: displayedDuration))
                        .opacity(0.6)
                        .padding(.top, 2)
                        .frame(height: reflectionHeight, alignment: .top)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        // Keep a visible focus ring for keyboard navigation without focusing on click.
        .focusable(isCurrentTrack, interactions: .activate)
        .onKeyPress(.leftArrow) {
            guard isCurrentTrack else { return .ignored }
            playback.seek(by: -5)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard isCurrentTrack else { return .ignored }
            playback.seek(by: 5)
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(track == nil ? "Waveform, playback not started" : "Track waveform")
        .accessibilityValue(
            "\(format(seconds: displayedCurrentTime)) of "
                + format(seconds: displayedDuration)
        )
        .accessibilityAdjustableAction { direction in
            guard isCurrentTrack else { return }
            switch direction {
            case .increment:
                playback.seek(by: 5)
            case .decrement:
                playback.seek(by: -5)
            @unknown default:
                break
            }
        }
    }

    private func addGroundReflection(
        in context: inout GraphicsContext,
        size: CGSize,
        drawBars: (inout GraphicsContext) -> Void
    ) {
        let ground = layout.reflectionHeight
        let reflectionTop = ground - 1
        let reflectionScale: CGFloat = 0.45
        let reflectionHeight = min(reflectionTop, (size.height - ground - 2) * reflectionScale)
        guard reflectionHeight > 0 else { return }
        context.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: reflectionTop)))
        context.drawLayer { reflection in
            var bars = reflection
            bars.translateBy(x: 0, y: reflectionTop + ground * reflectionScale)
            bars.scaleBy(x: 1, y: -reflectionScale)
            drawBars(&bars)

            // Fade the complete reflection, including progress and hover.
            reflection.blendMode = .destinationIn
            reflection.fill(
                Path(CGRect(x: 0, y: 0, width: size.width, height: reflectionTop)),
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .white.opacity(0.65), location: 0),
                        .init(color: .white.opacity(0.22), location: 0.5),
                        .init(color: .white.opacity(0), location: 1)
                    ]),
                    startPoint: CGPoint(x: 0, y: reflectionTop),
                    endPoint: CGPoint(x: 0, y: reflectionTop - reflectionHeight)
                )
            )
        }
    }

    private func fillBars(
        _ color: CGColor, in context: CGContext, bars: [CGRect], rect: CGRect
    ) {
        guard !rect.isEmpty else { return }
        if layout == .compact {
            context.setFillColor(color)
            context.fill(rect)
            return
        }
        guard let gradient = gradientCache.gradient(
            for: color, isDark: colorScheme == .dark
        ) else { return }

        context.saveGState()
        context.clip(to: rect)
        // Reuse the gradient, but fit its full range to each animated bar.
        // Playback and hover only clip the fill; they do not move the shading.
        for bar in bars where bar.intersects(rect) {
            context.saveGState()
            context.clip(to: bar)
            // Bar coordinates start at the bottom.
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: bar.midX, y: bar.maxY),
                end: CGPoint(x: bar.midX, y: bar.minY),
                options: []
            )
            context.restoreGState()
        }
        context.restoreGState()
    }

    private var progressColor: Color {
        let fallback = ArtworkAccent.fallback
        let accent = accentArtworkURL == track?.displayArtworkURL
            ? artworkAccent ?? fallback : fallback
        let contrastedAccent = accent.contrasted(
            isDark: colorScheme == .dark,
            increasedContrast: colorSchemeContrast == .increased
        )
        return Color(
            .sRGB, red: contrastedAccent.red,
            green: contrastedAccent.green, blue: contrastedAccent.blue
        )
    }

    private var isCurrentTrack: Bool {
        guard let track else { return false }
        return playback.currentTrack?.urn == track.urn
    }

    private var shouldDimBars: Bool {
        (isCurrentTrack && (playback.isLoading || playback.isBuffering)) || !isCurrentTrack
    }

    private var shouldPulseBars: Bool {
        isCurrentTrack && (playback.isLoading || playback.isBuffering) && !reduceMotion
    }

    private var displayedCurrentTime: Double {
        isCurrentTrack ? playback.currentTime : 0
    }

    private var displayedDuration: Double {
        if isCurrentTrack, playback.duration > 0 {
            return playback.duration
        }
        return Double(track?.durationMilliseconds ?? 0) / 1_000
    }

    private var progress: Double {
        guard isCurrentTrack, displayedDuration > 0 else { return 0 }
        return min(max(displayedCurrentTime / displayedDuration, 0), 1)
    }

    private var barsAreCollapsed: Bool {
        track == nil || (keepsBarsVisible && waveform == nil)
            || (collapsesBarsWhenPaused && (!isCurrentTrack || !playback.isPlaybackActive))
    }

    private var showsHoverPreview: Bool {
        track != nil && isHovering && contentHoverEnabled
    }

    private func barAmplitudes(
        _ waveform: SoundCloudWaveform?,
        width: CGFloat
    ) -> WaveformAmplitudes {
        // Keep the same bars for every track, including the loading state.
        let barCount = max(Int(width / 4), 1)
        let pausedHeight = 4.0
        let availableHeight = layout.availableBarHeight(for: height)
        let pausedAmplitude = pausedHeight / Double(availableHeight)
        if barsAreCollapsed && !showsHoverPreview {
            return WaveformAmplitudes(values: Array(repeating: pausedAmplitude, count: barCount))
        }
        guard let waveform, !waveform.samples.isEmpty, waveform.height > 0 else {
            return WaveformAmplitudes(values: Array(
                repeating: barsAreCollapsed ? pausedAmplitude : 0,
                count: barCount
            ))
        }
        // Measure from the bar centers (x = index * 4 + 1). Normalize the
        // distance so the nearest bar reveals fully and the farthest stays flat.
        let pointerIndex = (hoverFraction * Double(width) - 1) / 4
        let nearestIndex = min(max(pointerIndex.rounded(), 0), Double(barCount - 1))
        let nearestDistance = abs(pointerIndex - nearestIndex)
        let farthestDistance = max(abs(pointerIndex), abs(pointerIndex - Double(barCount - 1)))
        let distanceRange = farthestDistance - nearestDistance
        return WaveformAmplitudes(values: (0..<barCount).map { index in
            let lowerBound = index * waveform.samples.count / barCount
            let upperBound = max(
                (index + 1) * waveform.samples.count / barCount,
                lowerBound + 1
            )
            let sample = waveform.samples[lowerBound..<upperBound].max() ?? 0
            let amplitude = min(max(Double(sample) / Double(waveform.height), 0), 1)
            if barsAreCollapsed {
                let distance = abs(Double(index) - pointerIndex)
                let proximity = distanceRange > 0
                    ? min(max((farthestDistance - distance) / distanceRange, 0), 1)
                    : 1
                // Keep a long, subtle tail and concentrate the height increase
                // near the pointer with a normalized exponential ease-in.
                let exponent = 4.0
                let reveal = (exp(exponent * proximity) - 1) / (exp(exponent) - 1)
                // Interpolate visible heights, independent of animation direction.
                let fullAmplitude = max(amplitude, 2 / Double(availableHeight))
                return pausedAmplitude + (fullAmplitude - pausedAmplitude) * reveal
            }
            return amplitude * barDirection
        })
    }

    private func waveformBars(
        _ amplitudes: WaveformAmplitudes,
        size: CGSize
    ) -> [CGRect] {
        let barWidth: CGFloat = 2
        let step: CGFloat = 4
        let availableHeight = layout.availableBarHeight(for: size.height)
        return amplitudes.values.enumerated().map { index, amplitude in
            // Signed amplitudes collapse during track changes. Take the
            // absolute value after spring interpolation.
            let height = max(CGFloat(abs(amplitude)) * availableHeight, 2)
            return CGRect(
                x: CGFloat(index) * step,
                y: layout == .compact ? (size.height - height) / 2 : layout.reflectionHeight,
                width: barWidth,
                height: height
            )
        }
    }

    private func fraction(at xPosition: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(max(Double(xPosition / width), 0), 1)
    }

    private func seek(to fraction: Double) {
        guard let track else { return }
        if isCurrentTrack {
            playback.seek(toFraction: fraction)
            return
        }

        Task { @MainActor in
            if let onPlayTrack {
                await onPlayTrack(track)
            } else {
                await model.play(track)
            }
            guard playback.currentTrack?.urn == track.urn else { return }
            playback.seek(toFraction: fraction)
        }
    }

    private func format(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        return String(
            format: "%d:%02d",
            totalSeconds / 60,
            totalSeconds % 60
        )
    }

    private func load() async {
        guard let track else {
            waveform = nil
            waveformTrackURN = nil
            barDirection = 1
            errorMessage = nil
            return
        }
        if let cachedWaveform = model.cachedWaveform(for: track) {
            setWaveform(cachedWaveform)
            errorMessage = nil
            return
        }

        if !invertsBarsOnTrackChange {
            waveform = nil
        }
        errorMessage = nil
        do {
            let loadedWaveform = try await model.waveform(for: track)
            guard !Task.isCancelled else { return }
            setWaveform(loadedWaveform)
        } catch {
            guard !Task.isCancelled else { return }
            waveform = nil
            errorMessage = "Waveform unavailable"
        }
    }

    private func setWaveform(_ loadedWaveform: SoundCloudWaveform) {
        guard let track else { return }
        if invertsBarsOnTrackChange,
           let waveformTrackURN, waveformTrackURN != track.urn {
            barDirection *= -1
        }
        waveformTrackURN = track.urn
        waveform = loadedWaveform
    }
}

private struct WaveformLoadingOpacity: ViewModifier {
    @Environment(\.contentAnimationsPaused) private var contentAnimationsPaused

    let isPulsing: Bool
    let idleOpacity: Double

    func body(content: Content) -> some View {
        // Pause frame updates outside loading, and resume on every new load.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isPulsing || contentAnimationsPaused)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.6) / 1.6
            content.opacity(isPulsing ? 0.35 + 0.4 * abs(sin(phase * .pi)) : idleOpacity)
        }
    }
}

private struct WaveformStaggeredSpring: CustomAnimation {
    let reversesStagger: Bool
    private let spring = Spring(duration: 0.45, bounce: 0.3)
    private let staggerDuration: TimeInterval = 0.2

    func animate<V: VectorArithmetic>(
        value: V,
        time: TimeInterval,
        context: inout AnimationContext<V>
    ) -> V? {
        guard time < spring.settlingDuration + staggerDuration else { return nil }
        guard var bars = value as? AnimatablePair<WaveformAmplitudes, Double> else {
            return spring.value(target: value, time: time)
        }

        // Spread the delay across the width so resizing does not change its duration.
        let lastIndex = max(bars.first.values.count - 1, 0)
        bars.first.values = bars.first.values.enumerated().map { index, amplitude in
            let staggerIndex = reversesStagger ? lastIndex - index : index
            let delay = staggerDuration * Double(staggerIndex) / Double(max(lastIndex, 1))
            guard time > delay else { return 0 }
            return spring.value(target: amplitude, time: time - delay)
        }
        bars.second = spring.value(target: bars.second, time: time)
        return bars as? V
    }
}

// Canvas drawing needs explicit animatable inputs for bar heights and hover.
private struct WaveformAnimatedCanvas: View, Animatable {
    var amplitudes: WaveformAmplitudes
    var hoverOpacity: Double
    var renderer: (inout GraphicsContext, CGSize, WaveformAmplitudes, Double) -> Void

    var animatableData: AnimatablePair<WaveformAmplitudes, Double> {
        get { AnimatablePair(amplitudes, hoverOpacity) }
        set {
            amplitudes = newValue.first
            hoverOpacity = newValue.second
        }
    }

    var body: some View {
        Canvas { context, size in
            renderer(&context, size, amplitudes, hoverOpacity)
        }
    }
}

private struct WaveformAmplitudes: VectorArithmetic {
    var values: [Double]

    static let zero = WaveformAmplitudes(values: [])

    static func + (lhs: Self, rhs: Self) -> Self {
        combine(lhs, rhs, +)
    }

    static func - (lhs: Self, rhs: Self) -> Self {
        combine(lhs, rhs, -)
    }

    mutating func scale(by rhs: Double) {
        values = values.map { $0 * rhs }
    }

    var magnitudeSquared: Double {
        values.reduce(0) { $0 + $1 * $1 }
    }

    private static func combine(
        _ lhs: Self, _ rhs: Self, _ operation: (Double, Double) -> Double
    ) -> Self {
        // Zero padding also handles changes in bar count when the window resizes.
        Self(values: (0..<max(lhs.values.count, rhs.values.count)).map { index in
            operation(
                index < lhs.values.count ? lhs.values[index] : 0,
                index < rhs.values.count ? rhs.values[index] : 0
            )
        })
    }
}

// Each view retains a small palette across animation frames. Key by resolved
// CGColor and appearance so color and highlight changes get fresh shading.
private final class WaveformGradientCache {
    private var entries: [(color: CGColor, isDark: Bool, gradient: CGGradient)] = []

    func gradient(for color: CGColor, isDark: Bool) -> CGGradient? {
        if let entry = entries.first(where: { $0.color == color && $0.isDark == isDark }) {
            return entry.gradient
        }
        guard let gradient = makeGradient(for: color, isDark: isDark) else { return nil }
        if entries.count == 8 {
            entries.removeFirst()
        }
        entries.append((color, isDark, gradient))
        return gradient
    }

    private func makeGradient(for color: CGColor, isDark: Bool) -> CGGradient? {
        let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!
        guard let components = color.converted(
            to: colorSpace, intent: .relativeColorimetric, options: nil
        )?.components, components.count == 4 else { return nil }

        let base = WaveformOKLab(linearRGB: SIMD3(
            Double(components[0]), Double(components[1]), Double(components[2])
        )).value
        // Build the shaded stops and interpolate them in OKLab, including
        // the white crest. Keep alpha constant throughout the surface.
        let profile: [(location: CGFloat, brightness: CGFloat, highlight: CGFloat)] = [
            (0,    0.98, 0.08),
            (0.08, 1,    0.30),
            (0.24, 0.98, 0.12),
            (1,    0.87, 0.03)
        ]
        let stops = profile.map { stop in
            // Keep a subtle crest on light backgrounds without a white stripe.
            let highlight = stop.highlight * (isDark ? 1 : 0.25)
            return base * Double(stop.brightness * (1 - highlight))
                + SIMD3<Double>(Double(highlight), 0, 0)
        }
        // Core Graphics interpolates in RGB. Sample the OKLab curve densely
        // and include the exact profile stops to preserve each crest.
        let locations = Array(Set((0...64).map { CGFloat($0) / 64 }
            + profile.map(\.location))).sorted()
        let colors = locations.map { fraction in
            let upperIndex = profile.firstIndex { $0.location > fraction }
                ?? (profile.count - 1)
            let lower = profile[upperIndex - 1]
            let upper = profile[upperIndex]
            let t = (fraction - lower.location) / (upper.location - lower.location)
            let eased = t * t * (3 - 2 * t)
            let lab = stops[upperIndex - 1]
                + (stops[upperIndex] - stops[upperIndex - 1]) * Double(eased)
            let rgb = WaveformOKLab(value: lab).linearRGB
            return CGColor(colorSpace: colorSpace, components: [
                CGFloat(min(max(rgb.x, 0), 1)),
                CGFloat(min(max(rgb.y, 0), 1)),
                CGFloat(min(max(rgb.z, 0), 1)),
                components[3]
            ])!
        }
        return CGGradient(
            colorsSpace: colorSpace, colors: colors as CFArray, locations: locations
        )

    }
}

// OKLab conversion matrices:
// https://bottosson.github.io/posts/oklab/#converting-from-linear-srgb-to-oklab
private struct WaveformOKLab {
    let value: SIMD3<Double>

    init(value: SIMD3<Double>) {
        self.value = value
    }

    init(linearRGB rgb: SIMD3<Double>) {
        let l = cbrt(0.4122214708 * rgb.x + 0.5363325363 * rgb.y + 0.0514459929 * rgb.z)
        let m = cbrt(0.2119034982 * rgb.x + 0.6806995451 * rgb.y + 0.1073969566 * rgb.z)
        let s = cbrt(0.0883024619 * rgb.x + 0.2817188376 * rgb.y + 0.6299787005 * rgb.z)
        value = SIMD3(
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    var linearRGB: SIMD3<Double> {
        let roots = SIMD3(
            value.x + 0.3963377774 * value.y + 0.2158037573 * value.z,
            value.x - 0.1055613458 * value.y - 0.0638541728 * value.z,
            value.x - 0.0894841775 * value.y - 1.2914855480 * value.z
        )
        let cubes = roots * roots * roots
        return SIMD3(
            4.0767416621 * cubes.x - 3.3077115913 * cubes.y + 0.2309699292 * cubes.z,
            -1.2684380046 * cubes.x + 2.6097574011 * cubes.y - 0.3413193965 * cubes.z,
            -0.0041960863 * cubes.x - 0.7034186147 * cubes.y + 1.7076147010 * cubes.z
        )
    }
}

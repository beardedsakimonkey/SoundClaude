import AppKit
import SwiftUI

struct TrackWaveformView: View {
    enum Layout {
        case detail
        case compact

        var height: CGFloat { self == .compact ? 60 : 96 }
    }

    let track: SoundCloudTrack
    let model: AppModel
    let layout: Layout
    let invertsBarsOnTrackChange: Bool
    let onPlayTrack: ((SoundCloudTrack) async -> Void)?

    private let playback: PlaybackController
    @State private var waveform: SoundCloudWaveform?
    @State private var waveformTrackURN: String?
    @State private var barDirection: Double = 1
    @State private var errorMessage: String?
    @State private var artworkAccent: ArtworkAccent?
    @State private var accentArtworkURL: URL?
    @State private var hoverFraction: Double = 0
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    init(
        track: SoundCloudTrack,
        model: AppModel,
        layout: Layout = .detail,
        invertsBarsOnTrackChange: Bool = false,
        onPlayTrack: ((SoundCloudTrack) async -> Void)? = nil
    ) {
        self.track = track
        self.model = model
        self.layout = layout
        self.invertsBarsOnTrackChange = invertsBarsOnTrackChange
        self.onPlayTrack = onPlayTrack
        playback = model.playback
        _waveform = State(initialValue: model.cachedWaveform(for: track))
        _waveformTrackURN = State(
            initialValue: model.cachedWaveform(for: track) == nil ? nil : track.urn
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if layout == .compact {
                    waveformView(waveform)
                        .overlay {
                            if waveform == nil {
                                Text(errorMessage ?? "Loading waveform…")
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
                        .frame(maxWidth: .infinity, minHeight: 96)
                } else {
                    ProgressView("Loading waveform")
                        .frame(maxWidth: .infinity, minHeight: 96)
                }
            }
        }
        .task(id: [track.urn, track.waveformURL?.absoluteString ?? ""]) {
            await load()
        }
        .task(id: track.artworkURL) {
            artworkAccent = nil
            accentArtworkURL = nil
            guard let url = track.artworkURL,
                  let accent = try? await model.artworkLoader.accentColor(for: url),
                  !Task.isCancelled else { return }
            artworkAccent = accent
            accentArtworkURL = url
        }
    }

    private func waveformView(_ waveform: SoundCloudWaveform?) -> some View {
        VStack(spacing: 4) {
            GeometryReader { proxy in
                let amplitudes = barAmplitudes(waveform, width: proxy.size.width)
                WaveformAnimatedCanvas(
                    amplitudes: amplitudes,
                    hoverOpacity: isHovering ? 1 : 0
                ) { context, size, amplitudes, hoverOpacity in
                    guard size.width > 0, size.height > 0 else { return }
                    let scale = context.environment.displayScale
                    guard let bitmap = CGContext(
                        data: nil,
                        width: Int(ceil(size.width * scale)),
                        height: Int(ceil(size.height * scale)),
                        bitsPerComponent: 8,
                        bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    ) else { return }
                    bitmap.scaleBy(x: scale, y: scale)
                    let path = waveformPath(amplitudes, size: size)
                    let background = Color.secondary.opacity(0.3)
                        .resolve(in: context.environment).cgColor
                    let color = progressColor.resolve(in: context.environment).cgColor
                    let highlight = Color.white.opacity(0.6)
                        .resolve(in: context.environment).cgColor
                    let progress = progress

                    // Rasterize into a bitmap: Canvas's Core Graphics proxy can
                    // still change path edges when unrelated hover fills change.
                    bitmap.addPath(path)
                    bitmap.clip()
                    bitmap.beginTransparencyLayer(auxiliaryInfo: nil)
                    // Only the bar outline needs antialiasing. Keep the color
                    // boundaries from accumulating partial pixel coverage.
                    bitmap.setShouldAntialias(false)

                    fillGradient(background, in: bitmap, rect: CGRect(origin: .zero, size: size))
                    fillGradient(color, in: bitmap, rect: CGRect(
                        x: 0, y: 0,
                        width: size.width * progress,
                        height: size.height
                    ))

                    if hoverOpacity > 0 {
                        let hoverRegion = CGRect(
                            x: size.width * min(progress, hoverFraction),
                            y: 0,
                            width: size.width * abs(hoverFraction - progress),
                            height: size.height
                        )
                        bitmap.saveGState()
                        bitmap.setAlpha(hoverOpacity)
                        bitmap.beginTransparencyLayer(auxiliaryInfo: nil)
                        fillGradient(color, in: bitmap, rect: hoverRegion)
                        fillGradient(highlight, in: bitmap, rect: hoverRegion)
                        bitmap.endTransparencyLayer()
                        bitmap.restoreGState()
                    }
                    bitmap.endTransparencyLayer()
                    guard let image = bitmap.makeImage() else { return }
                    // Preserve the bitmap's pixel size, including any fractional
                    // layout padding, instead of stretching it to the view bounds.
                    context.draw(
                        Image(decorative: image, scale: scale),
                        at: .zero,
                        anchor: .topLeading
                    )
                }
                // Resampling during window resizing must not start or extend a spring.
                .animation(nil, value: proxy.size)
                .animation(
                    reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.3),
                    value: waveform
                )
                .animation(
                    reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.3),
                    value: barDirection
                )
                .animation(.easeInOut(duration: 0.15), value: isHovering)
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
                    isCurrentTrack
                        ? "Click or drag to seek."
                        : "Click to play from this position."
                )
            }
            .frame(height: layout.height)

            if layout == .detail {
                HStack {
                    Text(format(seconds: displayedCurrentTime))
                    Spacer()
                    Text(format(seconds: displayedDuration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
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
        .accessibilityLabel("Track waveform")
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

    private func fillGradient(_ color: CGColor, in bitmap: CGContext, rect: CGRect) {
        let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!
        guard let components = color.converted(
            to: colorSpace, intent: .relativeColorimetric, options: nil
        )?.components, components.count == 4 else { return }

        // For a fade toward black, scaling all OKLab coordinates by k is
        // equivalent to scaling linear RGB by k³. This preserves hue and stays
        // in gamut without a full matrix conversion. OKLab definition:
        // https://bottosson.github.io/posts/oklab/#converting-from-linear-srgb-to-oklab
        let locations = (0...32).map { CGFloat($0) / 32 }
        let colors = locations.map { fraction in
            let brightness = 1 - 0.4 * fraction
            let factor = brightness * brightness * brightness
            return CGColor(colorSpace: colorSpace, components: [
                components[0] * factor,
                components[1] * factor,
                components[2] * factor,
                components[3]
            ])!
        }
        guard let gradient = CGGradient(
            colorsSpace: colorSpace, colors: colors as CFArray, locations: locations
        ) else { return }

        bitmap.saveGState()
        bitmap.clip(to: rect)
        // Bitmap coordinates start at the bottom. Sample the OKLab fade with
        // closely spaced stops because Core Graphics interpolates in RGB.
        bitmap.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: rect.maxY),
            end: CGPoint(x: 0, y: rect.minY),
            options: []
        )
        bitmap.restoreGState()
    }

    private var progressColor: Color {
        let blue = NSColor.systemBlue.usingColorSpace(.sRGB)!
        let fallback = ArtworkAccent(
            red: blue.redComponent, green: blue.greenComponent, blue: blue.blueComponent
        )
        let accent = accentArtworkURL == track.artworkURL
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
        playback.currentTrack?.urn == track.urn
    }

    private var displayedCurrentTime: Double {
        isCurrentTrack ? playback.currentTime : 0
    }

    private var displayedDuration: Double {
        if isCurrentTrack, playback.duration > 0 {
            return playback.duration
        }
        return Double(track.durationMilliseconds) / 1_000
    }

    private var progress: Double {
        guard isCurrentTrack, displayedDuration > 0 else { return 0 }
        return min(max(displayedCurrentTime / displayedDuration, 0), 1)
    }

    private func barAmplitudes(
        _ waveform: SoundCloudWaveform?,
        width: CGFloat
    ) -> WaveformAmplitudes {
        // Keep the same bars for every track, including the loading state.
        let barCount = max(Int(width / 4), 1)
        guard let waveform, !waveform.samples.isEmpty, waveform.height > 0 else {
            return WaveformAmplitudes(values: Array(repeating: 0, count: barCount))
        }
        return WaveformAmplitudes(values: (0..<barCount).map { index in
            let lowerBound = index * waveform.samples.count / barCount
            let upperBound = max(
                (index + 1) * waveform.samples.count / barCount,
                lowerBound + 1
            )
            let sample = waveform.samples[lowerBound..<upperBound].max() ?? 0
            return min(max(Double(sample) / Double(waveform.height), 0), 1)
                * barDirection
        })
    }

    private func waveformPath(
        _ amplitudes: WaveformAmplitudes,
        size: CGSize
    ) -> CGPath {
        let barWidth: CGFloat = 2
        let step: CGFloat = 4
        let path = CGMutablePath()

        for (index, amplitude) in amplitudes.values.enumerated() {
            // Signed amplitudes let the endpoints cross at the center. Take the
            // absolute value only when drawing, after spring interpolation.
            let height = max(CGFloat(abs(amplitude)) * (size.height - 4), 2)
            let rect = CGRect(
                x: CGFloat(index) * step,
                y: (size.height - height) / 2,
                width: barWidth,
                height: height
            )
            path.addRoundedRect(
                in: rect,
                cornerWidth: 1,
                cornerHeight: 1
            )
        }
        return path
    }

    private func fraction(at xPosition: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(max(Double(xPosition / width), 0), 1)
    }

    private func seek(to fraction: Double) {
        let target = fraction * displayedDuration
        if isCurrentTrack {
            playback.seek(to: target)
            return
        }

        Task { @MainActor in
            if let onPlayTrack {
                await onPlayTrack(track)
            } else {
                await model.play(track)
            }
            guard playback.currentTrack?.urn == track.urn else { return }
            playback.seek(to: target)
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
        if invertsBarsOnTrackChange,
           let waveformTrackURN, waveformTrackURN != track.urn {
            barDirection *= -1
        }
        waveformTrackURN = track.urn
        waveform = loadedWaveform
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

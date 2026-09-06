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

    private let playback: PlaybackController
    @State private var waveform: SoundCloudWaveform?
    @State private var errorMessage: String?
    @State private var artworkAccent: ArtworkAccent?
    @State private var accentArtworkURL: URL?
    @State private var hoverFraction: Double = 0
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    init(
        track: SoundCloudTrack,
        model: AppModel,
        layout: Layout = .detail
    ) {
        self.track = track
        self.model = model
        self.layout = layout
        playback = model.playback
        _waveform = State(initialValue: model.cachedWaveform(for: track))
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
        .task(id: track.waveformURL) {
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
                HoverAnimatedCanvas(hoverOpacity: isHovering ? 1 : 0) { context, size, hoverOpacity in
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
                    let path = waveform.map { waveformPath($0, size: size) }
                        ?? CGPath(roundedRect: CGRect(
                            x: 0, y: (size.height - 2) / 2,
                            width: size.width, height: 2
                        ), cornerWidth: 1, cornerHeight: 1, transform: nil)
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

                    bitmap.setFillColor(background)
                    bitmap.fill(CGRect(origin: .zero, size: size))
                    bitmap.setFillColor(color)
                    bitmap.fill(CGRect(
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
                        bitmap.fill(hoverRegion)
                        bitmap.setFillColor(highlight)
                        bitmap.fill(hoverRegion)
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

    private func waveformPath(
        _ waveform: SoundCloudWaveform,
        size: CGSize
    ) -> CGPath {
        let barWidth: CGFloat = 2
        let spacing: CGFloat = 2
        let step = barWidth + spacing
        let barCount = max(min(Int(size.width / step), waveform.samples.count), 1)
        let maximumHeight = CGFloat(waveform.height)
        let path = CGMutablePath()

        for index in 0..<barCount {
            let lowerBound = index * waveform.samples.count / barCount
            let upperBound = max(
                (index + 1) * waveform.samples.count / barCount,
                lowerBound + 1
            )
            let sample = waveform.samples[lowerBound..<upperBound].max() ?? 0
            let amplitude = min(CGFloat(sample) / maximumHeight, 1)
            let height = max(amplitude * (size.height - 4), 2)
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
            await model.play(track)
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
            waveform = cachedWaveform
            errorMessage = nil
            return
        }

        waveform = nil
        errorMessage = nil
        do {
            let loadedWaveform = try await model.waveform(for: track)
            guard !Task.isCancelled else { return }
            waveform = loadedWaveform
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "Waveform unavailable"
        }
    }
}

// Canvas drawing does not interpolate its inputs without an animatable view.
private struct HoverAnimatedCanvas: View, Animatable {
    var hoverOpacity: Double
    var renderer: (inout GraphicsContext, CGSize, Double) -> Void

    var animatableData: Double {
        get { hoverOpacity }
        set { hoverOpacity = newValue }
    }

    var body: some View {
        Canvas { context, size in
            renderer(&context, size, hoverOpacity)
        }
    }
}

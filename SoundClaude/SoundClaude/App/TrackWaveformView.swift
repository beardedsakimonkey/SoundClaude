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
                Canvas { context, size in
                    let path = waveform.map { waveformPath($0, size: size) }
                        ?? Path(roundedRect: CGRect(
                            x: 0, y: (size.height - 2) / 2,
                            width: size.width, height: 2
                        ), cornerRadius: 1)
                    context.fill(
                        path,
                        with: .color(.secondary.opacity(0.3))
                    )

                    var playedContext = context
                    playedContext.clip(
                        to: Path(
                            CGRect(
                                x: 0,
                                y: 0,
                                width: size.width * progress,
                                height: size.height
                            )
                        )
                    )
                    playedContext.fill(path, with: .color(progressColor))
                }
                .contentShape(Rectangle())
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
    ) -> Path {
        let barWidth: CGFloat = 2
        let spacing: CGFloat = 2
        let step = barWidth + spacing
        let barCount = max(min(Int(size.width / step), waveform.samples.count), 1)
        let maximumHeight = CGFloat(waveform.height)
        var path = Path()

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
                cornerSize: CGSize(width: 1, height: 1)
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

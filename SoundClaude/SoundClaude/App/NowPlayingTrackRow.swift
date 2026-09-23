import SwiftUI

struct NowPlayingTrackRow: View {
    let track: SoundCloudTrack?
    let isPlaying: Bool
    let isLoading: Bool
    let analyzer: SpectrumAnalyzer
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    var appearanceDelay: Duration = .zero

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHoveringTrackTitle = false
    @State private var readyTrackURN: String?

    private var visibleTrack: SoundCloudTrack? {
        readyTrackURN == track?.urn || appearanceDelay == .zero || reduceMotion ? track : nil
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Text(" ")
                .hidden()
                .accessibilityHidden(true)
            if let track = visibleTrack {
                HStack(spacing: 10) {
                    SpinningRecordIcon(isPlaying: isPlaying && !isLoading)
                        .foregroundStyle((colorScheme == .dark ? Color.white : Color.black).opacity(0.8))
                        .fixedSize()
                        .accessibilityLabel(isLoading ? "Loading" : isPlaying ? "Now playing" : "Paused")
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Button {
                            onSelectTrack(track)
                        } label: {
                            Text(track.title)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .underline(isHoveringTrackTitle)
                        }
                        .buttonStyle(.plain)
                        .onContentHover { isHoveringTrackTitle = $0 }
                        .help("View track: \(track.title)")
                        .accessibilityLabel("View track: \(track.title)")
                        Text("by")
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        ArtistLink(artist: track.artist, onSelect: onSelectArtist)
                    }
                    .foregroundStyle(.primary)
                    .opacity(0.9)
                }
                .geometryGroup()
                .id(track.urn)
                .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .font(.title2)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.3),
            value: visibleTrack?.urn
        )
        .task(id: track?.urn) {
            readyTrackURN = nil
            isHoveringTrackTitle = false
            guard let track else { return }
            // Delay the row's appearance until the waveform animation has started.
            if !reduceMotion, appearanceDelay > .zero {
                do {
                    try await Task.sleep(for: appearanceDelay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            readyTrackURN = track.urn
        }
    }
}

private struct SpinningRecordIcon: View {
    let isPlaying: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.contentAnimationsPaused) private var contentAnimationsPaused
    @State private var motion = RecordMotion()
    @State private var isCoasting = false

    private var isSpinning: Bool {
        isPlaying && !reduceMotion && !contentAnimationsPaused
    }

    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1.0 / 30,
            paused: reduceMotion || contentAnimationsPaused || (!isSpinning && !isCoasting)
        )) { context in
            let angle = motion.value(at: context.date).angle

            ZStack {
                Circle().strokeBorder(lineWidth: 1.5)
                ForEach([0.0, 180.0], id: \.self) { rotation in
                    ForEach([14.0, 18.0], id: \.self) { diameter in
                        Circle()
                            .trim(from: 0.03, to: 0.23)
                            .stroke(style: StrokeStyle(lineWidth: 1, lineCap: .round))
                            .frame(width: diameter, height: diameter)
                            .rotationEffect(.degrees(rotation))
                    }
                }
                Circle().strokeBorder(lineWidth: 2.5)
                    .frame(width: 7, height: 7)
            }
            .frame(width: 22, height: 22)
            .rotationEffect(.degrees(angle))
            .animation(nil, value: angle)
        }
        .task(id: [isPlaying, reduceMotion, contentAnimationsPaused]) {
            let now = Date.now
            let current = motion.value(at: now)
            let stopImmediately = reduceMotion || contentAnimationsPaused
            motion = RecordMotion(
                angle: current.angle.truncatingRemainder(dividingBy: 360),
                speed: stopImmediately ? 0 : current.speed,
                targetSpeed: isSpinning ? 120 : 0,
                startedAt: now
            )
            isCoasting = !isSpinning && motion.speed > 0
            guard isCoasting else { return }
            do {
                try await Task.sleep(for: .seconds(RecordMotion.duration))
            } catch {
                return
            }
            isCoasting = false
        }
        .accessibilityElement(children: .ignore)
    }
}

private struct RecordMotion {
    static let duration: TimeInterval = 0.6

    var angle = 0.0
    var speed = 0.0
    var targetSpeed = 0.0
    var startedAt = Date.now

    func value(at date: Date) -> (angle: Double, speed: Double) {
        let elapsed = max(0, date.timeIntervalSince(startedAt))
        let progress = min(elapsed / Self.duration, 1)
        let easedProgress = progress * progress * (3 - 2 * progress)
        // Integrate the eased speed so rotation stays continuous during interruptions.
        let easedDistance = progress * progress * progress * (1 - progress / 2)
        let rampAngle = Self.duration * (speed * progress + (targetSpeed - speed) * easedDistance)
        let steadyAngle = targetSpeed * max(0, elapsed - Self.duration)
        return (angle + rampAngle + steadyAngle, speed + (targetSpeed - speed) * easedProgress)
    }
}

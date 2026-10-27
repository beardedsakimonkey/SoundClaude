import SwiftUI

struct TrackPlaybackIndicator: View {
    let isPlaying: Bool
    let isLoading: Bool
    var speed: Float = 1
    var color: Color = .accentColor

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.contentAnimationsPaused) private var contentAnimationsPaused

    var body: some View {
        let showsBars = isPlaying && !isLoading
        let shouldAnimate = showsBars && !reduceMotion && !contentAnimationsPaused
        return TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !shouldAnimate)) { context in
            PlaybackIndicatorBars(
                growth: showsBars ? 1 : 0,
                cycle: PlaybackIndicatorClock.cycle(at: context.date, speed: Double(speed)),
                animated: shouldAnimate
            )
            .fill(color)
            .frame(width: 10, height: 9)
            .animation(
                reduceMotion || contentAnimationsPaused ? nil : .easeInOut(duration: 0.3),
                value: showsBars
            )
        }
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isPlaying ? "Now playing" : "Paused")
    }
}

/// Shared so every indicator stays in step, and rebased on speed changes so
/// the bars keep their current position instead of jumping.
private enum PlaybackIndicatorClock {
    private static let duration = 1.5
    private static var anchorDate = Date(timeIntervalSinceReferenceDate: 0)
    private static var anchorCycle = 0.0
    private static var speed = 1.0

    static func cycle(at date: Date, speed newSpeed: Double) -> Double {
        if newSpeed != speed {
            anchorCycle = cycle(at: date)
            anchorDate = date
            speed = newSpeed
        }
        return cycle(at: date)
    }

    private static func cycle(at date: Date) -> Double {
        let cycle = (anchorCycle + date.timeIntervalSince(anchorDate) * speed / duration)
            .truncatingRemainder(dividingBy: 1)
        return cycle < 0 ? cycle + 1 : cycle
    }
}

private struct PlaybackIndicatorBars: Shape {
    private static let levels: [[CGFloat]] = [
        [0.12, 1.00, 0.30, 0.55],
        [0.18, 0.94, 0.28, 0.50],
        [0.15, 1.00, 0.35, 0.60]
    ]

    var growth: CGFloat
    let cycle: Double
    let animated: Bool

    var animatableData: CGFloat {
        get { growth }
        set { growth = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for index in 0..<3 {
            let levels = Self.levels[index]
            let phase = (cycle + Double(index) / 3).truncatingRemainder(dividingBy: 1)
            let position = phase * Double(levels.count)
            let step = Int(position)
            let blend = CGFloat((1 - cos((position - Double(step)) * .pi)) / 2)
            let start = levels[step]
            let end = levels[(step + 1) % levels.count]
            let level = animated ? (start + (end - start) * blend) * 7 : (index == 1 ? 7 : 3)
            let height = 2 + level * growth
            path.addPath(
                UnevenRoundedRectangle(topLeadingRadius: 1, topTrailingRadius: 1)
                    .path(in: CGRect(x: rect.minX + CGFloat(index) * 4, y: rect.maxY - height, width: 2, height: height))
            )
        }
        return path
    }
}

/// Reserve space once per selection change, then animate only the title's
/// drawing offset. The layout has no animatable data, so its width changes
/// immediately without disabling the title's movement animation.
struct TrackPlaybackTitleInset: ViewModifier {
    let inset: CGFloat

    func body(content: Content) -> some View {
        PlaybackTitleLayout(inset: inset) {
            content
        }
        .offset(x: inset)
    }
}

private struct PlaybackTitleLayout: Layout {
    let inset: CGFloat

    private func titleProposal(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: proposal.width.map { max(0, $0 - inset) }, height: proposal.height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews[0].sizeThatFits(titleProposal(proposal))
        return CGSize(width: size.width + inset, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: titleProposal(proposal))
    }
}

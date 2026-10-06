import SwiftUI

struct TrackPlaybackIndicator: View {
    let isPlaying: Bool
    let isLoading: Bool
    var color: Color = .accentColor

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.contentAnimationsPaused) private var contentAnimationsPaused

    var body: some View {
        let showsBars = isPlaying && !isLoading
        let shouldAnimate = showsBars && !reduceMotion && !contentAnimationsPaused
        return TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !shouldAnimate)) { context in
            PlaybackIndicatorBars(
                growth: showsBars ? 1 : 0,
                date: context.date,
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

private struct PlaybackIndicatorBars: Shape {
    var growth: CGFloat
    let date: Date
    let animated: Bool

    var animatableData: CGFloat {
        get { growth }
        set { growth = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for index in 0..<3 {
            let time = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2)
            let phase = time / 1.2 * 2 * .pi + Double(index) * 2 * .pi / 3
            let level = animated ? CGFloat((sin(phase) + 1) / 2) * 7 : (index == 1 ? 7 : 3)
            let height = 2 + level * growth
            path.addRoundedRect(
                in: CGRect(x: rect.minX + CGFloat(index) * 4, y: rect.maxY - height, width: 2, height: height),
                cornerSize: CGSize(width: 1, height: 1)
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

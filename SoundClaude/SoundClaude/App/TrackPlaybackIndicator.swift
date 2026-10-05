import SwiftUI

struct TrackPlaybackIndicator: View {
    let isPlaying: Bool
    let isLoading: Bool
    let analyzer: SpectrumAnalyzer
    var color: Color = .accentColor
    // Set to false to compare with the audio-driven indicator.
    var useFakePlaybackIndicator = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.contentAnimationsPaused) private var contentAnimationsPaused
    @State private var levels: [Float] = [0, 0, 0]

    private var isAnimating: Bool { (isPlaying || isLoading) && !reduceMotion && !contentAnimationsPaused }

    var body: some View {
        Group {
            if useFakePlaybackIndicator {
                fakeIndicator
            } else {
                audioIndicator
            }
        }
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(!useFakePlaybackIndicator && isLoading ? "Loading" : isPlaying ? "Now playing" : "Paused")
    }

    private var fakeIndicator: some View {
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
    }

    private var audioIndicator: some View {
        TimelineView(.animation(paused: !isAnimating)) { context in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(color)
                        .frame(width: 2, height: isLoading ? 2 : 2 + CGFloat(levels[index]) * 7)
                        .animation(
                            reduceMotion || contentAnimationsPaused || isLoading ? nil : .easeOut(duration: 0.2),
                            value: levels[index]
                        )
                        .offset(y: loadingOffset(for: index, at: context.date))
                }
            }
            .frame(width: 10, height: 9, alignment: .bottom)
            .onChange(of: context.date) { _, _ in
                updateLevels()
            }
        }
        .onAppear { updateLevels() }
        .onChange(of: isPlaying) { _, _ in updateLevels() }
        .onChange(of: isAnimating) { _, _ in updateLevels() }
        .onChange(of: isLoading) { _, _ in updateLevels() }
    }

    private func loadingOffset(for index: Int, at date: Date) -> CGFloat {
        guard isLoading, !reduceMotion else { return 0 }
        let cycleDuration = 1.5
        let time = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: cycleDuration)
        let phase = -Double(index) * 0.15
        let bounce = max(0, sin((time + phase) / cycleDuration * 2 * .pi))
        return -3 * CGFloat(bounce * bounce)
    }

    private func updateLevels() {
        guard isPlaying else {
            levels = [0, 0, 0]
            return
        }
        guard isAnimating, !isLoading, let snapshot = analyzer.playbackIndicatorLevels() else { return }
        levels = snapshot
    }
}

// Animate the multiplier inside fixed bounds to keep the title layout stable.
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

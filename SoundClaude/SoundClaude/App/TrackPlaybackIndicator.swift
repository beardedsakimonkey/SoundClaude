import SwiftUI

struct TrackPlaybackIndicator: View {
    let isPlaying: Bool
    let isLoading: Bool
    let analyzer: SpectrumAnalyzer
    var color: Color = .accentColor

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.contentAnimationsPaused) private var contentAnimationsPaused
    @State private var levels: [Float] = [0, 0, 0]

    private var isAnimating: Bool { (isPlaying || isLoading) && !reduceMotion && !contentAnimationsPaused }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimating)) { context in
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
        .opacity(isPlaying || isLoading ? 1 : 0.4)
        .animation(
            reduceMotion || contentAnimationsPaused ? nil : .easeInOut(duration: 0.2),
            value: isPlaying || isLoading
        )
        .onAppear { updateLevels() }
        .onChange(of: isPlaying) { _, _ in updateLevels() }
        .onChange(of: isAnimating) { _, _ in updateLevels() }
        .onChange(of: isLoading) { _, _ in updateLevels() }
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isLoading ? "Loading" : isPlaying ? "Now playing" : "Paused")
    }

    private func loadingOffset(for index: Int, at date: Date) -> CGFloat {
        guard isLoading, !reduceMotion else { return 0 }
        let bounceDuration = 0.9
        let pauseDuration = 0.6
        let cycleTime = (date.timeIntervalSinceReferenceDate - Double(index) * 0.15)
            .truncatingRemainder(dividingBy: bounceDuration + pauseDuration)
        guard cycleTime < bounceDuration else { return 0 }
        let phase = cycleTime / bounceDuration
        return -1.5 * CGFloat(1 - cos(phase * 2 * .pi))
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

/// Recompute the title and badge layout from one interpolated inset each frame.
/// Disable child interpolation only when the inset changes. Row movement must
/// keep its animation when the inset stays the same.
struct TrackPlaybackTitleInset: AnimatableModifier {
    var inset: CGFloat

    var animatableData: CGFloat {
        get { inset }
        set { inset = newValue }
    }

    func body(content: Content) -> some View {
        content
            .padding(.leading, inset)
            .transaction(value: inset) { transaction in
                transaction.animation = nil
            }
    }
}

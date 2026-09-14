import SwiftUI

struct TrackPlaybackIndicator: View {
    let isPlaying: Bool
    let isLoading: Bool
    let analyzer: SpectrumAnalyzer

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var levels: [Float] = [0, 0, 0]

    private var isAnimating: Bool { (isPlaying || isLoading) && !reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimating)) { context in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<3) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.orange)
                        .frame(width: 2, height: isLoading ? 2 : 2 + CGFloat(levels[index]) * 7)
                        .offset(y: loadingOffset(for: index, at: context.date))
                        .animation(
                            reduceMotion || isLoading ? nil : .easeOut(duration: 0.2),
                            value: isLoading
                        )
                }
            }
            .frame(width: 10, height: 9, alignment: .center)
            .onChange(of: context.date) { _, _ in
                updateLevels()
            }
        }
        .onAppear { updateLevels() }
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
        guard isAnimating, !isLoading, let snapshot = analyzer.playbackIndicatorLevels() else { return }
        levels = snapshot
    }
}

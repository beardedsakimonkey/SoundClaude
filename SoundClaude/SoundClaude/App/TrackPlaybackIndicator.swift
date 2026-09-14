import SwiftUI

struct TrackPlaybackIndicator: View {
    let isPlaying: Bool
    let analyzer: SpectrumAnalyzer

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var levels: [Float] = [0, 0, 0]

    private var isAnimating: Bool { isPlaying && !reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimating)) { context in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<3) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.orange)
                        .frame(width: 2, height: 2 + CGFloat(levels[index]) * 7)
                }
            }
            .frame(width: 10, height: 9, alignment: .center)
            .onChange(of: context.date) { _, _ in
                updateLevels()
            }
        }
        .onAppear { updateLevels() }
        .onChange(of: isAnimating) { _, _ in updateLevels() }
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isPlaying ? "Now playing" : "Paused")
    }

    private func updateLevels() {
        guard isAnimating, let snapshot = analyzer.playbackIndicatorLevels() else { return }
        levels = snapshot
    }
}

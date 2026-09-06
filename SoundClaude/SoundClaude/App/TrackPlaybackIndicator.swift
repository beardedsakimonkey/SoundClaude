import SwiftUI

struct TrackPlaybackIndicator: View {
    let isPlaying: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animationTime: TimeInterval = 0
    @State private var previousFrame: Date?

    private var isAnimating: Bool { isPlaying && !reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimating)) { context in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.orange)
                        .frame(width: 2, height: barHeight(index))
                }
            }
            .frame(width: 10, height: 9, alignment: .bottom)
            .onChange(of: context.date) { _, date in
                guard isAnimating else { return }
                if let previousFrame {
                    animationTime += max(0, date.timeIntervalSince(previousFrame))
                }
                previousFrame = date
            }
        }
        .onChange(of: isAnimating) { _, _ in
            // Keep the last rendered heights and exclude time spent paused.
            previousFrame = nil
        }
        .onDisappear { previousFrame = nil }
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isPlaying ? "Now playing" : "Paused")
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let time = animationTime
        // Mix unrelated frequencies so the bars do not share a repeating beat.
        let speed = [sqrt(2.0), sqrt(3.0), sqrt(5.0)][index]
        let drift = [sqrt(7.0), sqrt(11.0), sqrt(13.0)][index] * 0.3
        let phase = Double(index) * 2.4
        let movement = 0.7 * sin(time * speed * 3.0 + phase)
            + 0.3 * sin(time * drift + phase * 1.7)
        return CGFloat(2 + (movement + 1) * 3.5)
    }
}

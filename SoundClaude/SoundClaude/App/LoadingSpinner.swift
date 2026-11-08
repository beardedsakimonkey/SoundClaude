import SwiftUI

struct LoadingSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    var body: some View {
        ProgressView()
            .opacity(isVisible ? 1 : 0)
            .onAppear {
                withAnimation(reduceMotion ? nil : .easeIn(duration: 0.3)) {
                    isVisible = true
                }
            }
            .onDisappear {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    isVisible = false
                }
            }
    }
}

extension View {
    /// Pulses opacity while content loads. Driven by the clock rather than a repeating
    /// animation, so every loading placeholder on screen pulses in phase.
    func loadingPulse(_ isPulsing: Bool, idleOpacity: Double = 1) -> some View {
        modifier(LoadingPulse(isPulsing: isPulsing, idleOpacity: idleOpacity))
    }
}

private struct LoadingPulse: ViewModifier {
    @Environment(\.contentAnimationsPaused) private var contentAnimationsPaused

    let isPulsing: Bool
    let idleOpacity: Double
    private let period: TimeInterval = 1.2

    func body(content: Content) -> some View {
        // Pause frame updates outside loading, and resume on every new load.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isPulsing || contentAnimationsPaused)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: period) / period
            content.opacity(isPulsing ? 0.35 + 0.4 * abs(sin(phase * .pi)) : idleOpacity)
        }
    }
}

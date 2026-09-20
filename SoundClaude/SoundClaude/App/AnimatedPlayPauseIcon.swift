import SwiftUI

struct AnimatedPlayPauseIcon: View {
    let isPlaybackActive: Bool
    let size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Image(systemName: isPlaybackActive ? "pause.fill" : "play.fill")
                .font(.system(size: size, weight: .semibold))
                .id(isPlaybackActive)
                .transition(reduceMotion ? .identity : .scale(scale: 0.01).combined(with: .opacity))
        }
        .animation(
            reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.6),
            value: isPlaybackActive
        )
    }
}

import SwiftUI

struct AnimatedPlayPauseIcon: View {
    let isPlaybackActive: Bool
    let size: CGFloat
    var animatesChange = true

    private let incoming = Animation.interpolatingSpring(mass: 2, stiffness: 300, damping: 30)
    private let outgoing = Animation.interpolatingSpring(mass: 1, stiffness: 845.74, damping: 58.1632)
    private let playFade = Animation.interpolatingSpring(mass: 2, stiffness: 300, damping: 50)

    var body: some View {
        ZStack {
            icon("play.fill", visible: !isPlaybackActive, fade: playFade)
            icon("pause.fill", visible: isPlaybackActive, fade: incoming)
        }
        .font(.system(size: size, weight: .semibold))
    }

    private func icon(_ name: String, visible: Bool, fade: Animation) -> some View {
        return Image(systemName: name)
            .scaleEffect(visible ? 1 : 0)
            .animation(animatesChange ? (visible ? incoming : outgoing) : nil, value: visible)
            .opacity(visible ? 1 : 0)
            .animation(animatesChange ? (visible ? fade : outgoing) : nil, value: visible)
    }
}

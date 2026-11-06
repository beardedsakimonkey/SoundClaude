import SwiftUI
import QuartzCore

struct AnimatedSkipIcon: NSViewRepresentable {
    let isBackward: Bool
    let trigger: Int
    let reduceMotion: Bool

    func makeNSView(context: Context) -> SkipIconView {
        let view = SkipIconView()
        view.lastTrigger = trigger
        return view
    }

    func updateNSView(_ view: SkipIconView, context: Context) {
        view.configure(isBackward: isBackward, reduceMotion: reduceMotion)
        if view.lastTrigger != trigger {
            view.lastTrigger = trigger
            if !reduceMotion { view.advance() }
        }
    }
}

final class SkipIconView: NSView {
    var lastTrigger = 0
    private let origin = CALayer()
    private let arrows = (0..<4).map { _ in CALayer() }
    private var incoming = 2
    private var trailing = 0
    private var leading = 1
    private var spare = 3
    private var state = 1
    private var isBackward = false

    private struct Spring {
        let mass: Double
        let stiffness: Double
        let damping: Double
        let duration: Double

        static let movement = Spring(mass: 2, stiffness: 300, damping: 30, duration: 0.99751)
        static let disappearance = Spring(mass: 1, stiffness: 845.74, damping: 58.1632, duration: 0.3175)
        static let softFade = Spring(mass: 2, stiffness: 300, damping: 50, duration: 0.8)
        static let fastFade = Spring(mass: 1, stiffness: 1311.13, damping: 72.4189, duration: 0.255)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(origin)
        for arrow in arrows {
            let shape = CAShapeLayer()
            shape.path = Self.trianglePath
            shape.bounds = CGRect(x: 0, y: 0, width: 47.9, height: 55.04)
            shape.position = CGPoint(x: 4, y: 0)
            arrow.addSublayer(shape)
            origin.addSublayer(arrow)
        }
        reset()
        updateTint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // The SwiftUI button handles the pointer and accessibility label.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        origin.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let scale = 12 / 55.04
        origin.transform = CATransform3DMakeScale(isBackward ? -scale : scale, scale, 1)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTint()
    }

    private func updateTint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for arrow in arrows {
                (arrow.sublayers?.first as? CAShapeLayer)?.fillColor = NSColor.labelColor.cgColor
            }
            CATransaction.commit()
        }
    }

    func configure(isBackward: Bool, reduceMotion: Bool) {
        if self.isBackward != isBackward {
            self.isBackward = isBackward
            needsLayout = true
        }
        if reduceMotion { reset() }
    }

    private func reset() {
        incoming = 2
        trailing = 0
        leading = 1
        spare = 3
        state = 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, arrow) in arrows.enumerated() {
            arrow.removeAllAnimations()
            arrow.position.x = [-26, 22, -50, 70][index]
            arrow.opacity = index < 2 ? 1 : 0
            arrow.transform = CATransform3DMakeScale(index < 2 ? 1 : 0, index < 2 ? 1 : 0, 1)
        }
        CATransaction.commit()
    }

    func advance() {
        state = state % 4 + 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        animate(arrows[trailing], "position.x", to: 22, spring: .movement)
        animate(arrows[leading], "position.x", to: 70, spring: .movement)
        animate(arrows[leading], "transform.scale.x", to: 0, spring: .disappearance)
        animate(arrows[leading], "transform.scale.y", to: 0, spring: .disappearance)
        animate(arrows[leading], "opacity", to: 0, spring: .disappearance)
        animate(arrows[incoming], "position.x", to: -26, spring: .movement)
        animate(arrows[incoming], "transform.scale.x", to: 1, spring: .movement)
        animate(arrows[incoming], "transform.scale.y", to: 1, spring: .movement)
        let fade: Spring = state == 2 ? .disappearance : state == 4 ? .fastFade : .softFade
        animate(arrows[incoming], "opacity", to: 1, spring: fade)
        animate(arrows[spare], "position.x", to: state == 1 ? -50 : -60, spring: .movement)
        CATransaction.commit()
        (incoming, trailing, leading, spare) = (spare, incoming, trailing, leading)
    }

    private func animate(_ layer: CALayer, _ key: String, to value: Double, spring: Spring) {
        // Continue from the displayed value when another click interrupts a spring.
        let from = (layer.presentation() ?? layer).value(forKeyPath: key)
        layer.setValue(value, forKeyPath: key)
        let animation = CASpringAnimation(keyPath: key)
        animation.fromValue = from
        animation.toValue = value
        animation.mass = spring.mass
        animation.stiffness = spring.stiffness
        animation.damping = spring.damping
        animation.initialVelocity = 0
        animation.duration = spring.duration
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        layer.add(animation, forKey: key)
    }

    private static var trianglePath: CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 49.05))
        path.addCurve(to: CGPoint(x: 5, y: 55.04), control1: CGPoint(x: 0, y: 52.94), control2: CGPoint(x: 2.29, y: 55.04))
        path.addCurve(to: CGPoint(x: 8.99, y: 53.74), control1: CGPoint(x: 6.42, y: 55.04), control2: CGPoint(x: 7.57, y: 54.58))
        path.addLine(to: CGPoint(x: 44.39, y: 32.72))
        path.addCurve(to: CGPoint(x: 47.9, y: 27.54), control1: CGPoint(x: 46.86, y: 31.25), control2: CGPoint(x: 47.9, y: 29.53))
        path.addCurve(to: CGPoint(x: 44.39, y: 22.32), control1: CGPoint(x: 47.9, y: 25.55), control2: CGPoint(x: 46.86, y: 23.79))
        path.addLine(to: CGPoint(x: 9, y: 1.3))
        path.addCurve(to: CGPoint(x: 5.01, y: 0), control1: CGPoint(x: 7.61, y: 0.46), control2: CGPoint(x: 6.43, y: 0))
        path.addCurve(to: CGPoint(x: 0.01, y: 5.99), control1: CGPoint(x: 2.3, y: 0), control2: CGPoint(x: 0.01, y: 2.1))
        path.addLine(to: CGPoint(x: 0.01, y: 49.05))
        path.closeSubpath()
        return path
    }
}

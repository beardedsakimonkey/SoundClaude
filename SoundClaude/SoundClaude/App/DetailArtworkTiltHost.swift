import AppKit
import SwiftUI

enum DetailArtworkTiltMotion {
    // Degrees the artwork leans away under the pointer at its edge.
    static let angle = 14.0
    // Viewing distance as a multiple of the artwork's size; smaller exaggerates the perspective.
    static let viewingDistance = 1.9

    // Fast and critically damped, so the lean stays with the pointer and only the entry is eased.
    static let tracking = Spring(response: 0.15, dampingFraction: 1)
    static let settling = Spring(response: 0.35 * 1.5, dampingFraction: 0.75)

    struct Spring {
        let response: Double
        let dampingFraction: Double
    }
}

/// Hosts the artwork in its own hosting view and leans that view's layer away from the pointer.
///
/// Animating the tilt in SwiftUI re-renders the whole window on the main thread every frame,
/// which stutters on a busy page. Here a frame moves one layer and re-renders the glass, whose
/// highlight follows the lean, within the small hosting view.
struct DetailArtworkTiltHost<Content: View>: NSViewRepresentable {
    let artworkSize: CGFloat
    let isTilting: Bool
    @ViewBuilder let content: Content

    func makeNSView(context: Context) -> DetailArtworkTiltView {
        DetailArtworkTiltView(artworkSize: artworkSize)
    }

    func updateNSView(_ view: DetailArtworkTiltView, context: Context) {
        // The hosting view starts from an empty environment, so hand it the page's.
        // The tilt goes innermost: replacing the whole environment would otherwise drop it.
        view.setContent(AnyView(
            content
                .environment(\.playerArtworkGlassTilt, view.glassTilt)
                .environment(\.self, context.environment)
        ))
        view.isTilting = isTilting
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: DetailArtworkTiltView, context: Context
    ) -> CGSize? {
        DetailArtworkTiltView.footprint(artworkSize: artworkSize)
    }
}

// Replacing a hosting view's root view applies the change without animation, which would drop
// the artwork's track-change transition. A change observed inside the hosted hierarchy animates.
@Observable
private final class DetailArtworkHostedContent {
    var view = AnyView(EmptyView())
}

private struct DetailArtworkHostedRoot: View {
    let content: DetailArtworkHostedContent

    var body: some View { content.view }
}

private final class DetailArtworkHostingView: NSHostingView<DetailArtworkHostedRoot> {
    // Nothing in here scrolls; hand the wheel straight to the page.
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

final class DetailArtworkTiltView: NSView {
    // Room around the footprint for the shadows and the reflection's tail.
    private static let sideBleed: CGFloat = 64
    private static let bottomBleed: CGFloat = 96

    static func footprint(artworkSize: CGFloat) -> CGSize {
        CGSize(
            width: artworkSize,
            height: artworkSize + DetailArtworkView.reflectionSpacing + DetailArtworkView.reflectionSlotHeight
        )
    }

    private let artworkSize: CGFloat
    private let hostedContent = DetailArtworkHostedContent()
    private let host: DetailArtworkHostingView

    var isTilting = false {
        didSet {
            guard isTilting != oldValue else { return }
            if isTilting { readPointer() }
            startAnimating()
        }
    }

    // Tells the artwork's glass how far it leans, so its highlight follows.
    let glassTilt = PlayerArtworkGlassTilt()

    // Pointer offset from the artwork's center, -1...1 on each axis.
    private var pointer = CGPoint.zero
    // The displayed lean in the same units, and its velocity per second.
    private var lean = CGPoint.zero
    private var velocity = CGPoint.zero
    private var displayLink: CADisplayLink?
    private var lastGlassUpdate: CFTimeInterval = 0

    init(artworkSize: CGFloat) {
        self.artworkSize = artworkSize
        host = DetailArtworkHostingView(rootView: DetailArtworkHostedRoot(content: hostedContent))
        super.init(frame: .zero)
        wantsLayer = true
        // The page scrolls behind the toolbar; keep that from insetting the artwork.
        host.safeAreaRegions = []
        host.sizingOptions = []
        addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    private var bleed: NSEdgeInsets {
        // The top bleed puts the hosting view's center on the artwork's, which the lean pivots on.
        let footprint = Self.footprint(artworkSize: artworkSize)
        return NSEdgeInsets(
            top: Self.bottomBleed + footprint.height - artworkSize,
            left: Self.sideBleed, bottom: Self.bottomBleed, right: Self.sideBleed
        )
    }

    func setContent(_ content: AnyView) {
        let bleed = bleed
        hostedContent.view = AnyView(
            content
                .padding(EdgeInsets(top: bleed.top, leading: bleed.left, bottom: bleed.bottom, trailing: bleed.right))
                .ignoresSafeArea()
        )
    }

    override func layout() {
        super.layout()
        let bleed = bleed
        host.frame = CGRect(
            x: -bleed.left, y: -bleed.top,
            width: bounds.width + bleed.left + bleed.right,
            height: bounds.height + bleed.top + bleed.bottom
        )
        applyLean()
    }

    // The hosting view overhangs the footprint; only the footprint takes clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? super.hitTest(point) : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        // Not passed on: the page's hosting view tracks the pointer itself, and would
        // otherwise run its hover handling a second time for every move.
        setPointer(convert(event.locationInWindow, from: nil))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopAnimating() }
    }

    // Hover can begin before the first move event arrives here.
    private func readPointer() {
        guard let window else { return }
        setPointer(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func setPointer(_ location: CGPoint) {
        let half = artworkSize / 2
        pointer = CGPoint(
            x: min(max((location.x - half) / half, -1), 1),
            y: min(max((location.y - half) / half, -1), 1)
        )
        if isTilting { startAnimating() }
    }

    private var target: CGPoint { isTilting ? pointer : .zero }

    private func startAnimating() {
        guard displayLink == nil, window != nil else { return }
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopAnimating() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let spring = isTilting ? DetailArtworkTiltMotion.tracking : DetailArtworkTiltMotion.settling
        let frequency = 2 * Double.pi / spring.response
        let stiffness = frequency * frequency
        let damping = 2 * spring.dampingFraction * frequency
        let target = target

        // Small fixed steps keep the spring stable if a frame arrives late.
        var remaining = min(link.targetTimestamp - link.timestamp, 1.0 / 20)
        while remaining > 0 {
            let dt = min(remaining, 1.0 / 240)
            velocity.x += (stiffness * (target.x - lean.x) - damping * velocity.x) * dt
            velocity.y += (stiffness * (target.y - lean.y) - damping * velocity.y) * dt
            lean.x += velocity.x * dt
            lean.y += velocity.y * dt
            remaining -= dt
        }

        let isSettled = hypot(target.x - lean.x, target.y - lean.y) < 0.001
            && hypot(velocity.x, velocity.y) < 0.01
        if isSettled {
            lean = target
            velocity = .zero
            // Pointer moves restart it; holding still costs nothing.
            stopAnimating()
        }
        applyLean()
        updateGlass(at: link.timestamp, isSettled: isSettled)
    }

    // Radians the artwork is turned by at the current lean.
    private var leanAngle: Double {
        DetailArtworkTiltMotion.angle * min(hypot(lean.x, lean.y), 1) * .pi / 180
    }

    // Re-rendering the glass is the costly part of a frame, and its highlight is too soft to
    // show the difference, so it follows at up to 60 updates a second.
    private func updateGlass(at timestamp: CFTimeInterval, isSettled: Bool) {
        guard isSettled || timestamp - lastGlassUpdate > 1.0 / 60 - 0.002 else { return }
        lastGlassUpdate = timestamp
        let distance = hypot(lean.x, lean.y)
        let normal = distance > 0
            ? CGSize(width: sin(leanAngle) * lean.x / distance, height: sin(leanAngle) * lean.y / distance)
            : .zero
        if glassTilt.normal != normal { glassTilt.normal = normal }
    }

    private func applyLean() {
        guard let layer, let hostLayer = host.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayerTransform = leanTransform(around: CGPoint(x: hostLayer.frame.midX, y: hostLayer.frame.midY))
        CATransaction.commit()
    }

    private func leanTransform(around center: CGPoint) -> CATransform3D {
        let distance = hypot(lean.x, lean.y)
        guard distance > 0 else { return CATransform3DIdentity }
        // The side under the pointer recedes: turn about the in-plane axis square to the lean.
        var transform = CATransform3DMakeTranslation(-center.x, -center.y, 0)
        transform = CATransform3DConcat(
            transform, CATransform3DMakeRotation(leanAngle, -lean.y / distance, lean.x / distance, 0)
        )
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / (artworkSize * DetailArtworkTiltMotion.viewingDistance)
        transform = CATransform3DConcat(transform, perspective)
        return CATransform3DConcat(transform, CATransform3DMakeTranslation(center.x, center.y, 0))
    }
}

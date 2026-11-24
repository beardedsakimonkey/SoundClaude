import AppKit
import SwiftUI

private struct DetailScrollTargetKey: EnvironmentKey {
    static let defaultValue: DetailScrollTarget? = nil
}

extension EnvironmentValues {
    var detailScrollTarget: DetailScrollTarget? {
        get { self[DetailScrollTargetKey.self] }
        set { self[DetailScrollTargetKey.self] = newValue }
    }
}

final class DetailScrollTarget {
    weak var anchor: NSView?
}

// Gives a slot a target that tracks the page's scroll view, for slots without their own state.
struct DetailScrollSlot<Content: View>: View {
    @ViewBuilder let content: (DetailScrollTarget) -> Content
    @State private var target = DetailScrollTarget()

    var body: some View {
        content(target).background(DetailScrollAnchor(target: target))
    }
}

struct DetailScrollAnchor: NSViewRepresentable {
    let target: DetailScrollTarget

    func makeNSView(context: Context) -> NSView {
        let view = DetailScrollAnchorView()
        target.anchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        target.anchor = view
    }
}

private final class DetailScrollAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// Host-drawn detail controls sit above the page's scroll view, where SwiftUI content
// swallows wheel events. Return them to the scroll view that contains the control's slot,
// leaving clicks, drags, and hover to SwiftUI.
struct DetailScrollForwarder: NSViewRepresentable {
    let target: DetailScrollTarget

    func makeNSView(context: Context) -> DetailScrollForwardingView {
        DetailScrollForwardingView()
    }

    func updateNSView(_ view: DetailScrollForwardingView, context: Context) {
        view.target = target
    }
}

final class DetailScrollForwardingView: NSView {
    var target: DetailScrollTarget?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard NSApp.currentEvent?.type == .scrollWheel,
              target?.anchor?.enclosingScrollView != nil else { return nil }
        return super.hitTest(point)
    }

    override func scrollWheel(with event: NSEvent) {
        if let scrollView = target?.anchor?.enclosingScrollView {
            scrollView.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

// Host-drawn controls pass behind the toolbar, where a click must drag the window instead.
// The host's mask clips drawing but not hit testing, so trim each control's hit area to the
// part below the toolbar. A container's content shape limits its descendants' hits too.
struct BelowToolbarHitShape: Shape {
    // How far the control's top sits under the toolbar.
    var occludedHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        let inset = min(max(occludedHeight, 0), rect.height)
        return Path(CGRect(x: rect.minX, y: rect.minY + inset, width: rect.width, height: rect.height - inset))
    }
}

private struct DetailToolbarOcclusionKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    // How far the top of the host-drawn waveform sits under the toolbar.
    var detailToolbarOcclusion: CGFloat {
        get { self[DetailToolbarOcclusionKey.self] }
        set { self[DetailToolbarOcclusionKey.self] = newValue }
    }
}

extension View {
    // `bounds` is in the host's safe area, whose top is the toolbar's bottom edge.
    // The shape also makes the control's empty space take clicks, so apply it only
    // to the control's own frame.
    func hitTestingBelowToolbar(_ bounds: CGRect) -> some View {
        contentShape(BelowToolbarHitShape(occludedHeight: -bounds.minY))
    }
}

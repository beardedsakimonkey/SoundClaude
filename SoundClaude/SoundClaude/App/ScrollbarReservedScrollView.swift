import AppKit
import SwiftUI

/// A vertical scroll view that reserves space for the system's legacy scrollbar.
struct ScrollbarReservedScrollView<Content: View>: View {
    @ViewBuilder let content: (CGSize) -> Content

    @State private var scrollerStyle = NSScroller.preferredScrollerStyle

    var body: some View {
        GeometryReader { geometry in
            let scrollbarWidth = scrollerStyle == .legacy
                ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
                : 0
            let contentSize = CGSize(
                width: max(0, geometry.size.width - scrollbarWidth),
                height: geometry.size.height
            )

            ScrollView {
                content(contentSize)
                    // AppKit can defer its narrower width proposal until the first scroll.
                    .frame(width: contentSize.width, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .scrollKeyNavigation()
            }
            .frame(width: geometry.size.width)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
            scrollerStyle = NSScroller.preferredScrollerStyle
        }
    }
}

extension View {
    /// Scrolls the enclosing page scroll view with Page Up/Down, Home/End, and ↑/↓.
    /// SwiftUI scroll views never become first responder, so AppKit's own key handling
    /// never sees these keys. Apply this inside the scroll view's content.
    func scrollKeyNavigation() -> some View {
        background(ScrollKeyNavigationView())
    }
}

private struct ScrollKeyNavigationView: NSViewRepresentable {
    // Retained root pages and pages behind the visualizer stay mounted but inactive.
    @Environment(\.contentHoverEnabled) private var isActive

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.isActive = isActive
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.isActive = isActive
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class MonitorView: NSView {
        var isActive = false
        private var monitor: Any?
        private var targetOrigin: NSPoint?
        private static let lineScroll: CGFloat = 40

        private enum Key {
            case lineUp, lineDown, pageUp, pageDown, home, end
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.handle(event) else { return event }
                return nil
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            stopMonitoring()
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard isActive,
                  let window, event.window === window, window.attachedSheet == nil,
                  let scrollView = enclosingScrollView,
                  let key = Self.key(for: event) else { return false }

            if let text = window.firstResponder as? NSText {
                // Leave arrows to text fields, and every key to multi-line editors.
                switch key {
                case .lineUp, .lineDown: return false
                default: if !text.isFieldEditor { return false }
                }
            }

            scroll(scrollView, key: key)
            return true
        }

        private static func key(for event: NSEvent) -> Key? {
            let modifiers = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.function, .numericPad, .capsLock])
            guard modifiers.isEmpty else { return nil }

            switch Int(event.keyCode) {
            case 126: return .lineUp
            case 125: return .lineDown
            case 116: return .pageUp
            case 121: return .pageDown
            case 115: return .home
            case 119: return .end
            default: return nil
            }
        }

        private func scroll(_ scrollView: NSScrollView, key: Key) {
            let clipView = scrollView.contentView
            guard let documentView = scrollView.documentView else { return }

            // Continue from an in-flight animation so held keys don't stall.
            let origin = targetOrigin ?? clipView.bounds.origin
            let insets = clipView.contentInsets
            let visibleHeight = clipView.bounds.height - insets.top - insets.bottom
            let page = max(visibleHeight - scrollView.verticalPageScroll, Self.lineScroll)
            let documentHeight = documentView.frame.height

            // Distance toward the end of the document.
            let delta: CGFloat = switch key {
            case .lineUp: -Self.lineScroll
            case .lineDown: Self.lineScroll
            case .pageUp: -page
            case .pageDown: page
            case .home: -documentHeight
            case .end: documentHeight
            }

            var proposed = clipView.bounds
            proposed.origin = NSPoint(x: origin.x, y: origin.y + (documentView.isFlipped ? delta : -delta))
            let destination = clipView.constrainBoundsRect(proposed).origin
            guard destination != origin else { return }

            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                clipView.setBoundsOrigin(destination)
                scrollView.reflectScrolledClipView(clipView)
                return
            }

            targetOrigin = destination
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.allowsImplicitAnimation = true
                clipView.animator().setBoundsOrigin(destination)
            } completionHandler: { [weak self] in
                guard let self else { return }
                if self.targetOrigin == destination { self.targetOrigin = nil }
                scrollView.reflectScrolledClipView(clipView)
            }
        }
    }
}

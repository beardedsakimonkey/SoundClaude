import AppKit
import SwiftUI

struct SearchOutsideClickView: NSViewRepresentable {
    let onOutsideClick: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onOutsideClick = onOutsideClick
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onOutsideClick = onOutsideClick
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class MonitorView: NSView {
        var onOutsideClick: (() -> Void)?
        private var monitor: Any?

        // The background observes clicks without taking part in hit testing.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
                [weak self] event in
                guard let self,
                      let window = self.window,
                      event.window === window,
                      !self.isHiddenOrHasHiddenAncestor else { return event }

                let location = self.convert(event.locationInWindow, from: nil)
                if !self.visibleRect.contains(location) {
                    self.onOutsideClick?()
                }
                return event
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
    }
}

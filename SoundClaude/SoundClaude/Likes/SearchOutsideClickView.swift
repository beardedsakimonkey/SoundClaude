import AppKit
import SwiftUI

struct SearchOutsideClickView: NSViewRepresentable {
    let isFocused: Bool
    let onOutsideClick: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.isFocused = isFocused
        view.onOutsideClick = onOutsideClick
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.isFocused = isFocused
        nsView.onOutsideClick = onOutsideClick
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class MonitorView: NSView {
        var isFocused = false
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
                      self.isFocused,
                      let window = self.window,
                      event.window === window,
                      !self.isHiddenOrHasHiddenAncestor else { return event }

                let location = self.convert(event.locationInWindow, from: nil)
                // SwiftUI can disable clipping, making visibleRect larger than the filter.
                let filterRect = self.bounds.intersection(self.visibleRect)
                if !filterRect.contains(location) {
                    // End native text editing before the click can focus another control.
                    window.makeFirstResponder(nil)
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

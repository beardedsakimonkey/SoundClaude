import AppKit
import SwiftUI

struct PreventAutomaticSearchFocus: ViewModifier {
    @State private var isReady = false

    func body(content: Content) -> some View {
        content
            // Keep the field out of macOS's initial focus selection.
            .disabled(!isReady)
            .onAppear {
                DispatchQueue.main.async {
                    isReady = true
                }
            }
            .onDisappear {
                isReady = false
            }
    }
}

struct SearchOutsideClickView: NSViewRepresentable {
    let isFocused: Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.isFocused = isFocused
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.isFocused = isFocused
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class MonitorView: NSView {
        var isFocused = false
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
                    // SwiftUI clears the field's focus state from this on its own; setting
                    // it false as well lands after the click focuses another field, and
                    // takes that focus away again.
                    window.makeFirstResponder(nil)
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

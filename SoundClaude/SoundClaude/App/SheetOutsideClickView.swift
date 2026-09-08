import AppKit
import SwiftUI

extension View {
    /// Dismisses a sheet when the user clicks outside it in its parent window.
    /// Apply this modifier to the sheet's content.
    func dismissOnOutsideClick() -> some View {
        modifier(SheetOutsideClickDismissal())
    }
}

private struct SheetOutsideClickDismissal: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.background {
            SheetOutsideClickView { dismiss() }
        }
    }
}

private struct SheetOutsideClickView: NSViewRepresentable {
    let onDismiss: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onDismiss = onDismiss
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onDismiss = onDismiss
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class MonitorView: NSView {
        var onDismiss: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
                [weak self] event in
                guard let self,
                      let sheet = self.window,
                      sheet.isVisible,
                      let parent = sheet.sheetParent,
                      parent.attachedSheet === sheet,
                      sheet.attachedSheet == nil,
                      let eventWindow = event.window,
                      eventWindow === parent || eventWindow === sheet else {
                    return event
                }

                let location = eventWindow.convertPoint(toScreen: event.locationInWindow)
                guard parent.frame.contains(location),
                      !sheet.frame.contains(location) else {
                    return event
                }

                // Consume the click so it cannot activate a control behind the sheet.
                self.stopMonitoring()
                self.onDismiss?()
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
    }
}

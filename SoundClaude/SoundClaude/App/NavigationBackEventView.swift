import AppKit
import SwiftUI

struct NavigationBackEventView: NSViewRepresentable {
    let onBack: () -> Bool
    let onForward: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onBack: onBack, onForward: onForward)
    }

    func makeNSView(context: Context) -> ResponderInstallerView {
        ResponderInstallerView(coordinator: context.coordinator)
    }

    func updateNSView(_ nsView: ResponderInstallerView, context: Context) {
        context.coordinator.onBack = onBack
        context.coordinator.onForward = onForward
    }

    static func dismantleNSView(
        _ nsView: ResponderInstallerView,
        coordinator: Coordinator
    ) {
        coordinator.uninstall()
    }

    final class Coordinator: NSResponder {
        var onBack: () -> Bool
        var onForward: () -> Bool

        private weak var window: NSWindow?

        init(
            onBack: @escaping () -> Bool,
            onForward: @escaping () -> Bool
        ) {
            self.onBack = onBack
            self.onForward = onForward
            super.init()
        }

        required init?(coder: NSCoder) {
            onBack = { false }
            onForward = { false }
            super.init(coder: coder)
        }

        func install(in window: NSWindow?) {
            guard self.window !== window else {
                return
            }

            uninstall()

            guard let window else {
                return
            }

            nextResponder = window.nextResponder
            window.nextResponder = self
            self.window = window
        }

        func uninstall() {
            if window?.nextResponder === self {
                window?.nextResponder = nextResponder
            }

            nextResponder = nil
            window = nil
        }

        override func swipe(with event: NSEvent) {
            let handled: Bool
            if event.deltaX > 0 {
                handled = onBack()
            } else if event.deltaX < 0 {
                handled = onForward()
            } else {
                handled = false
            }

            if !handled {
                super.swipe(with: event)
                return
            }
        }
    }

    final class ResponderInstallerView: NSView {
        private weak var coordinator: Coordinator?

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.install(in: window)
        }
    }
}

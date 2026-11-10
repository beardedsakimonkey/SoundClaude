import AppKit
import SwiftUI

/// Dragging a scrollbar replaces every visible row on each frame, faster than rows can
/// mount their buttons, menus, and hover tracking. A row that mounts during such a
/// scroll shows only its appearance, and adds its controls once scrolling settles.
@MainActor
final class ScrollScrubbing {
    static let shared = ScrollScrubbing()

    /// Points per second. Slower scrolling reveals rows gradually enough to mount them whole.
    private static let minimumSpeed: CGFloat = 3_000
    private static let settleDelay: TimeInterval = 0.15
    private static let turnInterval = 8

    private var lastFastScroll = -TimeInterval.infinity
    private var nextTurn = ContinuousClock.now

    var isActive: Bool {
        ProcessInfo.processInfo.systemUptime - lastFastScroll < Self.settleDelay
    }

    fileprivate func scrolled(by distance: CGFloat, after elapsed: TimeInterval) {
        // A jump that follows a pause counts as a single slow frame, and
        // changes within the same frame must not read as a high speed.
        let duration = min(max(elapsed, 1.0 / 120), 1.0 / 30)
        if distance / duration >= Self.minimumSpeed {
            lastFastScroll = ProcessInfo.processInfo.systemUptime
        }
    }

    /// Suspends while scrolling is fast.
    func settled() async throws {
        while isActive {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Suspends like `settled`, then resumes callers one at a time. A screenful
    /// of rows mounting their controls together would itself drop frames.
    func settledInTurn() async throws {
        repeat {
            try await settled()
            let turn = max(nextTurn, .now)
            nextTurn = turn + .milliseconds(Self.turnInterval)
            try await Task.sleep(until: turn)
        } while isActive
    }
}

extension View {
    /// Reports fast scrolling of the enclosing scroll view. Apply this inside its content.
    func monitorsScrollScrubbing() -> some View {
        background(ScrollScrubbingMonitor())
    }
}

private struct ScrollScrubbingMonitor: NSViewRepresentable {
    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ nsView: MonitorView, context: Context) {}

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class MonitorView: NSView {
        private var observer: NSObjectProtocol?
        private var lastOffset: CGFloat = 0
        private var lastScroll: TimeInterval = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil, let clipView = enclosingScrollView?.contentView else { return }

            clipView.postsBoundsChangedNotifications = true
            lastOffset = clipView.bounds.origin.y
            // Deliver synchronously: the rows this scroll reveals mount later in the same update.
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clipView, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.clipViewDidScroll(clipView) }
            }
        }

        private func clipViewDidScroll(_ clipView: NSClipView) {
            let offset = clipView.bounds.origin.y
            let now = ProcessInfo.processInfo.systemUptime
            ScrollScrubbing.shared.scrolled(by: abs(offset - lastOffset), after: now - lastScroll)
            lastOffset = offset
            lastScroll = now
        }

        func stopMonitoring() {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
        }

        deinit {
            stopMonitoring()
        }
    }
}

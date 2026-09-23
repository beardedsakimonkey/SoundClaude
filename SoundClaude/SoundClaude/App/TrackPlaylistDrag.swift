import AppKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// A separate type keeps playlist drops distinct from queue reorder drags.
struct TrackPlaylistDrag: Codable, Transferable {
    let track: SoundCloudTrack

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .soundClaudeTrack)
            .visibility(.ownProcess)
    }
}

extension UTType {
    static let soundClaudeTrack = UTType(
        exportedAs: "com.tim.soundclaude.native.track",
        conformingTo: .data
    )
}

extension View {
    func trackDraggable(_ track: SoundCloudTrack) -> some View {
        draggable(TrackPlaylistDrag(track: track))
            .background(TrackDragThreshold())
    }
}

/// Keep small mouse movements from reaching the native drag recognizer.
/// Mouse-down and mouse-up still reach the original controls for normal clicks.
private struct TrackDragThreshold: NSViewRepresentable {
    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ nsView: MonitorView, context: Context) {}

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class MonitorView: NSView {
        private var monitor: Any?
        private var start: NSPoint?
        private let minimumDistance: CGFloat = 8

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                guard let self else { return event }
                return self.filter(event)
            }
        }

        private func filter(_ event: NSEvent) -> NSEvent? {
            switch event.type {
            case .leftMouseDown:
                start = nil
                if let window, event.window === window,
                   !isHiddenOrHasHiddenAncestor,
                   visibleRect.contains(convert(event.locationInWindow, from: nil)) {
                    start = event.locationInWindow
                }
            case .leftMouseDragged:
                guard let start, event.window === window else { return event }
                if hypot(event.locationInWindow.x - start.x,
                         event.locationInWindow.y - start.y) < minimumDistance {
                    return nil
                }
                // Once the threshold is crossed, allow the entire drag through,
                // including movement back toward the original click position.
                self.start = nil
            case .leftMouseUp:
                start = nil
            default:
                break
            }
            return event
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            start = nil
        }

        deinit { stopMonitoring() }
    }
}

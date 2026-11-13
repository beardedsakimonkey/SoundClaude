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

/// SwiftUI's `draggable` reports neither the start nor the end of a drag, so
/// drop targets learn about one from the drag pasteboard and the mouse button.
@MainActor @Observable
final class TrackDragState {
    static let shared = TrackDragState()

    private(set) var isDragging = false
    @ObservationIgnored private var timer: Timer?

    /// Call once the pointer has moved far enough to start a drag.
    /// `baseline` is the drag pasteboard's change count at mouse-down.
    fileprivate func watchForDrag(baseline: Int) {
        timer?.invalidate()
        // Common modes keep the timer firing while the drag tracks the mouse.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll(baseline: baseline) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll(baseline: Int) {
        if NSEvent.pressedMouseButtons & 1 == 0 {
            timer?.invalidate()
            timer = nil
            isDragging = false
        } else if !isDragging, NSPasteboard(name: .drag).changeCount != baseline {
            isDragging = true
        }
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

    /// Text inside the glass footer renders blank in the default drag image,
    /// so the title preview uses colors that do not depend on its surroundings.
    func trackDraggable(_ track: SoundCloudTrack, previewTitle: String) -> some View {
        draggable(TrackPlaylistDrag(track: track)) {
            Text(previewTitle)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(Color(nsColor: .labelColor))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
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
        private var dragPasteboardChangeCount = 0
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
                    dragPasteboardChangeCount = NSPasteboard(name: .drag).changeCount
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
                TrackDragState.shared.watchForDrag(baseline: dragPasteboardChangeCount)
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

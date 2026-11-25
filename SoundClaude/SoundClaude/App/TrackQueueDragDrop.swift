import AppKit
import SwiftUI

/// Owns the temporary drag order and commits a single move after a valid drop.
struct TrackQueueList<Row: View>: View {
    let tracks: [SoundCloudTrack]
    let currentTrackURN: String?
    let onMove: (IndexSet, Int) -> Void
    @ViewBuilder let row: (SoundCloudTrack) -> Row

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draggedURN: String?
    @State private var previewTracks: [SoundCloudTrack]?
    @State private var dragTranslation: CGFloat = 0
    @State private var dragFrames: [String: CGRect] = [:]
    @State private var rowFrames: [String: CGRect] = [:]

    private let dragCoordinateSpace = "trackQueueDrag"

    // Keep the row identities and layout slots fixed for the whole gesture.
    // Only their vertical offsets change, so the source keeps receiving events.
    private func updateDrag(translation: CGFloat) {
        guard let draggedURN, let frame = dragFrames[draggedURN],
              let source = tracks.firstIndex(where: { $0.urn == draggedURN }) else { return }
        dragTranslation = translation
        let center = frame.midY + translation
        var destination = source
        for (index, track) in tracks.enumerated() {
            guard let target = dragFrames[track.urn] else { continue }
            if index > source && center > target.midY { destination = index }
            if index < source && center < target.midY {
                destination = min(destination, index)
            }
        }
        var preview = tracks
        preview.move(fromOffsets: IndexSet(integer: source),
                     toOffset: destination > source ? destination + 1 : destination)
        previewTracks = preview
    }

    /// Lifts the row under `point`, given in the scroll view's coordinate space.
    private func startDrag(at point: CGPoint) -> Bool {
        guard draggedURN == nil,
              let track = tracks.first(where: { rowFrames[$0.urn]?.contains(point) == true }) else {
            return false
        }
        dragFrames = rowFrames
        draggedURN = track.urn
        previewTracks = tracks
        return true
    }

    private func offset(for urn: String) -> CGFloat {
        if urn == draggedURN { return dragTranslation }
        guard draggedURN != nil,
              let destination = previewTracks?.firstIndex(where: { $0.urn == urn }),
              let originalFrame = dragFrames[urn],
              let targetFrame = dragFrames[tracks[destination].urn] else { return 0 }
        return targetFrame.minY - originalFrame.minY
    }

    private func commitDrag() -> Bool {
        guard let draggedURN,
              let source = tracks.firstIndex(where: { $0.urn == draggedURN }),
              let destination = previewTracks?.firstIndex(where: { $0.urn == draggedURN }) else {
            return false
        }
        // The dropped rows are already drawn in their final positions.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if source != destination {
                onMove(
                    IndexSet(integer: source),
                    destination > source ? destination + 1 : destination
                )
            }
            cancelDrag()
        }
        return true
    }

    private func cancelDrag() {
        previewTracks = nil
        draggedURN = nil
        dragTranslation = 0
        dragFrames = [:]
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(tracks.map { QueueRowItem(track: $0, isDragged: $0.urn == draggedURN) }) { item in
                        let track = item.track
                        row(track)
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: QueueRowFramesKey.self,
                                        value: [track.urn: geometry.frame(in: .named(dragCoordinateSpace))]
                                    )
                                }
                            }
                            .background {
                                if draggedURN == track.urn {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.8))
                                        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                                }
                            }
                            .contentShape(Rectangle())
                            .offset(y: offset(for: track.urn))
                            .animation(
                                draggedURN == nil || draggedURN == track.urn || reduceMotion ? nil
                                    : .spring(response: 0.3, dampingFraction: 0.85),
                                value: offset(for: track.urn)
                            )
                            .zIndex(item.isDragged ? 999 : 0)
                    }
                }
                .frame(maxWidth: .infinity)
                .modifier(QueueRowMoveAnimation(order: tracks.map(\.urn)))
            }
            .coordinateSpace(name: dragCoordinateSpace)
            .background {
                QueueDragMonitor(
                    onStart: startDrag,
                    onChange: updateDrag,
                    onEnd: { valid in
                        if valid { _ = commitDrag() } else { cancelDrag() }
                    },
                    onCancel: cancelDrag
                )
            }
            .onPreferenceChange(QueueRowFramesKey.self) { rowFrames = $0 }
            .onAppear {
                if let urn = currentTrackURN {
                    proxy.scrollTo(QueueRowIdentity(urn: urn, isDragged: false), anchor: .center)
                }
            }
        }
        .onChange(of: tracks.map(\.urn)) { _, _ in cancelDrag() }
        .onDisappear(perform: cancelDrag)
        .onExitCommand {
            if draggedURN != nil { cancelDrag() }
        }
    }
}

// Slide rows only when the same tracks change order, such as toggling shuffle,
// or when one track is added or removed. Loading more pages, clearing, or
// replacing the queue should still update immediately.
private struct QueueRowMoveAnimation: ViewModifier {
    let order: [String]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previousOrder: [String] = []

    private var shouldAnimate: Bool {
        order != previousOrder && !previousOrder.isEmpty
            && Set(order).symmetricDifference(previousOrder).count <= 1
    }

    func body(content: Content) -> some View {
        content
            .transaction { transaction in
                if !reduceMotion && !transaction.disablesAnimations && shouldAnimate {
                    transaction.animation = .spring(response: 0.3, dampingFraction: 0.85)
                }
            }
            .onChange(of: order, initial: true) { _, newOrder in
                previousOrder = newOrder
            }
    }
}

// Lazy stacks cache a row's initial zIndex. Refresh only the active row's
// identity when lifting/lowering it; all other rows retain their state.
private struct QueueRowItem: Identifiable {
    let track: SoundCloudTrack
    let isDragged: Bool
    var id: QueueRowIdentity { QueueRowIdentity(urn: track.urn, isDragged: isDragged) }
}

private struct QueueRowIdentity: Hashable {
    let urn: String
    let isDragged: Bool
}

// Watches the window's mouse events from behind the scroll view instead of
// receiving them, so clicks still reach the rows' buttons and tap gestures.
// A press that moves past the threshold lifts the row under it. Tracking stays
// here, outside the rows, because the lifted row's lazy-stack identity changes.
// This moves the live row, without a native drag image or snapshot.
private struct QueueDragMonitor: NSViewRepresentable {
    let onStart: (CGPoint) -> Bool
    let onChange: (CGFloat) -> Void
    let onEnd: (Bool) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onStart = onStart
        view.onChange = onChange
        view.onEnd = onEnd
        view.onCancel = onCancel
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class MonitorView: NSView {
        var onStart: ((CGPoint) -> Bool)?
        var onChange: ((CGFloat) -> Void)?
        var onEnd: ((Bool) -> Void)?
        var onCancel: (() -> Void)?

        private var monitor: Any?
        /// Where the current press began, until it becomes a drag or ends.
        private var pressStart: CGPoint?
        /// Where the active drag began.
        private var dragStart: CGPoint?
        private let minimumDistance: CGFloat = 5

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]
            ) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            if event.type == .keyDown {
                // Escape cancels an active drag.
                guard dragStart != nil, event.keyCode == 53 else { return event }
                endDrag()
                onCancel?()
                return nil
            }
            guard let window, event.window === window else {
                if dragStart != nil {
                    endDrag()
                    onCancel?()
                }
                pressStart = nil
                return event
            }
            let point = convert(event.locationInWindow, from: nil)
            switch event.type {
            case .leftMouseDown:
                pressStart = nil
                if !isHiddenOrHasHiddenAncestor, bounds.contains(point),
                   !isOnScroller(event) {
                    pressStart = point
                }
            case .leftMouseDragged:
                if let dragStart {
                    onChange?(point.y - dragStart.y)
                } else if let pressStart,
                          hypot(point.x - pressStart.x, point.y - pressStart.y) >= minimumDistance {
                    self.pressStart = nil
                    if onStart?(pressStart) == true {
                        dragStart = pressStart
                        NSCursor.closedHand.push()
                        onChange?(point.y - pressStart.y)
                    }
                }
            case .leftMouseUp:
                pressStart = nil
                if dragStart != nil {
                    endDrag()
                    onEnd?(bounds.contains(point))
                }
            default:
                break
            }
            return event
        }

        private func isOnScroller(_ event: NSEvent) -> Bool {
            var view = window?.contentView?.hitTest(event.locationInWindow)
            while let current = view {
                if current is NSScroller { return true }
                view = current.superview
            }
            return false
        }

        private func endDrag() {
            if dragStart != nil { NSCursor.pop() }
            dragStart = nil
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            pressStart = nil
            endDrag()
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

private struct QueueRowFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

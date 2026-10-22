import AppKit
import SwiftUI

/// Owns the temporary drag order and commits a single move after a valid drop.
struct TrackQueueList<Row: View>: View {
    let tracks: [SoundCloudTrack]
    let currentTrackURN: String?
    let onMove: (IndexSet, Int) -> Void
    let onDismiss: () -> Void
    @ViewBuilder let row: (SoundCloudTrack) -> Row

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragSession = QueueMouseSession()
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
        if source != destination {
            onMove(
                IndexSet(integer: source),
                destination > source ? destination + 1 : destination
            )
        }
        cancelDrag()
        return true
    }

    private func cancelDrag() {
        dragSession.stop()
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
                        HStack(spacing: 0) {
                            QueueDragHandle()
                                .accessibilityLabel("Reorder \(track.title)")
                            row(track)
                        }
                        .overlay(alignment: .leading) {
                            GeometryReader { geometry in
                                QueueDragSource(
                                    title: track.title,
                                    session: dragSession,
                                    onStart: {
                                        dragFrames = rowFrames
                                        draggedURN = track.urn
                                        previewTracks = tracks
                                    },
                                    onChange: updateDrag,
                                    onEnd: { valid in
                                        if valid { _ = commitDrag() } else { cancelDrag() }
                                    },
                                    onCancel: cancelDrag
                                )
                                .frame(width: 28, height: geometry.size.height)
                            }
                        }
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
            }
            .coordinateSpace(name: dragCoordinateSpace)
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
            if draggedURN != nil {
                cancelDrag()
            } else {
                onDismiss()
            }
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

// Keep tracking outside the row because its lazy-stack identity changes at
// mouse-down. This moves the live row, without a native drag image or snapshot.
@MainActor
private final class QueueMouseSession {
    private var monitor: Any?

    func start(
        event: NSEvent,
        source: NSView,
        onChange: @escaping (CGFloat) -> Void,
        onEnd: @escaping (Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        stop()
        let start = event.locationInWindow
        let window = source.window
        let scrollView = source.enclosingScrollView
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self, weak window, weak scrollView] event in
            guard let self else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }
                self.stop()
                onCancel()
                return nil
            }
            guard event.window === window else {
                self.stop()
                onCancel()
                return event
            }
            if event.type == .leftMouseDragged {
                onChange(start.y - event.locationInWindow.y)
            } else {
                let valid = scrollView.map {
                    $0.bounds.contains($0.convert(event.locationInWindow, from: nil))
                } ?? false
                self.stop()
                onEnd(valid)
            }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private struct QueueDragSource: NSViewRepresentable {
    let title: String
    let session: QueueMouseSession
    let onStart: () -> Void
    let onChange: (CGFloat) -> Void
    let onEnd: (Bool) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> DragView { DragView() }

    func updateNSView(_ view: DragView, context: Context) {
        view.setAccessibilityLabel("Reorder \(title)")
        view.onMouseDown = { [weak view] event in
            guard let view else { return }
            session.start(event: event, source: view, onChange: onChange,
                          onEnd: onEnd, onCancel: onCancel)
            onStart()
        }
    }

    final class DragView: NSView {
        var onMouseDown: ((NSEvent) -> Void)?

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            onMouseDown?(event)
        }
    }
}

private struct QueueRowFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct QueueDragHandle: View {
    @State private var isHovered = false

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .foregroundStyle(isHovered ? .primary : .secondary)
            .frame(width: 28, height: 56)
            .contentShape(Rectangle())
            .onContentHover { isHovered = $0 }
            .onDisappear { isHovered = false }
            .contentHelp("Drag to reorder")
    }
}

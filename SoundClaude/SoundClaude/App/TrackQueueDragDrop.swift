import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Owns the temporary drag order and commits a single move after a valid drop.
struct TrackQueueList<Row: View>: View {
    let tracks: [SoundCloudTrack]
    let currentTrackURN: String?
    let onMove: (IndexSet, Int) -> Void
    let onDismiss: () -> Void
    @ViewBuilder let row: (SoundCloudTrack) -> Row

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draggedURN: String?
    @State private var previewTracks: [SoundCloudTrack]?
    @State private var rowFrames: [String: CGRect] = [:]

    private let dragCoordinateSpace = "trackQueueDrag"

    private var displayedTracks: [SoundCloudTrack] {
        previewTracks ?? tracks
    }

    private func previewMove(to targetURN: String, location: CGPoint) {
        guard let draggedURN, var preview = previewTracks,
              let source = preview.firstIndex(where: { $0.urn == draggedURN }),
              let destination = preview.firstIndex(where: { $0.urn == targetURN }),
              source != destination,
              let frame = rowFrames[targetURN] else { return }
        // Cross the target's midpoint before moving, to avoid bouncing between rows.
        guard destination > source ? location.y > frame.height / 2
                                   : location.y < frame.height / 2 else { return }
        preview.move(
            fromOffsets: IndexSet(integer: source),
            toOffset: destination > source ? destination + 1 : destination
        )
        previewTracks = preview
    }

    private func commitDrag() -> Bool {
        guard let draggedURN,
              let source = tracks.firstIndex(where: { $0.urn == draggedURN }),
              let destination = previewTracks?.firstIndex(where: { $0.urn == draggedURN }) else {
            return false
        }
        onMove(
            IndexSet(integer: source),
            destination > source ? destination + 1 : destination
        )
        cancelDrag()
        return true
    }

    private func cancelDrag() {
        previewTracks = nil
        draggedURN = nil
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(displayedTracks) { track in
                        HStack(spacing: 0) {
                            QueueDragHandle()
                                .accessibilityLabel("Reorder \(track.title)")
                            row(track)
                        }
                        .overlay(alignment: .leading) {
                            GeometryReader { geometry in
                                QueueDragSource(
                                    urn: track.urn,
                                    title: track.title,
                                    rowSize: geometry.size,
                                    onStart: {
                                        draggedURN = track.urn
                                        previewTracks = tracks
                                    },
                                    onEnd: cancelDrag
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
                        .contentShape(Rectangle())
                        .onDrop(of: [UTType.utf8PlainText], delegate: QueueDropDelegate(
                            isActive: draggedURN != nil,
                            onHover: { previewMove(to: track.urn, location: $0) },
                            onDrop: commitDrag
                        ))
                        .id(track.urn)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .onDrop(of: [UTType.utf8PlainText], delegate: QueueDropDelegate(
                isActive: draggedURN != nil,
                onHover: { _ in },
                onDrop: commitDrag
            ))
            .animation(
                reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85),
                value: displayedTracks.map(\.urn)
            )
            .coordinateSpace(name: dragCoordinateSpace)
            .onPreferenceChange(QueueRowFramesKey.self) { rowFrames = $0 }
            .onAppear {
                if let urn = currentTrackURN {
                    proxy.scrollTo(urn, anchor: .center)
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

private struct QueueDropDelegate: DropDelegate {
    let isActive: Bool
    let onHover: (CGPoint) -> Void
    let onDrop: () -> Bool

    func validateDrop(info: DropInfo) -> Bool { isActive }

    func dropEntered(info: DropInfo) {
        if isActive { onHover(info.location) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard isActive else { return DropProposal(operation: .cancel) }
        onHover(info.location)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard isActive else { return false }
        onHover(info.location)
        return onDrop()
    }
}

// AppKit owns the drag session so moving the SwiftUI row does not cancel a
// gesture. Its end callback also cleans up drops outside the queue and Escape.
private struct QueueDragSource: NSViewRepresentable {
    let urn: String
    let title: String
    let rowSize: CGSize
    let onStart: () -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> DragView { DragView() }

    func updateNSView(_ view: DragView, context: Context) {
        view.setAccessibilityLabel("Reorder \(title)")
        view.urn = urn
        view.title = title
        view.rowSize = rowSize
        view.onStart = onStart
        view.onEnd = onEnd
    }

    final class DragView: NSView, NSDraggingSource {
        var urn = ""
        var title = ""
        var rowSize: CGSize = .zero
        var onStart: (() -> Void)?
        var onEnd: (() -> Void)?
        private var mouseDownLocation: NSPoint?

        override var isFlipped: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            mouseDownLocation = event.locationInWindow
        }

        override func mouseUp(with event: NSEvent) {
            mouseDownLocation = nil
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = mouseDownLocation,
                  hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 4
            else { return }
            mouseDownLocation = nil
            let item = NSPasteboardItem()
            item.setString(urn, forType: .string)
            let draggingItem = NSDraggingItem(pasteboardWriter: item)
            let image = rowSnapshot() ?? titlePreview()
            let point = convert(event.locationInWindow, from: nil)
            let startPoint = convert(start, from: nil)
            draggingItem.setDraggingFrame(
                NSRect(
                    x: point.x - startPoint.x,
                    y: point.y - startPoint.y,
                    width: image.size.width,
                    height: image.size.height
                ),
                contents: image
            )
            onStart?()
            beginDraggingSession(with: [draggingItem], event: event, source: self)
        }

        private func rowSnapshot() -> NSImage? {
            guard let contentView = window?.contentView,
                  rowSize.width > 0, rowSize.height > 0 else { return nil }
            // Capture the already-rendered row before onStart can move it. This
            // includes loaded artwork and the current SwiftUI appearance/state.
            let rect = convert(NSRect(origin: bounds.origin, size: rowSize), to: contentView)
            guard let bitmap = contentView.bitmapImageRepForCachingDisplay(in: rect) else {
                return nil
            }
            contentView.cacheDisplay(in: rect, to: bitmap)
            let image = NSImage(size: rowSize)
            image.addRepresentation(bitmap)
            return image
        }

        private func titlePreview() -> NSImage {
            NSImage(size: NSSize(width: 240, height: 36), flipped: false) { rect in
                NSColor.controlBackgroundColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byTruncatingTail
                (self.title as NSString).draw(
                    in: rect.insetBy(dx: 10, dy: 9),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 13),
                                     .foregroundColor: NSColor.labelColor,
                                     .paragraphStyle: paragraph]
                )
                return true
            }
        }

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }

        func draggingSession(
            _ session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            onEnd?()
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
            .onHover { isHovered = $0 }
            .onDisappear { isHovered = false }
            .help("Drag to reorder")
    }
}

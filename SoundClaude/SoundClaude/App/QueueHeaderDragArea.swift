import AppKit
import QuartzCore
import SwiftUI

struct QueueHeaderButtonBounds: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []

    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

// Native cursor rectangles keep the hand cursor scoped to the drag area and
// avoid publishing hover/drag state through the queue's SwiftUI content.
struct QueueHeaderDragArea: NSViewRepresentable {
    let onMove: (CGSize) -> Void
    let onMoveEnd: () -> Void

    let buttonRects: [CGRect]

    func makeNSView(context: Context) -> DragView { DragView() }

    func updateNSView(_ view: DragView, context: Context) {
        view.onMove = onMove
        view.onMoveEnd = onMoveEnd
        view.buttonRects = buttonRects
        view.window?.invalidateCursorRects(for: view)
        view.toolTip = "Drag to move track queue"
        view.setAccessibilityLabel("Move track queue")
    }

    final class DragView: NSView {
        var onMove: ((CGSize) -> Void)?
        var onMoveEnd: (() -> Void)?
        var buttonRects: [CGRect] = []
        override var isFlipped: Bool { true }
        private var dragStart: NSPoint?
        private var headerTrackingArea: NSTrackingArea?
        private let highlightLayer = CALayer()
        private var isHovered = false {
            didSet {
                if isHovered != oldValue { updateHighlight() }
            }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            highlightLayer.opacity = 0
            layer?.addSublayer(highlightLayer)
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            highlightLayer.frame = bounds
            CATransaction.commit()
        }

        private func updateHighlight() {
            let target: Float = isHovered || dragStart != nil ? 1 : 0
            guard highlightLayer.opacity != target else { return }
            let current = highlightLayer.presentation()?.opacity ?? highlightLayer.opacity
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            highlightLayer.opacity = target
            CATransaction.commit()
            highlightLayer.removeAnimation(forKey: "hoverFade")
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = current
            animation.toValue = target
            animation.duration = 0.15
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            highlightLayer.add(animation, forKey: "hoverFade")
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let headerTrackingArea { removeTrackingArea(headerTrackingArea) }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate,
                          .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            headerTrackingArea = area
        }

        private func updateHover(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            isHovered = bounds.contains(point) && !buttonRects.contains { $0.contains(point) }
            if dragStart != nil {
                NSCursor.closedHand.set()
            } else {
                (isHovered ? NSCursor.openHand : NSCursor.arrow).set()
            }
        }

        override func mouseEntered(with event: NSEvent) { updateHover(with: event) }
        override func mouseMoved(with event: NSEvent) { updateHover(with: event) }
        override func cursorUpdate(with event: NSEvent) { updateHover(with: event) }

        override func mouseExited(with event: NSEvent) {
            isHovered = false
            if dragStart == nil { NSCursor.arrow.set() }
        }

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            // Split the drag region so no hand cursor rectangle covers a button.
            var regions = [bounds]
            for button in buttonRects {
                regions = regions.flatMap { region -> [CGRect] in
                    let cut = region.intersection(button)
                    guard !cut.isNull && !cut.isEmpty else { return [region] }
                    return [
                        CGRect(x: region.minX, y: region.minY, width: region.width, height: cut.minY - region.minY),
                        CGRect(x: region.minX, y: cut.maxY, width: region.width, height: region.maxY - cut.maxY),
                        CGRect(x: region.minX, y: cut.minY, width: cut.minX - region.minX, height: cut.height),
                        CGRect(x: cut.maxX, y: cut.minY, width: region.maxX - cut.maxX, height: cut.height)
                    ].filter { !$0.isEmpty }
                }
                addCursorRect(button, cursor: .arrow)
            }
            for region in regions {
                addCursorRect(region, cursor: dragStart == nil ? .openHand : .closedHand)
            }
        }

        override func mouseDown(with event: NSEvent) {
            dragStart = event.locationInWindow
            updateHighlight()
            NSCursor.closedHand.set()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = dragStart else { return }
            NSCursor.closedHand.set()
            onMove?(CGSize(
                width: event.locationInWindow.x - start.x,
                height: start.y - event.locationInWindow.y
            ))
        }

        override func mouseUp(with event: NSEvent) {
            dragStart = nil
            onMoveEnd?()
            window?.invalidateCursorRects(for: self)
            updateHover(with: event)
            updateHighlight()
        }
    }
}


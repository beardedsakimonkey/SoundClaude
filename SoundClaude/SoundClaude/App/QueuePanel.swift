import SwiftUI

// Only QueuePanel observes this object. Pointer updates must not invalidate the
// navigation screen or recreate the queue's rows and track lookup.
final class QueuePanelLayout: ObservableObject {
    @Published private var frame: CGRect?
    private var gestureStart: CGRect?

    func fittedFrame(in bounds: CGSize) -> CGRect {
        fitted(frame, in: bounds)
    }

    private func fitted(_ proposed: CGRect?, in bounds: CGSize) -> CGRect {
        let margin: CGFloat = 8
        let width = min(560, max(0, bounds.width - margin * 2))
        let height = min(520, max(0, bounds.height - margin * 2))
        // Leave 96 points of the draggable header visible. Reserve the right
        // 110 points for Clear/Close, which cannot be used to drag the panel.
        let minX = min(0, 110 + 96 - width)
        let maxX = max(0, bounds.width - 16 - 96)
        let maxY = max(0, bounds.height - 60)
        let initialX = max(0, bounds.width - margin - width - 16)
        let initialY = max(0, bounds.height - margin - height + 8)
        return CGRect(
            x: min(maxX, max(minX, proposed?.minX ?? initialX)),
            y: min(maxY, max(0, proposed?.minY ?? initialY)),
            width: width,
            height: height
        )
    }

    func move(_ translation: CGSize, in bounds: CGSize) {
        let start = gestureStart ?? fittedFrame(in: bounds)
        gestureStart = start
        update(fitted(start.offsetBy(dx: translation.width, dy: translation.height), in: bounds))
    }

    func endGesture() { gestureStart = nil }

    func constrain(to bounds: CGSize) {
        if frame != nil { update(fittedFrame(in: bounds)) }
        endGesture()
    }

    private func update(_ newFrame: CGRect) {
        guard frame != newFrame else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { frame = newFrame }
    }
}

struct QueuePanel<Content: View>: View {
    @ObservedObject var layout: QueuePanelLayout
    let bounds: CGSize
    let isVisible: Bool
    let hoverSuppression: ContentHoverSuppression
    // Constructed by the parent, so geometry changes reuse the same content.
    let content: Content

    var body: some View {
        let frame = layout.fittedFrame(in: bounds)
        ZStack(alignment: .topLeading) {
            if isVisible {
                content
                    .frame(width: frame.width, height: frame.height)
                    .modifier(QueuePanelGlass())
                    .contentShape(RoundedRectangle(cornerRadius: 16))
                    .onHover { hoverSuppression.isSuppressed = $0 }
                    .onDisappear {
                        hoverSuppression.isSuppressed = false
                        layout.endGesture()
                    }
                    .offset(x: frame.minX, y: frame.minY)
                    .transition(.offset(y: 24).combined(with: .opacity))
            }
        }
        .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
        .coordinateSpace(name: "queuePanel")
        .onChange(of: bounds) { _, newBounds in layout.constrain(to: newBounds) }
    }
}

private struct QueuePanelGlass: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        Group {
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular, in: shape)
            } else {
                content.background(.regularMaterial, in: shape)
                    .overlay {
                        shape.strokeBorder(.primary.opacity(0.12), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
            }
        }
        .background(
            (colorScheme == .dark ? Color.black : Color.white)
                .opacity(colorScheme == .dark ? 0.4 : 0.6),
            in: shape
        )
    }
}

import AppKit
import SwiftUI

struct SortMenu<Order: Hashable>: View {
    let label: String
    @Binding var selection: Order
    let options: [Order]
    let title: (Order) -> String
    var reservesWidestTitle = true
    @State private var isPointerInside = false
    @Environment(\.contentHoverEnabled) private var hoverEnabled
    @Environment(\.contentHoverSuppression) private var hoverSuppression

    private var isHovered: Bool {
        isPointerInside && hoverEnabled && hoverSuppression?.isSuppressed != true
    }

    var body: some View {
        // Reserve the widest title so changing the order doesn't resize the header.
        ZStack {
            ForEach(reservesWidestTitle ? options : [], id: \.self) { order in
                menu(showing: order)
                    .hidden()
            }

            menu(showing: selection)
                .background {
                    SortMenuHoverTrackingView { isPointerInside = $0 }
                }
                .opacity(isHovered ? 1 : 0.7)
                .accessibilityLabel(label)
                .accessibilityValue(title(selection))
                .contentHelp(label)
        }
        // The borderless menu insets its chevron 2.5pt more than its title. Even out the edges.
        .padding(.trailing, -2.5)
        .fixedSize(horizontal: true, vertical: false)
        .onDisappear { isPointerInside = false }
    }

    private func menu(showing order: Order) -> some View {
        Menu {
            Picker(label, selection: $selection) {
                ForEach(options, id: \.self) { order in
                    Text(title(order))
                        .tag(order)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(title(order))
                .font(.subheadline)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
    }
}

// SwiftUI hover callbacks did not fire over this native menu. Track its bounds in AppKit.
private struct SortMenuHoverTrackingView: NSViewRepresentable {
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onHover = onHover
    }

    final class TrackingView: NSView {
        var onHover: ((Bool) -> Void)?
        private var hoverArea: NSTrackingArea?

        // Observe pointer movement without intercepting menu clicks.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverArea { removeTrackingArea(hoverArea) }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            hoverArea = area
        }

        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseMoved(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }
    }
}

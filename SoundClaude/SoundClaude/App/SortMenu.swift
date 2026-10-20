import AppKit
import SwiftUI

struct SortMenu<Order: Hashable>: View {
    let label: String
    @Binding var selection: Order
    let options: [Order]
    let title: (Order) -> String
    var systemImage: String? = nil
    @State private var isPointerInside = false
    @Environment(\.contentHoverEnabled) private var hoverEnabled
    @Environment(\.contentHoverSuppression) private var hoverSuppression

    private var isHovered: Bool {
        isPointerInside && hoverEnabled && hoverSuppression?.isSuppressed != true
    }

    var body: some View {
        HStack(spacing: 4) {
            if systemImage == nil {
                Image(systemName: "arrow.down")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }

            let menu = Menu {
                Picker(label, selection: $selection) {
                    ForEach(options, id: \.self) { order in
                        Text(title(order))
                            .tag(order)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                if let systemImage {
                    Image(systemName: systemImage)
                } else {
                    Text(title(selection))
                        .font(.subheadline)
                }
            }

            Group {
                if systemImage != nil {
                    menu
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        // Keep header spacing outside the menu's popup anchor.
                        .fixedSize()
                        .frame(width: 36, height: 36)
                } else {
                    menu
                        .menuStyle(.borderlessButton)
                }
            }
            .menuIndicator(systemImage == nil ? .visible : .hidden)
            .fixedSize()
            .opacity(isHovered ? 1 : 0.7)
            .accessibilityLabel(label)
            .accessibilityValue(title(selection))
            .contentHelp(label)
            .background {
                SortMenuHoverTrackingView { isPointerInside = $0 }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .onDisappear { isPointerInside = false }
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

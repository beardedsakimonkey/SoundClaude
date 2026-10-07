import SwiftUI

struct SortMenu<Order: Hashable>: View {
    let label: String
    @Binding var selection: Order
    let options: [Order]
    let title: (Order) -> String
    var systemImage: String? = nil
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
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
                } else {
                    menu
                        .menuStyle(.borderlessButton)
                }
            }
            .menuIndicator(systemImage == nil ? .visible : .hidden)
            .fixedSize()
            .opacity(isHovered ? 1 : 0.7)
            .onContentHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovered)
            .accessibilityLabel(label)
            .accessibilityValue(title(selection))
            .contentHelp(label)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

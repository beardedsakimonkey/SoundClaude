import SwiftUI

struct SortMenu<Order: Hashable>: View {
    let label: String
    @Binding var selection: Order
    let options: [Order]
    let title: (Order) -> String
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.down")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            Menu {
                Picker(label, selection: $selection) {
                    ForEach(options, id: \.self) { order in
                        Text(title(order))
                            .tag(order)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text(title(selection))
                    .font(.subheadline)
            }
            .menuStyle(.borderlessButton)
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

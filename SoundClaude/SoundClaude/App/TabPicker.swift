import SwiftUI

/// Shared, background-free tabs for content selection throughout the app.
struct TabPicker<Selection: Hashable & RawRepresentable>: View where Selection.RawValue == String {
    let title: String
    let options: [Selection]
    @Binding var selection: Selection

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var underlineNamespace
    @State private var hoveredOption: Selection?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.self) { option in
                let isSelected = selection == option

                Button {
                    selection = option
                } label: {
                    Text(option.rawValue)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(isSelected || hoveredOption == option ? Color.primary : Color.secondary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .overlay(alignment: .bottom) {
                            Color.clear
                                .frame(height: 2)
                                .matchedGeometryEffect(id: option, in: underlineNamespace)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onContentHover { isHovering in
                    if isHovering {
                        hoveredOption = option
                    } else if hoveredOption == option {
                        hoveredOption = nil
                    }
                }
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .overlay {
            Rectangle()
                .fill(Color.primary)
                .matchedGeometryEffect(id: selection, in: underlineNamespace, isSource: false)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

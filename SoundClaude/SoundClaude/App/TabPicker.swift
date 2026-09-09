import SwiftUI

/// Shared, background-free tabs for content selection throughout the app.
struct TabPicker<Selection: Hashable & RawRepresentable>: View where Selection.RawValue == String {
    let title: String
    let options: [Selection]
    @Binding var selection: Selection

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.self) { option in
                let isSelected = selection == option

                Button {
                    selection = option
                } label: {
                    Text(option.rawValue)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(isSelected ? Color.primary : Color.clear)
                                .frame(height: 2)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

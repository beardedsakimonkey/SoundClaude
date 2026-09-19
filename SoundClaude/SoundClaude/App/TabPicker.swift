import SwiftUI

/// Shared, background-free tabs for content selection throughout the app.
struct TabPicker<Selection: Hashable & RawRepresentable>: View where Selection.RawValue == String {
    let title: String
    let options: [Selection]
    @Binding var selection: Selection
    let optionCount: (Selection) -> Int?
    let optionSystemImage: (Selection) -> String?

    init(
        title: String,
        options: [Selection],
        selection: Binding<Selection>,
        optionCount: @escaping (Selection) -> Int? = { _ in nil },
        optionSystemImage: @escaping (Selection) -> String? = { _ in nil }
    ) {
        self.title = title
        self.options = options
        self._selection = selection
        self.optionCount = optionCount
        self.optionSystemImage = optionSystemImage
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var underlineNamespace
    @State private var hoveredOption: Selection?

    private var visibleOptions: [Selection] {
        options.filter { optionCount($0) != 0 }
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(visibleOptions, id: \.self) { option in
                let isSelected = selection == option

                Button {
                    selection = option
                } label: {
                    HStack(spacing: 6) {
                        if let systemImage = optionSystemImage(option) {
                            Image(systemName: systemImage)
                                .accessibilityHidden(true)
                        }
                        ViewThatFits(in: .horizontal) {
                            optionTitle(option, isEmphasized: isSelected || hoveredOption == option)
                                .fixedSize(horizontal: true, vertical: false)
                            Text(option.rawValue)
                        }
                    }
                        .lineLimit(1)
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
                .accessibilityLabel(optionTitle(option, isEmphasized: false))
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
            if visibleOptions.contains(selection) {
                Rectangle()
                    .fill(Color.primary)
                    .matchedGeometryEffect(id: selection, in: underlineNamespace, isSource: false)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: visibleOptions, initial: true) { _, options in
            if !options.contains(selection), let first = options.first {
                selection = first
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func optionTitle(_ option: Selection, isEmphasized: Bool) -> Text {
        let title = Text(option.rawValue)
        guard let count = optionCount(option) else { return title }
        return title + Text(" (\(count.formatted()))")
            .font(.body.weight(.regular))
            .foregroundStyle(isEmphasized ? .secondary : .tertiary)
    }
}

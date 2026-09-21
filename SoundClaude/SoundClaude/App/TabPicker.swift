import SwiftUI

/// Shared, background-free tabs for content selection throughout the app.
struct TabPicker<Selection: Hashable & RawRepresentable>: View where Selection.RawValue == String {
    let title: String
    let options: [Selection]
    @Binding var selection: Selection
    let optionCount: (Selection) -> Int?
    let optionSystemImage: (Selection) -> String?
    let allowsIconOnly: Bool

    init(
        title: String,
        options: [Selection],
        selection: Binding<Selection>,
        optionCount: @escaping (Selection) -> Int? = { _ in nil },
        optionSystemImage: @escaping (Selection) -> String? = { _ in nil },
        allowsIconOnly: Bool = false
    ) {
        self.title = title
        self.options = options
        self._selection = selection
        self.optionCount = optionCount
        self.optionSystemImage = optionSystemImage
        self.allowsIconOnly = allowsIconOnly
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var underlineNamespace
    @State private var hoveredOption: Selection?

    private var visibleOptions: [Selection] {
        options.filter { optionCount($0) != 0 }
    }

    private enum DisplayStyle: String {
        case full
        case withoutCounts
        case iconsOnly
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            tabRow(style: .full)
                .fixedSize(horizontal: true, vertical: false)
            tabRow(style: .withoutCounts)
                .fixedSize(horizontal: true, vertical: false)
            if allowsIconOnly {
                tabRow(style: .iconsOnly)
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

    private func tabRow(style: DisplayStyle) -> some View {
        HStack(spacing: 8) {
            ForEach(visibleOptions, id: \.self) { option in
                let isSelected = selection == option

                Button {
                    selection = option
                } label: {
                    optionLabel(option, style: style, isEmphasized: isSelected || hoveredOption == option)
                        .lineLimit(1)
                        .foregroundStyle(isSelected || hoveredOption == option ? Color.primary : Color.secondary)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: hoveredOption == option)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .overlay(alignment: .bottom) {
                            Color.clear
                                .frame(height: 2)
                                .matchedGeometryEffect(id: [style.rawValue, option.rawValue], in: underlineNamespace)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(optionTitle(option, isEmphasized: false))
                .help(optionTitle(option, isEmphasized: false))
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
                    .matchedGeometryEffect(id: [style.rawValue, selection.rawValue], in: underlineNamespace, isSource: false)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private func optionLabel(_ option: Selection, style: DisplayStyle, isEmphasized: Bool) -> some View {
        HStack(spacing: 6) {
            let systemImage = optionSystemImage(option)
            if let systemImage {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            }
            if style == .full {
                optionTitle(option, isEmphasized: isEmphasized)
            } else if style != .iconsOnly || systemImage == nil {
                Text(option.rawValue)
            }
        }
    }

    private func optionTitle(_ option: Selection, isEmphasized: Bool) -> Text {
        let title = Text(option.rawValue)
        guard let count = optionCount(option) else { return title }
        return title + Text(" (\(count.formatted()))")
            .font(.body.weight(.regular))
            .foregroundStyle(isEmphasized ? .secondary : .tertiary)
    }
}

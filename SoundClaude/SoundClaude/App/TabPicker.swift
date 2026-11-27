import SwiftUI

enum TabPickerStyle: String {
    case full
    case withoutCounts
    case iconsOnly
}

/// Shared, background-free tabs for content selection throughout the app.
struct TabPicker<Selection: Hashable & RawRepresentable>: View where Selection.RawValue == String {
    let title: String
    let options: [Selection]
    @Binding var selection: Selection
    let optionCount: (Selection) -> Int?
    let optionSystemImage: (Selection) -> String?
    let optionText: (Selection) -> String
    let allowsIconOnly: Bool
    /// A style to always use instead of picking the widest that fits, for callers
    /// that fold the tabs into their own `ViewThatFits`.
    let fixedStyle: TabPickerStyle?
    let horizontalPadding: CGFloat
    /// What to warm while a tab other than the selected one is hovered or pressed.
    let prefetch: (Selection) -> PrefetchTarget?

    init(
        title: String,
        options: [Selection],
        selection: Binding<Selection>,
        optionCount: @escaping (Selection) -> Int? = { _ in nil },
        optionSystemImage: @escaping (Selection) -> String? = { _ in nil },
        optionText: @escaping (Selection) -> String = { $0.rawValue },
        allowsIconOnly: Bool = false,
        fixedStyle: TabPickerStyle? = nil,
        horizontalPadding: CGFloat = 12,
        prefetch: @escaping (Selection) -> PrefetchTarget? = { _ in nil }
    ) {
        self.title = title
        self.options = options
        self._selection = selection
        self.optionCount = optionCount
        self.optionSystemImage = optionSystemImage
        self.optionText = optionText
        self.allowsIconOnly = allowsIconOnly
        self.fixedStyle = fixedStyle
        self.horizontalPadding = horizontalPadding
        self.prefetch = prefetch
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var underlineNamespace
    @State private var hoveredOption: Selection?

    private var visibleOptions: [Selection] {
        options.filter { optionCount($0) != 0 }
    }

    var body: some View {
        Group {
            if let fixedStyle {
                tabRow(style: fixedStyle)
            } else {
                ViewThatFits(in: .horizontal) {
                    tabRow(style: .full)
                        .fixedSize(horizontal: true, vertical: false)
                    tabRow(style: .withoutCounts)
                        .fixedSize(horizontal: true, vertical: false)
                    if allowsIconOnly {
                        tabRow(style: .iconsOnly)
                    }
                }
            }
        }
        .onChange(of: visibleOptions, initial: true) { _, options in
            if !options.contains(selection), let first = options.first {
                selection = first
            }
        }
        .animation(reduceMotion ? nil : .timingCurve(0.4, 0, 0.2, 1, duration: 0.3), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func tabRow(style: TabPickerStyle) -> some View {
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
                        .padding(.horizontal, horizontalPadding)
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
                .contentHelp(optionTitle(option, isEmphasized: false))
                .prefetch(isSelected ? nil : prefetch(option)) { isHovering in
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

    private func optionLabel(_ option: Selection, style: TabPickerStyle, isEmphasized: Bool) -> some View {
        HStack(spacing: 6) {
            let systemImage = optionSystemImage(option)
            if let systemImage {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            }
            if style == .full {
                optionTitle(option, isEmphasized: isEmphasized)
            } else if style != .iconsOnly || systemImage == nil {
                Text(optionText(option))
            }
        }
    }

    private func optionTitle(_ option: Selection, isEmphasized: Bool) -> Text {
        let title = Text(optionText(option))
        guard let count = optionCount(option) else { return title }
        return title + Text(" (\(count.formatted()))")
            .font(.body.weight(.regular))
            .foregroundStyle(isEmphasized ? .secondary : .tertiary)
    }
}

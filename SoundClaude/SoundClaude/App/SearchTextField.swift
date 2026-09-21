import SwiftUI

struct SearchTextField: View {
    enum Style {
        case regular
        case compact

        var spacing: CGFloat { self == .regular ? 10 : 8 }
        var padding: CGFloat { self == .regular ? 12 : 10 }
        var cornerRadius: CGFloat { self == .regular ? 10 : 8 }
        var background: AnyShapeStyle {
            self == .regular
                ? AnyShapeStyle(.primary.opacity(0.06))
                : AnyShapeStyle(.quaternary)
        }
    }

    let placeholder: String
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let accessibilityLabel: String
    var style: Style = .regular
    var preventsAutomaticFocus = false
    var onSubmit: () -> Void = {}
    var onClear: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHoveringClear = false

    var body: some View {
        HStack(spacing: style.spacing) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            input
                .onSubmit(onSubmit)
                .onExitCommand {
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        text = ""
                    }
                    isFocused.wrappedValue = false
                }
                .accessibilityLabel(accessibilityLabel)
            if !text.isEmpty {
                Button {
                    text = ""
                    onClear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(isHoveringClear ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
                .onContentHover { isHoveringClear = $0 }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHoveringClear)
                .accessibilityLabel("Clear search")
                .help("Clear search")
                .transition(style == .regular ? .scale(scale: 0.8).combined(with: .opacity) : .identity)
            }
        }
        .animation(reduceMotion || style == .compact ? nil : .easeInOut(duration: 0.2), value: text.isEmpty)
        .padding(style.padding)
        .background {
            RoundedRectangle(cornerRadius: style.cornerRadius)
                .fill(style.background)
                .overlay {
                    RoundedRectangle(cornerRadius: style.cornerRadius)
                        .fill(.white.opacity(isFocused.wrappedValue ? 0.08 : 0))
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isFocused.wrappedValue)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            isFocused.wrappedValue = true
        })
        .background {
            SearchOutsideClickView(isFocused: isFocused.wrappedValue) {
                isFocused.wrappedValue = false
            }
        }
    }

    @ViewBuilder
    private var input: some View {
        let field = TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .focused(isFocused)
        if preventsAutomaticFocus {
            field.modifier(PreventAutomaticSearchFocus())
        } else {
            field
        }
    }
}

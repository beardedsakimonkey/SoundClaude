import AppKit
import SwiftUI

// Arrow keys carry the function-key flag, so AppKit matches them against menu key equivalents
// before the first responder sees them. Route them to a focused text view instead, so the
// seek, track, and volume shortcuts don't swallow caret movement and selection.
enum TextArrowKeys {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard (123...126).contains(event.keyCode),
                  event.modifierFlags.isDisjoint(with: [.command, .control]),
                  let window = event.window, window.isKeyWindow,
                  window.firstResponder is NSText else { return event }
            // Deliver through the window rather than calling the text view's keyDown,
            // which would skip SwiftUI key handlers such as the search suggestions' arrows.
            window.sendEvent(event)
            return nil
        }
    }
}

struct SearchTextField: View {
    enum Style {
        case regular
        case compact

        var spacing: CGFloat { self == .regular ? 10 : 8 }
        var padding: CGFloat { self == .regular ? 12 : 10 }
        var cornerRadius: CGFloat { self == .regular ? 10 : 8 }
    }

    let placeholder: String
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let accessibilityLabel: String
    var style: Style = .regular
    var preventsAutomaticFocus = false
    /// Height of a dropdown below the field in which clicks keep the field focused.
    var dropdownHeight: CGFloat = 0
    var onSubmit: () -> Void = {}
    var onClear: () -> Void = {}
    /// Handles Escape before the field gives up focus. Returns whether it did.
    var onExit: () -> Bool = { false }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHoveringClear = false

    var body: some View {
        HStack(spacing: style.spacing) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            input
                .onSubmit(onSubmit)
                .onExitCommand {
                    if onExit() { return }
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
                .contentHelp("Clear search")
                .transition(style == .regular ? .scale(scale: 0.8).combined(with: .opacity) : .identity)
            }
        }
        .animation(reduceMotion || style == .compact ? nil : .easeInOut(duration: 0.2), value: text.isEmpty)
        .padding(style.padding)
        .background {
            RoundedRectangle(cornerRadius: style.cornerRadius)
                .fill(.primary.opacity(0.06))
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
            SearchOutsideClickView(isFocused: isFocused.wrappedValue, dropdownHeight: dropdownHeight)
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

// Own focus here so entering or leaving the filter does not update its parent page.
// Typing edits a local draft; the parent's text (and its re-filter) follows after a
// short pause, so fast typing doesn't re-render the whole track list per keystroke.
struct TrackFilterField: View {
    @Binding var text: String
    let accessibilityLabel: String

    @FocusState private var isFocused: Bool
    @State private var draft: String

    private static let debounce: Duration = .milliseconds(100)

    init(text: Binding<String>, accessibilityLabel: String) {
        _text = text
        self.accessibilityLabel = accessibilityLabel
        _draft = State(initialValue: text.wrappedValue)
    }

    var body: some View {
        SearchTextField(
            placeholder: "Filter",
            text: $draft,
            isFocused: $isFocused,
            accessibilityLabel: accessibilityLabel,
            style: .compact,
            preventsAutomaticFocus: true
        )
        .onDisappear { isFocused = false }
        // Adopt outside changes (e.g. the page resetting its filter).
        .onChange(of: text) { _, newValue in
            if draft != newValue { draft = newValue }
        }
        .task(id: draft) {
            guard draft != text else { return }
            // Clearing should restore the full list without delay.
            if !draft.isEmpty {
                try? await Task.sleep(for: Self.debounce)
                if Task.isCancelled { return }
            }
            text = draft
        }
    }
}

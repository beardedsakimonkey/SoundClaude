import SwiftUI

struct KeyboardShortcutsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var keyChrome: Color {
        Color(white: colorScheme == .dark ? 0.3 : 0.7)
    }

    private let leftShortcuts = [
        // Playback
        Shortcut(title: "Play or pause", keys: ["Space"]),
        Shortcut(title: "Previous track", keys: ["⇧", "←"]),
        Shortcut(title: "Next track", keys: ["⇧", "→"]),
        Shortcut(title: "Seek back 5 seconds", keys: ["←"]),
        Shortcut(title: "Seek forward 5 seconds", keys: ["→"]),
        Shortcut(title: "Seek back 30 seconds", keys: ["⌥", "←"]),
        Shortcut(title: "Seek forward 30 seconds", keys: ["⌥", "→"]),
        Shortcut(title: "Mute or unmute", keys: ["M"]),
        Shortcut(title: "Increase volume", keys: ["⇧", "↑"]),
        Shortcut(title: "Decrease volume", keys: ["⇧", "↓"]),
        Shortcut(title: "Like or unlike current track", keys: ["L"])
    ]

    private let rightShortcuts = [
        Shortcut(title: "Toggle shuffle", keys: ["⇧", "S"]),
        Shortcut(title: "Cycle repeat", keys: ["R"]),
        Shortcut(title: "Show or hide playback speed", keys: ["X"]),
        Shortcut(title: "Show or hide track queue", keys: ["Q"]),
        Shortcut(title: "Show or hide visualizer", keys: ["V"]),
        Shortcut(title: "Next visualizer effect", keys: ["Enter"]),
        Shortcut(title: "Focus current track", keys: ["F"]),
        Shortcut(title: "Focus current artist", keys: ["A"]),
        Shortcut(title: "Focus current station", keys: ["S"]),
        Shortcut(title: "Search", keys: ["/"]),
        Shortcut(title: "Show or hide keyboard shortcuts", keys: ["?"])
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Keyboard Shortcuts")
                .font(.title2.weight(.semibold))

            ScrollView {
                HStack(alignment: .top, spacing: 32) {
                    shortcutColumn(leftShortcuts)
                    shortcutColumn(rightShortcuts)
                }
                .padding(.trailing, 12)
                .padding(.bottom, 2)
            }
            .frame(maxHeight: 440)

            HStack {
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 820)
        .background {
            Button("Close keyboard shortcuts") {
                dismiss()
            }
            .keyboardShortcut("?", modifiers: [])
            .hidden()
            .accessibilityHidden(true)
        }
        .dismissOnOutsideClick()
    }

    private func shortcutColumn(_ shortcuts: [Shortcut]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            ForEach(shortcuts) { shortcut in
                GridRow {
                    Text(shortcut.title)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 4) {
                        keyCaps(shortcut.keys)
                    }
                    .fixedSize()
                    .gridColumnAlignment(.trailing)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func keyCaps(_ keys: [String]) -> some View {
        ForEach(keys, id: \.self) { key in
            Text(key)
                .font(.system(.callout, design: .monospaced).weight(.medium))
                .frame(minWidth: 24, minHeight: 22)
                .padding(.horizontal, key.count > 1 ? 10 : 4)
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(keyChrome)
                            .offset(y: 3)
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.background)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(keyChrome, lineWidth: 1)
                }
                .padding(.bottom, 3)
        }
    }
}

private struct Shortcut: Identifiable {
    let title: String
    let keys: [String]

    var id: String { title }
}

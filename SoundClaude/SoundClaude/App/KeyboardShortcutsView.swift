import SwiftUI

struct KeyboardShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    private let shortcutGroups = [
        // Playback
        [
            Shortcut(title: "Play or pause", keys: ["Space"]),
            Shortcut(title: "Mute or unmute", keys: ["M"]),
            Shortcut(title: "Increase volume", keys: ["⇧", "↑"]),
            Shortcut(title: "Decrease volume", keys: ["⇧", "↓"]),
            Shortcut(title: "Toggle shuffle", keys: ["⇧", "S"]),
            Shortcut(title: "Cycle repeat", keys: ["R"]),
            Shortcut(title: "Seek back 5 seconds", keys: ["←"]),
            Shortcut(title: "Seek forward 5 seconds", keys: ["→"]),
            Shortcut(title: "Previous track", keys: ["⇧", "←"]),
            Shortcut(title: "Next track", keys: ["⇧", "→"])
        ],
        // Track actions and views
        [
            Shortcut(title: "Like or unlike current track", keys: ["L"]),
            Shortcut(title: "Toggle track queue", keys: ["Q"]),
            Shortcut(title: "Toggle visualizer", keys: ["V"]),
            Shortcut(title: "Cycle shaders in visualizer", keys: ["Enter"]),
            Shortcut(title: "Focus current track", keys: ["F"]),
            Shortcut(title: "Focus current artist", keys: ["A"]),
            Shortcut(title: "Focus active station or playlist", keys: ["S"]),
            Shortcut(title: "Focus search", keys: ["/"])
        ],
        // Number shortcuts / help
        [
            Shortcut(title: "Open search", keys: ["1"]),
            Shortcut(title: "Open feed", keys: ["2"]),
            Shortcut(title: "Open likes", keys: ["3"]),
            Shortcut(title: "Open history", keys: ["4"]),
            Shortcut(title: "Show or hide keyboard shortcuts", keys: ["?"])
        ]
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Keyboard Shortcuts")
                .font(.title2.weight(.semibold))

            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 12) {
                    ForEach(shortcutGroups.indices, id: \.self) { groupIndex in
                        if groupIndex > 0 {
                            Divider()
                                .gridCellUnsizedAxes(.horizontal)
                        }

                        ForEach(shortcutGroups[groupIndex]) { shortcut in
                            GridRow {
                                Text(shortcut.title)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                HStack(spacing: 4) {
                                    keyCaps(shortcut.keys)
                                }
                                .gridColumnAlignment(.trailing)
                            }
                        }
                    }
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
        .frame(width: 420)
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

    private func keyCaps(_ keys: [String]) -> some View {
        ForEach(keys, id: \.self) { key in
            Text(key)
                .font(.system(.callout, design: .monospaced).weight(.medium))
                .frame(minWidth: 24, minHeight: 22)
                .padding(.horizontal, 4)
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.secondary.opacity(0.5))
                            .offset(y: 3)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.background)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(.tertiary, lineWidth: 1)
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

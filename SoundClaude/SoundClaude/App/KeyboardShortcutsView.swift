import SwiftUI

struct KeyboardShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    private let shortcuts = [
        Shortcut(title: "Play or pause", keys: ["Space"]),
        Shortcut(title: "Mute or unmute", keys: ["M"]),
        Shortcut(title: "Seek back 5 seconds", keys: ["←"]),
        Shortcut(title: "Seek forward 5 seconds", keys: ["→"]),
        Shortcut(title: "Previous track", keys: ["⇧", "←"]),
        Shortcut(title: "Next track", keys: ["⇧", "→"]),
        Shortcut(title: "Show keyboard shortcuts", keys: ["?"])
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Keyboard Shortcuts")
                .font(.title2.weight(.semibold))

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 12) {
                ForEach(shortcuts) { shortcut in
                    GridRow {
                        Text(shortcut.title)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        HStack(spacing: 4) {
                            ForEach(shortcut.keys, id: \.self) { key in
                                Text(key)
                                    .font(.system(.body, design: .rounded).weight(.medium))
                                    .frame(minWidth: 24, minHeight: 22)
                                    .padding(.horizontal, 4)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                            }
                        }
                    }
                }
            }

            Divider()

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
    }
}

private struct Shortcut: Identifiable {
    let title: String
    let keys: [String]

    var id: String { title }
}

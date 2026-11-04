import AppKit
import SwiftUI

struct KeyboardShortcutsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var pressedKeys: Set<String> = []

    private var keyChrome: Color {
        Color(white: colorScheme == .dark ? 0.3 : 0.7)
    }

    private let leftShortcuts = [
        // Playback
        Shortcut(title: "Play or pause", keys: ["Space"]),
        Shortcut(title: "Previous track", keys: ["P"], alternateKeys: ["⇧", "←"]),
        Shortcut(title: "Next track", keys: ["N"], alternateKeys: ["⇧", "→"]),
        Shortcut(title: "Seek back 5 seconds", keys: ["J"], alternateKeys: ["←"]),
        Shortcut(title: "Seek forward 5 seconds", keys: ["K"], alternateKeys: ["→"]),
        Shortcut(title: "Seek back 30 seconds", keys: ["⌥", "←"]),
        Shortcut(title: "Seek forward 30 seconds", keys: ["⌥", "→"]),
        Shortcut(title: "Mute or unmute", keys: ["M"]),
        Shortcut(title: "Increase volume", keys: ["U"], alternateKeys: ["⇧", "↑"]),
        Shortcut(title: "Decrease volume", keys: ["D"], alternateKeys: ["⇧", "↓"]),
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
        .background {
            ShortcutForwardingView(
                onPressedKeysChange: { pressedKeys = $0 },
                onDismiss: { dismiss() }
            )
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
                        if let alternateKeys = shortcut.alternateKeys {
                            Text("or")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                            keyCaps(alternateKeys)
                        }
                    }
                    .fixedSize()
                    .gridColumnAlignment(.trailing)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func keyCaps(_ keys: [String]) -> some View {
        // Light up only the exact combination, so S and ⇧S stay distinct.
        let isPressed = pressedKeys == Set(keys)
        return ForEach(keys, id: \.self) { key in
            Text(key)
                .font(.system(.callout, design: .monospaced).weight(.medium))
                .foregroundStyle(isPressed ? Color.white : Color.primary)
                .frame(minWidth: 24, minHeight: 22)
                .padding(.horizontal, key.count > 1 ? 10 : 4)
                .background {
                    if isPressed {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.accentColor)
                    } else {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.background)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(keyChrome, lineWidth: 1)
                }
                .offset(y: isPressed ? 2 : 0)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(keyChrome)
                        .offset(y: 3)
                }
                .padding(.bottom, 3)
        }
    }
}

// The sheet is the key window, so shortcuts on views in its parent window never see these keys.
private struct ShortcutForwardingView: NSViewRepresentable {
    let onPressedKeysChange: (Set<String>) -> Void
    let onDismiss: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onPressedKeysChange = onPressedKeysChange
        view.onDismiss = onDismiss
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onPressedKeysChange = onPressedKeysChange
        nsView.onDismiss = onDismiss
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class MonitorView: NSView {
        var onPressedKeysChange: ((Set<String>) -> Void)?
        var onDismiss: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) {
                [weak self] event in
                self?.handle(event) ?? nil
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            // A shortcut can open a window that takes the key up, so accept it from anywhere.
            guard event.type == .keyDown else {
                onPressedKeysChange?([])
                return event
            }
            guard let sheet = window,
                  event.window === sheet,
                  let parent = sheet.sheetParent,
                  event.modifierFlags.isDisjoint(with: [.command, .control]) else {
                return event
            }

            let keys = Self.keys(for: event)
            onPressedKeysChange?(keys)

            // Esc must close the sheet, even when the parent has its own cancel button.
            if sheet.performKeyEquivalent(with: event) { return nil }
            let isHandled = parent.performKeyEquivalent(with: event)
            // Search needs keyboard focus, which the parent only gets once the sheet closes.
            if keys == ["/"] { onDismiss?() }
            // Unhandled keys continue on to the menu bar.
            return isHandled ? nil : event
        }

        private static func keys(for event: NSEvent) -> Set<String> {
            var keys: Set<String> = []
            if event.modifierFlags.contains(.shift) { keys.insert("⇧") }
            if event.modifierFlags.contains(.option) { keys.insert("⌥") }
            switch event.keyCode {
            case 36, 76: keys.insert("Enter")
            case 49: keys.insert("Space")
            case 123: keys.insert("←")
            case 124: keys.insert("→")
            case 125: keys.insert("↓")
            case 126: keys.insert("↑")
            default:
                if let key = event.charactersIgnoringModifiers?.uppercased() { keys.insert(key) }
            }
            return keys
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            stopMonitoring()
        }
    }
}

private struct Shortcut: Identifiable {
    let title: String
    let keys: [String]
    var alternateKeys: [String]? = nil

    var id: String { title }
}

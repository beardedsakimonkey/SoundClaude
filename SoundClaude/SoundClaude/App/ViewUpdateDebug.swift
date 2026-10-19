#if DEBUG
import SwiftUI

/// The preference is observed only by the menu and overlays, not by app content.
struct ViewUpdateDebugCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @AppStorage("debug.highlightViewUpdates") private var isEnabled = false
    @AppStorage("debug.showArtworkQueues") private var showsArtworkQueues = false

    var body: some Commands {
        CommandMenu("Debug") {
            Button("Network Activity") { openWindow(id: "network-activity") }
                .keyboardShortcut("n", modifiers: [.command, .option, .shift])
            Toggle("Artwork Prefetching", isOn: $showsArtworkQueues)
            Toggle("Highlight View Updates", isOn: $isEnabled)
                .keyboardShortcut("u", modifiers: [.command, .option, .shift])
        }
    }
}

extension View {
    /// Call from the view's own body so the color samples that body's evaluations.
    /// This diagnoses body evaluation, not layout passes or GPU redraws.
    func debugViewUpdates(_ name: String) -> some View {
        let color = Color(hue: .random(in: 0..<1), saturation: 0.85, brightness: 1)
        return overlay {
            ViewUpdateDebugOverlay(name: name, color: color)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

private struct ViewUpdateDebugOverlay: View {
    let name: String
    let color: Color
    @AppStorage("debug.highlightViewUpdates") private var isEnabled = false

    var body: some View {
        if isEnabled {
            Rectangle()
                .strokeBorder(color, lineWidth: 2)
                .overlay(alignment: .topLeading) {
                    Text(name)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .padding(2)
                        .foregroundStyle(.black)
                        .background(color)
                }
                // Do not interpolate colors during the app's own animations.
                .transaction { $0.animation = nil }
        }
    }
}
#endif

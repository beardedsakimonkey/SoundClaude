#if DEBUG
import Observation
import SwiftUI

// Shared by the menu and overlays; outlines start disabled on each app launch.
@MainActor
@Observable
private final class ViewUpdateDebugSettings {
    static let shared = ViewUpdateDebugSettings()
    var isEnabled = false
}

/// Debug state is observed only by the menu and overlays, not by app content.
struct ViewUpdateDebugCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Bindable private var settings = ViewUpdateDebugSettings.shared
    @AppStorage("debug.showArtworkQueues") private var showsArtworkQueues = false

    var body: some Commands {
        CommandMenu("Debug") {
            Toggle("Highlight View Updates", isOn: $settings.isEnabled)
                .keyboardShortcut("u", modifiers: [.command, .option, .shift])
            Toggle("Artwork Prefetching", isOn: $showsArtworkQueues)
                .keyboardShortcut("a", modifiers: [.command, .option, .shift])
            Button("Network Activity") { openWindow(id: "network-activity") }
                .keyboardShortcut("n", modifiers: [.command, .option, .shift])
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
    private let settings = ViewUpdateDebugSettings.shared

    var body: some View {
        if settings.isEnabled {
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

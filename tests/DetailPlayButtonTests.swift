import AppKit
import SwiftUI

private final class ButtonLifetime: ObservableObject {
    static var creations = 0
    init() { Self.creations += 1 }
}

struct TrackActionButtonStyle: ButtonStyle {
    let fill: Color
    @StateObject private var lifetime = ButtonLifetime()

    func makeBody(configuration: Configuration) -> some View {
        let _ = lifetime
        configuration.label.padding(.vertical, 10).background(fill, in: Capsule())
    }
}

extension View {
    func contentHelp(_ text: String) -> some View { help(text) }
}

@main struct DetailPlayButtonTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            await runTests()
            exit(0)
        }
        app.run()
    }

    @MainActor static func runTests() async {
        var selectedRoute: Int?
        func page(route: Int, enabled: Bool = true, iconOnly: Bool = false) -> some View {
            CurrentNavigationPage(route: route) {
                Color.clear
            } destination: { route in
                VStack(alignment: .leading) {
                    DetailPlayButtonSlot(configuration: DetailPlayButtonConfiguration(
                        trackURN: "same", isCollection: route != 0,
                        isStarting: route != 0, isPlaying: false,
                        isEnabled: enabled, iconOnly: iconOnly
                    )) { selectedRoute = route }
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, route == 0 ? 24 : 60)
            }
            .modifier(DetailPlayButtonOverlay())
        }
        let host = NSHostingView(rootView: page(route: 0))
        host.frame.size = CGSize(width: 600, height: 400)
        func layout() async {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
            host.layoutSubtreeIfNeeded()
        }
        await layout()
        precondition(ButtonLifetime.creations == 2)
        for route in [1, 0, 2, 0] {
            let before = ButtonLifetime.creations
            host.rootView = page(route: route)
            await layout()
            precondition(ButtonLifetime.creations == before + 1,
                         "Only the hidden sizing button should remount during navigation")
        }
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        for (route, enabled, iconOnly) in [(1, true, false), (2, true, true), (0, true, false), (2, false, false)] {
            host.rootView = page(route: route, enabled: enabled, iconOnly: iconOnly)
            selectedRoute = nil
            await layout()
            try? await Task.sleep(for: .milliseconds(400))
            let point = host.convert(NSPoint(x: 20, y: route == 0 ? 44 : 80), to: nil)
            // A native button can track mouse-up within its mouse-down handler.
            for type in [NSEvent.EventType.leftMouseUp, .leftMouseDown] {
                let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: 1
                )!
                if type == .leftMouseUp {
                    NSApplication.shared.postEvent(event, atStart: true)
                } else {
                    NSApplication.shared.sendEvent(event)
                }
            }
            await layout()
            precondition(selectedRoute == (enabled ? route : nil),
                         "The shared button must use the current page's action and enabled state")
        }
        window.orderOut(nil)
        print("Detail play button lifetime, actions, compact layout, and disabled state tests passed")
    }
}

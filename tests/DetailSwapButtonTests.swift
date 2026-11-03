import AppKit
import SwiftUI

private final class ButtonLifetime: ObservableObject {
    static var alive = 0
    init() { Self.alive += 1 }
    deinit { Self.alive -= 1 }
}

private struct TestButton: View {
    let action: () -> Void
    @StateObject private var lifetime = ButtonLifetime()

    var body: some View {
        let _ = lifetime
        Button(action: action) { Color.blue }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
    }
}

@main struct DetailSwapButtonTests {
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
        var clicked: String?
        // Track pages have one swap button and collection pages have two.
        func page(route: Int, trackURN: String = "same") -> some View {
            CurrentNavigationPage(route: route) {
                Color.clear
            } destination: { route in
                let isCollection = route != 0
                HStack(spacing: 12) {
                    ForEach(isCollection ? ["shuffle", "next"] : ["repost"], id: \.self) { id in
                        TestButton { clicked = "\(route):\(id)" }
                            .detailSwapSlot(id: id, trackURN: trackURN, isCollection: isCollection)
                    }
                    Spacer()
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(24)
            }
            .modifier(DetailSwapButtonOverlay(routeID: route))
        }
        let host = NSHostingView(rootView: page(route: 0))
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        func wait(_ milliseconds: Int) async {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(milliseconds))
            host.layoutSubtreeIfNeeded()
        }
        func click(x: CGFloat) async {
            let point = NSPoint(x: x, y: host.bounds.height - 46)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                )!)
            }
            await wait(50)
        }
        await wait(100)
        // Each button has a visible copy and a hidden sizing copy.
        precondition(ButtonLifetime.alive == 2, "Track page has \(ButtonLifetime.alive) copies")

        // Between layouts for one track, the old button outlives its page to scale away.
        host.rootView = page(route: 1)
        await wait(100)
        precondition(ButtonLifetime.alive == 5,
                     "The old visible button should remain while the new buttons mount: \(ButtonLifetime.alive)")
        await wait(1_500)
        precondition(ButtonLifetime.alive == 4, "The old button should finish leaving: \(ButtonLifetime.alive)")

        await click(x: 46)
        precondition(clicked == "1:shuffle", "Clicked \(clicked ?? "nothing")")
        await click(x: 102)
        precondition(clicked == "1:next", "Clicked \(clicked ?? "nothing")")

        // A button in both collection layouts stays mounted and calls the current page.
        host.rootView = page(route: 2)
        await wait(100)
        precondition(ButtonLifetime.alive == 4, "Shared buttons should not swap: \(ButtonLifetime.alive)")
        await click(x: 46)
        precondition(clicked == "2:shuffle", "Clicked \(clicked ?? "nothing")")

        // Going back reverses the swap.
        host.rootView = page(route: 0)
        await wait(100)
        precondition(ButtonLifetime.alive == 4, "Both old visible buttons should remain: \(ButtonLifetime.alive)")
        await wait(1_500)
        precondition(ButtonLifetime.alive == 2, "The old buttons should finish leaving: \(ButtonLifetime.alive)")

        // A different track replaces the buttons without a swap.
        host.rootView = page(route: 1, trackURN: "other")
        await wait(100)
        precondition(ButtonLifetime.alive == 4, "A new track should not animate: \(ButtonLifetime.alive)")
        window.orderOut(nil)
        print("Detail swap button lifetime and action tests passed")
    }
}

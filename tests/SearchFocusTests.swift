import AppKit
import SwiftUI

private struct FilterFixture: View {
    @State private var text = "Keep this query"
    @FocusState private var focused: Bool

    var body: some View {
        VStack {
            TextField("Filter", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .modifier(PreventAutomaticSearchFocus())
                .padding(10)
                .background {
                    SearchOutsideClickView(isFocused: focused) { focused = false }
                }
            Color.gray.frame(height: 200)
        }
        .padding()
    }
}

@main
private struct SearchFocusTests {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 500, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let host = NSHostingView(rootView: FilterFixture())
        window.contentView = host
        window.makeKeyAndOrderFront(nil)

        func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            return view.subviews.lazy.compactMap { descendant(type, in: $0) }.first
        }
        func click(_ point: NSPoint) {
            // Queue mouse-up first: text editing tracks it inside mouseDown.
            for type in [NSEvent.EventType.leftMouseUp, .leftMouseDown] {
                let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: 1
                )!
                if type == .leftMouseUp {
                    app.postEvent(event, atStart: true)
                } else {
                    app.sendEvent(event)
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let field = descendant(NSTextField.self, in: host)!
            precondition(field.currentEditor() == nil, "Filter must start without focus")
            precondition(field.isEnabled, "Filter must allow input after appearing")
            precondition(window.makeFirstResponder(field))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let monitor = descendant(SearchOutsideClickView.MonitorView.self, in: host)!
                precondition(monitor.isFocused, "Fixture must focus the filter")
                click(field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil))
                precondition(field.currentEditor() != nil, "Inside click must keep editing")
                click(NSPoint(x: 250, y: 100))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    precondition(field.currentEditor() == nil, "Outside click must end editing")
                    precondition(!monitor.isFocused, "Outside click must clear SwiftUI focus")
                    precondition(field.stringValue == "Keep this query", "Dismissal must retain the query")
                    let user = SoundCloudUser(
                        urn: "soundcloud:users:focus-test", username: "Focus test",
                        avatarURL: nil, permalinkURL: URL(string: "https://soundcloud.com/focus-test")!
                    )
                    let searchHost = NSHostingView(rootView: SearchView(
                        user: user, searchText: .constant(""), focusRequest: UUID(),
                        results: { Text("Results for \($0)") }
                    ))
                    window.contentView = searchHost
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        let searchField = descendant(NSTextField.self, in: searchHost)!
                        precondition(searchField.currentEditor() != nil, "Search route must focus its input on arrival")
                        click(NSPoint(x: 250, y: 100))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            precondition(searchField.currentEditor() == nil, "Outside click must release search focus")
                            searchHost.rootView = SearchView(
                                user: user, searchText: .constant(""), focusRequest: UUID(),
                                results: { Text("Results for \($0)") }
                            )
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                precondition(searchField.currentEditor() != nil, "Reselecting Search must restore input focus")
                                print("Search focus tests passed")
                                app.terminate(nil)
                            }
                        }
                    }
                }
            }
        }
        app.run()
    }
}

import AppKit
import Observation
import SwiftUI

@Observable
private final class SuggestionHarness {
    let model = SearchFieldModel(focusRequest: UUID())
    var searches: [String] = []
    var opened: [SoundCloudSearchResult] = []
    var requests: [String] = []
}

private let artist = SoundCloudUser(
    urn: "soundcloud:users:1", username: "Artist",
    avatarURL: nil, permalinkURL: URL(string: "https://soundcloud.com/artist")!
)
private let track = SoundCloudTrack(
    urn: "soundcloud:tracks:1", title: "Track", artist: artist, artworkURL: nil, waveformURL: nil,
    permalinkURL: URL(string: "https://soundcloud.com/artist/track")!,
    durationMilliseconds: 1_000, access: .playable, secretToken: nil
)

private struct SuggestionFixture: View {
    let harness: SuggestionHarness

    /// Stands in for the toolbar's space below the field.
    static let fieldPadding: CGFloat = 20

    var body: some View {
        let actions = SearchFieldActions(
            onSearch: { harness.searches.append($0) },
            onSelectResult: { harness.opened.append($0) }
        )
        // As in the app: the field above the page, the suggestions over the page.
        VStack(spacing: 0) {
            SearchField(
                model: harness.model,
                suggest: { query in
                    harness.requests.append(query)
                    return SoundCloudSearchSuggestions(
                        queries: ["one", "two", "three"].map { "\(query) \($0)" },
                        results: [.user(artist), .track(track)]
                    )
                },
                actions: actions
            )
            .frame(width: 320)
            .padding(Self.fieldPadding)
            SearchSuggestionDropdown(model: harness.model, artworkLoader: ArtworkLoader(), actions: actions)
        }
    }
}

// The app only routes arrow keys in its key window. Claiming that here keeps the suite
// from having to activate, which would take the keyboard from whoever is running it.
private final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@main
private struct SearchSuggestionTests {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = KeyWindow(
            contentRect: NSRect(x: 100, y: 100, width: 600, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let harness = SuggestionHarness()
        let host = NSHostingView(rootView: SuggestionFixture(harness: harness))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        // The app routes arrow keys to text views itself; the suggestions must work with that.
        TextArrowKeys.install()

        func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            return view.subviews.lazy.compactMap { descendant(type, in: $0) }.first
        }
        func pause() async {
            try? await Task.sleep(for: .milliseconds(400))
        }
        func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code
                )!
                // Arrows go by way of the app's monitors; an inactive app drops other keys.
                if (123...126).contains(code) {
                    app.sendEvent(event)
                } else {
                    window.sendEvent(event)
                }
            }
        }
        // Keys arrive on separate turns of the run loop, as they do from a keyboard.
        func press(_ code: UInt16, _ characters: String) async {
            key(code, characters)
            try? await Task.sleep(for: .milliseconds(50))
        }
        func down() async { await press(125, "\u{F701}") }
        func up() async { await press(126, "\u{F700}") }
        func enter() async { await press(36, "\r") }
        func escape() async { await press(53, "\u{1B}") }
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

        Task { @MainActor in
            await pause()
            let field = descendant(NSTextField.self, in: host)!
            /// Focus arrives a few run loop turns after it is requested, more under load.
            @MainActor func focused() async {
                for _ in 0..<60 where field.currentEditor() == nil {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                precondition(field.currentEditor() != nil, "A focus request must focus the search field")
            }
            /// Focuses the field and replaces its text the way typing does.
            @MainActor func type(_ text: String) async {
                harness.model.focusRequest = UUID()
                await focused()
                let editor = field.currentEditor() as! NSTextView
                editor.selectAll(nil)
                editor.insertText(text, replacementRange: editor.selectedRange())
                // Wait for the debounced request, then for the list to draw.
                let query = text.trimmingCharacters(in: .whitespaces)
                for _ in 0..<60 where harness.requests.last != query {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                await pause()
            }

            await focused()
            await down()
            await enter()
            await pause()
            precondition(harness.requests.isEmpty && harness.searches.isEmpty, "An empty field must suggest nothing")

            await type(" fo ")
            precondition(harness.requests == ["fo"], "Suggestions must be requested for the trimmed text")
            await down()
            await enter()
            await pause()
            precondition(harness.searches == ["fo one"], "Down then Return must search the first suggestion")
            precondition(harness.model.text == "fo one", "The field must show the suggestion that was searched")
            precondition(field.currentEditor() == nil, "Searching must release focus")

            // The searched text is still in the field, as it is on going Back to Search.
            harness.requests = []
            harness.model.focusRequest = UUID()
            await focused()
            await pause()
            precondition(harness.requests.isEmpty, "Restored text must not open suggestions")
            await down()
            await enter()
            await pause()
            precondition(harness.searches.last == "fo one", "Return must search the restored text")

            await type("ba")
            for _ in 1...4 { await down() }
            await enter()
            await pause()
            precondition(harness.opened == [.user(artist)], "Return on a top result must open it")
            precondition(harness.searches.last == "fo one" && harness.model.text == "ba", "Opening a result must not search")
            precondition(field.currentEditor() == nil, "Opening a result must release focus")

            await type("pa")
            for _ in 1...6 { await down() }
            await enter()
            await pause()
            precondition(harness.searches.last == "pa", "Stepping past the last suggestion must return to the typed text")

            await type("up")
            await up()
            await enter()
            await pause()
            precondition(harness.opened.last == .track(track), "Up must select the last suggestion")
            await type("un")
            await up()
            await up()
            await up()
            await enter()
            await pause()
            precondition(harness.searches.last == "un three", "Up must step from the results into the completions")

            await type("caret")
            let editor = field.currentEditor() as! NSTextView
            await press(123, "\u{F702}")
            precondition(editor.selectedRange() == NSRange(location: 4, length: 0), "Left must still move the caret")
            key(123, "\u{F702}", modifiers: .shift)
            precondition(editor.selectedRange() == NSRange(location: 3, length: 1), "Shift-Left must still select")
            await escape()
            await escape()
            await pause()
            precondition(field.currentEditor() == nil)

            await type("es")
            let searchCount = harness.searches.count
            await down()
            await escape()
            await pause()
            precondition(field.currentEditor() != nil, "Escape must close the suggestions before releasing focus")
            await down()
            await enter()
            await pause()
            precondition(harness.searches.count == searchCount + 1 && harness.searches.last == "es",
                         "Closed suggestions must not be selectable")

            await type("cl")
            // Rows start below the field's 7pt padding, the fixture's padding, the gap above
            // the list, and the list's 6pt padding: three 30pt completions, then 54pt results.
            let fieldFrame = field.convert(field.bounds, to: nil)
            let rowsTop = fieldFrame.minY - 7 - SuggestionFixture.fieldPadding - SearchSuggestionDropdown.gap - 6
            click(NSPoint(x: fieldFrame.midX, y: rowsTop - 45))
            await pause()
            precondition(harness.searches.last == "cl two", "Clicking a completion must search it")

            await type("re")
            let openedCount = harness.opened.count
            click(NSPoint(x: fieldFrame.midX, y: rowsTop - 90 - 54 - 27))
            await pause()
            precondition(harness.opened.count == openedCount + 1 && harness.opened.last == .track(track),
                         "Clicking a top result must open it")
            precondition(harness.searches.last == "cl two", "Opening a result must not search")

            await type("ou")
            // Where the third row was: the closed list must not keep taking clicks.
            await escape()
            click(NSPoint(x: fieldFrame.midX, y: rowsTop - 75))
            await pause()
            precondition(field.currentEditor() == nil, "Outside click must still release focus")
            precondition(harness.searches.last == "cl two", "A closed list must not search")

            print("Search suggestion tests passed")
            app.terminate(nil)
        }
        app.run()
    }
}

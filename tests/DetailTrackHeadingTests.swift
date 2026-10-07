import AppKit
import SwiftUI

struct SoundCloudUser { let username: String }
struct SoundCloudTrack {
    let urn: String
    let title: String
    let artist: SoundCloudUser
    var createdAt: String? = nil
}
struct ArtworkLoader {}
struct ArtistLink: View {
    let artist: SoundCloudUser
    var artworkLoader: ArtworkLoader? = nil
    var showsAvatarBorder = false
    let onSelect: (SoundCloudUser) -> Void
    @StateObject private var lifetime = HeadingLifetime()
    var body: some View { let _ = lifetime; Button(artist.username) { onSelect(artist) }.lineLimit(1) }
}
extension View {
    func onContentHover(_ action: @escaping (Bool) -> Void) -> some View { onHover(perform: action) }
    func contentHelp(_ text: String) -> some View { help(text) }
}

private final class HeadingLifetime: ObservableObject {
    static var creations = 0
    init() { Self.creations += 1 }
}

@main struct DetailTrackHeadingTests {
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
        let track = SoundCloudTrack(urn: "seed", title: "Track title", artist: .init(username: "Artist"))
        var selectedTrackURN: String?
        func page(collection: Bool, showsHeading: Bool = true) -> some View {
            CurrentNavigationPage(route: collection ? 1 : 0) {
                Color.clear
            } destination: { route in
                VStack {
                    if showsHeading {
                        DetailTrackHeadingSlot(
                            track: track, isCollection: route == 1, artworkLoader: ArtworkLoader(),
                            onSelectTrack: { selectedTrackURN = $0.urn }, onSelectArtist: { _ in }
                        )
                    }
                    Spacer()
                }
                .padding(.top, collection ? 60 : 24)
            }
            .modifier(DetailTrackHeadingOverlay(artworkLoader: ArtworkLoader()))
        }
        let host = NSHostingView(rootView: page(collection: false))
        host.frame.size = CGSize(width: 600, height: 400)
        func layout() async {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(40))
            host.layoutSubtreeIfNeeded()
        }
        await layout()
        precondition(HeadingLifetime.creations == 2, "Expected a hidden sizing heading and a visible heading")
        for collection in [true, false, true, false] {
            let before = HeadingLifetime.creations
            host.rootView = page(collection: collection)
            await layout()
            precondition(HeadingLifetime.creations == before + 1,
                         "Only the route's hidden sizing heading should remount; the visible artist must survive")
        }
        host.rootView = page(collection: false, showsHeading: false)
        await layout()
        let before = HeadingLifetime.creations
        host.rootView = page(collection: false)
        await layout()
        precondition(HeadingLifetime.creations == before + 2, "Leaving detail pages should release the heading")
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        host.rootView = page(collection: true)
        await layout()
        try? await Task.sleep(for: .milliseconds(400))
        let point = host.convert(NSPoint(x: 40, y: 74), to: nil)
        // Selectable text can consume clicks, so exercise the actual mouse path.
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1
            )!
            NSApplication.shared.sendEvent(event)
            try? await Task.sleep(for: .milliseconds(50))
        }
        await layout()
        precondition(selectedTrackURN == track.urn, "Clicking the collection title must open its track")
        window.orderOut(nil)
        print("Detail heading lifetime and collection title click tests passed")
    }
}

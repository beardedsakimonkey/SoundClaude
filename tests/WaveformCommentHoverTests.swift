import AppKit
import SwiftUI

struct SoundCloudTrack { let urn: String }
struct SoundCloudUser { let username: String; var avatarURL: URL? = nil }
struct SoundCloudComment: Identifiable {
    let id: String
    let body: String
    let user: SoundCloudUser?
    let timestampMilliseconds: Int?
}
struct CommentPage { let comments: [SoundCloudComment]; var nextURL: URL? = nil }
final class ArtworkLoader {}
@Observable final class PlaybackController {
    var currentTrack: SoundCloudTrack? = nil
    var isPlaying = false
    var currentTime: Double = 0
}
final class AppModel {
    let artworkLoader = ArtworkLoader()
    let playback = PlaybackController()
    func trackComments(for track: SoundCloudTrack, pageURL: URL?) async throws -> CommentPage {
        CommentPage(comments: [
            SoundCloudComment(id: "left", body: "A comment to hover", user: SoundCloudUser(username: "Left artist"), timestampMilliseconds: 25000),
            SoundCloudComment(id: "neighbor", body: "A nearby comment", user: SoundCloudUser(username: "Nearby artist"), timestampMilliseconds: 30000),
            SoundCloudComment(id: "right", body: "Another comment to hover", user: SoundCloudUser(username: "Right artist"), timestampMilliseconds: 75000)
        ])
    }
}
struct TrackArtworkView: View {
    let artworkURL: URL?
    let loader: ArtworkLoader
    let size: CGFloat
    var showsBorder = false
    var animatesChanges = false
    var showsPlaceholderIcon = false
    var body: some View { Color.orange.frame(width: size, height: size) }
}
private enum Observations {
    static var names: Set<String> = []
    static var frames: [String: CGRect] = [:]
    static var selected: String?
}
// Observe bubble lifetime and its navigation action without networking or artwork.
struct ArtistLink: View {
    let artist: SoundCloudUser
    let onSelect: (SoundCloudUser) -> Void
    var body: some View {
        Button(artist.username) { onSelect(artist) }
            .buttonStyle(.plain)
            .onAppear { Observations.names.insert(artist.username) }
            .onDisappear { Observations.names.remove(artist.username) }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("test")) } action: {
                Observations.frames[artist.username] = $0
            }
    }
}
@main struct WaveformCommentHoverTests {
    @MainActor static func main() {
        guard CGPreflightPostEventAccess() else {
            print("SKIPPED: mouse event access is required")
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let previousApp = NSWorkspace.shared.frontmostApplication
        let originalPointer = CGEvent(source: nil)?.location
        let model = AppModel()
        let root = VStack(spacing: 0) {
            WaveformCommentsView(track: SoundCloudTrack(urn: "test"), model: model,
                                 duration: 100, showsComments: true, onSeek: { _ in })
                .frame(height: 32)
            Spacer()
        }
        .padding(.top, 40)
        .coordinateSpace(name: "test")
        .environment(\.waveformCommentArtistAction, { Observations.selected = $0.username })
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 150, y: 150, width: 600, height: 250),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.acceptsMouseMovedEvents = true
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        func settle() async { try? await Task.sleep(for: .milliseconds(400)) }
        func post(_ type: CGEventType, _ point: CGPoint) async {
            let local = host.convert(point, to: nil)
            let screen = window.convertPoint(toScreen: local)
            let global = CGPoint(x: screen.x, y: NSScreen.screens[0].frame.height - screen.y)
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: global,
                    mouseButton: .left)!.post(tap: .cghidEventTap)
            await settle()
        }
        Task { @MainActor in
            for _ in 0..<20 {
                if app.isActive { break }
                await settle()
            }
            precondition(app.isActive, "Test window must be active")
            await post(.mouseMoved, CGPoint(x: 300, y: 200))
            await settle()
            for (name, x) in [("Left artist", 150.0), ("Right artist", 450.0)] {
                await post(.mouseMoved, CGPoint(x: x, y: 56))
                precondition(Observations.names.contains(name), "Avatar must show its comment")
                if name == "Left artist" {
                    // The old full-width bridge captured this neighboring avatar.
                    await post(.mouseMoved, CGPoint(x: 180, y: 65))
                    precondition(Observations.names == ["Nearby artist"], "Nearby avatar must be selectable")
                    await post(.mouseMoved, CGPoint(x: x, y: 65))
                    precondition(Observations.names == [name], "Original avatar must be selectable again")
                }
                // Move slowly through the narrow bridge, with a small horizontal offset.
                await post(.mouseMoved, CGPoint(x: x + 10, y: 75))
                precondition(Observations.names.contains(name), "Comment disappeared in the gap")
                let frame = Observations.frames[name]!
                let target = CGPoint(x: frame.midX, y: frame.midY)
                await post(.mouseMoved, target)
                precondition(Observations.names.contains(name), "Comment disappeared over the name")
                await post(.mouseMoved, CGPoint(x: frame.maxX + 40, y: frame.midY))
                precondition(Observations.names.contains(name), "Comment disappeared over the text")
                model.playback.currentTrack = SoundCloudTrack(urn: "test")
                model.playback.isPlaying = true
                model.playback.currentTime = x < 300 ? 75 : 25
                await settle()
                precondition(Observations.names == [name], "Playback must not replace a hovered comment")
                await post(.mouseMoved, target)
                await post(.leftMouseDown, target)
                await post(.leftMouseUp, target)
                precondition(Observations.selected == name, "Name must navigate to the artist")
                model.playback.isPlaying = false
                await post(.mouseMoved, CGPoint(x: 300, y: 200))
                precondition(Observations.names.isEmpty, "Comment must close after leaving")
            }
            window.orderOut(nil)
            if let originalPointer {
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: originalPointer,
                        mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            previousApp?.activate()
            print("Waveform comment hover and artist navigation tests passed")
            app.terminate(nil)
        }
        app.run()
    }
}

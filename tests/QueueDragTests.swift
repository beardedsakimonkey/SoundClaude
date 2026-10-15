import AppKit
import SwiftUI

// Run with make test-queue-drag. Uses a temporary window and mouse events.
// Test doubles keep this UI regression independent of playback and accounts.

// Use the real title inset modifier so row movement cannot silently lose its animation.
final class SpectrumAnalyzer {
    func playbackIndicatorLevels() -> [Float]? { nil }
}
extension EnvironmentValues {
    @Entry var contentAnimationsPaused = false
}
private enum TitleAnimationProbe {
    static var animatedURNs: Set<String> = []
}

struct SoundCloudUser {}
struct SoundCloudTrack: Identifiable, Equatable, Codable {
    var urn: String
    var title: String
    var id: String { urn }
}
struct SoundCloudTrackPage { var tracks: [SoundCloudTrack]; var nextURL: URL? }
enum SoundCloudError: Error { case invalidData }
final class LikesController: ObservableObject { @Published var tracks: [SoundCloudTrack] = [] }
final class Playback: ObservableObject { var currentTrack: SoundCloudTrack? }
final class AppModel: ObservableObject {
    @Published var queue = TrackQueue(source: .single, tracks: (1...5).map { SoundCloudTrack(urn: "track:\($0)", title: "Track \($0)") })
    let likes = LikesController()
    let playback = Playback()
    let analyzer = 0
    let artworkLoader = 0
    var moves = 0
    func moveQueueTracks(fromOffsets: IndexSet, toOffset: Int) {
        moves += 1
        queue.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }
    var clearCalls = 0
    func clearQueue() { clearCalls += 1 }
    func removeFromQueue(_ track: SoundCloudTrack) {}
    func play(_ track: SoundCloudTrack) async {}
}
struct TrackListRow: View {
    let track: SoundCloudTrack
    let playback: Playback
    let analyzer: Int
    let artworkLoader: Int
    let likes: LikesController
    let onRemoveFromQueue: (SoundCloudTrack) -> Void
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    let onPlayTrack: (SoundCloudTrack) async -> Void
    var body: some View {
        Text(track.title)
            .transaction { transaction in
                if transaction.animation != nil {
                    TitleAnimationProbe.animatedURNs.insert(track.urn)
                }
            }
            .modifier(TrackPlaybackTitleInset(inset: 0))
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 56)
    }
}

private struct PanelContentProbe: View {
    static var bodyUpdates = 0

    var body: some View {
        Self.bodyUpdates += 1
        return Text("Queue content")
    }
}

@main
struct QueueDragTests {
    @MainActor
    static func main() {
        let layout = QueuePanelLayout()
        let bounds = CGSize(width: 600, height: 500)
        // The panel may cross the sides and bottom, but its drag area must
        // remain reachable, including after the app window gets smaller.
        layout.move(CGSize(width: -2000, height: 2000), in: bounds)
        layout.endGesture()
        let leftFrame = layout.fittedFrame(in: bounds)
        precondition(leftFrame.minX < 0 && leftFrame.maxY > bounds.height)
        precondition(leftFrame.maxX >= 206 && leftFrame.minY <= bounds.height - 60)
        layout.move(CGSize(width: 4000, height: -4000), in: bounds)
        layout.endGesture()
        let rightFrame = layout.fittedFrame(in: bounds)
        precondition(rightFrame.maxX > bounds.width && rightFrame.minY == 0)
        precondition(rightFrame.minX + 112 <= bounds.width)
        let smallerBounds = CGSize(width: 400, height: 300)
        layout.constrain(to: smallerBounds)
        let constrained = layout.fittedFrame(in: smallerBounds)
        precondition(constrained.minX + 112 <= smallerBounds.width)
        precondition(constrained.minY + 60 <= smallerBounds.height)
        if CommandLine.arguments.contains("--layout-only") {
            print("Queue panel bounds tests passed")
            return
        }
        precondition(CGPreflightPostEventAccess(), "Mouse event access is required")
        let originalPointer = CGEvent(source: nil)?.location
        let previousApp = NSWorkspace.shared.frontmostApplication
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = AppModel()
        let window = NSWindow(contentRect: NSRect(x: 150, y: 150, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        var dismissCalls = 0
        window.contentView = NSHostingView(rootView: TrackQueueView(model: model, onSelectTrack: { _ in }, onSelectArtist: { _ in }, onDismiss: { dismissCalls += 1 }, onMove: { _ in }, onMoveEnd: {}))
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)

        func handles(_ view: NSView) -> [NSView] {
            (view.accessibilityLabel()?.hasPrefix("Reorder Track") == true ? [view] : []) + view.subviews.flatMap(handles)
        }
        func point(_ title: String) -> CGPoint {
            let view = handles(window.contentView!).first { $0.accessibilityLabel() == "Reorder \(title)" }!
            let local = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            let screen = window.convertPoint(toScreen: local)
            return CGPoint(x: screen.x, y: NSScreen.screens[0].frame.height - screen.y)
        }
        func order() -> [String] {
            handles(window.contentView!).sorted {
                $0.convert(.zero, to: nil).y > $1.convert(.zero, to: nil).y
            }.map { $0.accessibilityLabel()! }
        }
        func post(_ type: CGEventType, _ point: CGPoint) {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!.post(tap: .cghidEventTap)
        }
        Task { @MainActor in
            func pause() async { try? await Task.sleep(for: .milliseconds(400)) }
            // Wait for activation and layout before sending system mouse events.
            for _ in 0..<20 {
                if app.isActive && handles(window.contentView!).count == 5 { break }
                await pause()
            }
            precondition(app.isActive && handles(window.contentView!).count == 5)
            await pause()
            @MainActor func headerView(in view: NSView) -> NSView? {
                if view.accessibilityLabel() == "Move track queue" { return view }
                return view.subviews.lazy.compactMap { headerView(in: $0) }.first
            }
            let header = headerView(in: window.contentView!)!
            let headerBounds = header.convert(header.bounds, to: window.contentView!)
            precondition(abs(headerBounds.minX) < 1, "Header target must reach the left panel edge")
            precondition(abs(headerBounds.width - window.contentView!.bounds.width) < 1,
                         "Header target must reach the right panel edge")
            let topGap = window.contentView!.isFlipped
                ? headerBounds.minY - window.contentView!.bounds.minY
                : window.contentView!.bounds.maxY - headerBounds.maxY
            precondition(abs(topGap) < 1, "Header target must reach the top panel edge")
            let headerLocal = header.convert(NSPoint(x: header.bounds.midX, y: header.bounds.midY), to: nil)
            let headerScreen = window.convertPoint(toScreen: headerLocal)
            let headerPoint = CGPoint(x: headerScreen.x, y: NSScreen.screens[0].frame.height - headerScreen.y)
            post(.mouseMoved, headerPoint)
            await pause()
            precondition(NSCursor.current == NSCursor.openHand, "Header hover must show the open hand")
            post(.leftMouseDown, headerPoint)
            await pause()
            precondition(NSCursor.current == NSCursor.closedHand, "Header press must show the closed hand")
            post(.leftMouseUp, headerPoint)
            await pause()
            precondition(NSCursor.current == NSCursor.openHand, "Header release must restore the open hand")
            TitleAnimationProbe.animatedURNs = []
            let start = point("Track 1")
            let target = point("Track 3")
            post(.mouseMoved, start)
            await pause()
            post(.leftMouseDown, start)
            await pause()
            post(.leftMouseDragged, CGPoint(x: start.x, y: start.y + 8))
            await pause()
            post(.leftMouseDragged, CGPoint(x: target.x, y: target.y + 10))
            await pause()
            precondition(order() == [2,3,1,4,5].map { "Reorder Track \($0)" }, "Rows must move before mouse release: \(order()), active: \(app.isActive)")
            precondition(model.moves == 0, "Hover must not commit")
            precondition(
                ["track:1", "track:2", "track:3"].allSatisfy(TitleAnimationProbe.animatedURNs.contains),
                "Moved track titles must retain the row animation"
            )
            post(.leftMouseUp, CGPoint(x: target.x, y: target.y + 10))
            await pause()
            precondition(model.queue.playbackTracks.map(\.urn) == [2,3,1,4,5].map { "track:\($0)" }, "Drop must commit")
            precondition(model.moves == 1)
            let secondStart = point("Track 1")
            let secondTarget = point("Track 2")
            post(.mouseMoved, secondStart)
            await pause()
            post(.leftMouseDown, secondStart)
            await pause()
            post(.leftMouseDragged, CGPoint(x: secondStart.x, y: secondStart.y - 8))
            await pause()
            post(.leftMouseDragged, CGPoint(x: secondTarget.x, y: secondTarget.y - 10))
            await pause()
            precondition(order() == [1,2,3,4,5].map { "Reorder Track \($0)" }, "Upward drag must preview")
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)!.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)!.post(tap: .cghidEventTap)
            await pause()
            post(.leftMouseUp, secondTarget)
            await pause()
            precondition(order() == [2,3,1,4,5].map { "Reorder Track \($0)" }, "Escape must restore the order")
            precondition(model.moves == 1, "Cancellation must not commit")
            let outsideStart = point("Track 1")
            let outsideTarget = point("Track 2")
            post(.mouseMoved, outsideStart)
            await pause()
            post(.leftMouseDown, outsideStart)
            await pause()
            post(.leftMouseDragged, CGPoint(x: outsideStart.x, y: outsideStart.y - 8))
            await pause()
            post(.leftMouseDragged, CGPoint(x: outsideTarget.x, y: outsideTarget.y - 10))
            await pause()
            precondition(order() == [1,2,3,4,5].map { "Reorder Track \($0)" })
            // The header is outside the queue's drop targets, but inside the test window.
            let outside = CGPoint(x: outsideTarget.x + 100, y: outsideTarget.y - 55)
            post(.leftMouseDragged, outside)
            await pause()
            post(.leftMouseUp, outside)
            await pause()
            await pause() // Allow AppKit's rejected-drop animation to finish.
            precondition(order() == [2,3,1,4,5].map { "Reorder Track \($0)" }, "Rejected drop must restore the order")
            precondition(model.moves == 1, "Rejected drop must not commit")
            // The full-width drag background must not intercept the buttons.
            let clearPoint = CGPoint(x: headerPoint.x + header.bounds.width / 2 - 80, y: headerPoint.y)
            post(.mouseMoved, clearPoint)
            await pause()
            precondition(NSCursor.current == NSCursor.arrow, "Clear hover must show the arrow")
            post(.leftMouseDown, clearPoint)
            post(.leftMouseUp, clearPoint)
            await pause()
            precondition(model.clearCalls == 1, "Clear must remain clickable")
            let closePoint = CGPoint(x: headerPoint.x + header.bounds.width / 2 - 30, y: headerPoint.y)
            post(.mouseMoved, closePoint)
            await pause()
            precondition(NSCursor.current == NSCursor.arrow, "Close hover must show the arrow")
            post(.leftMouseDown, closePoint)
            post(.leftMouseUp, closePoint)
            await pause()
            precondition(dismissCalls == 1, "Close must remain clickable")
            // Moving the panel must reuse its content instead of rebuilding it
            // for every pointer event.
            let layout = QueuePanelLayout()
            let bounds = CGSize(width: 600, height: 500)
            window.contentView = NSHostingView(rootView: QueuePanel(
                layout: layout, bounds: bounds, isVisible: true,
                hoverSuppression: ContentHoverSuppression(), content: PanelContentProbe()
            ))
            await pause()
            let updatesBeforeMove = PanelContentProbe.bodyUpdates
            let frameBeforeMove = layout.fittedFrame(in: bounds)
            for step in 1...20 {
                layout.move(CGSize(width: step * 4, height: step * 3), in: bounds)
                try? await Task.sleep(for: .milliseconds(20))
            }
            layout.endGesture()
            await pause()
            precondition(layout.fittedFrame(in: bounds).origin != frameBeforeMove.origin)
            precondition(PanelContentProbe.bodyUpdates == updatesBeforeMove,
                         "Panel movement must not rebuild its content")
            if let originalPointer { post(.mouseMoved, originalPointer) }
            previousApp?.activate()
            print("Queue drag UI tests passed")
            app.terminate(nil)
        }
        app.run()
    }
}

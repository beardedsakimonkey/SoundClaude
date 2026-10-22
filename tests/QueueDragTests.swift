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
    static var rowUpdates: [String: Int] = [:]
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
@Observable
final class AppModel {
    var queue = TrackQueue(source: .single, tracks: (1...5).map { SoundCloudTrack(urn: "track:\($0)", title: "Track \($0)") })
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
    func removeFromQueue(_ track: SoundCloudTrack) { queue.remove(track) }
    func play(_ track: SoundCloudTrack) async {}
}
struct TrackListRow: View {
    let track: SoundCloudTrack
    let playback: Playback
    let analyzer: Int
    let artworkLoader: Int
    @ObservedObject var likes: LikesController
    var showsMetadata = true
    var showsDuration = true
    var showsLikes = true
    let onRemoveFromQueue: (SoundCloudTrack) -> Void
    let onSelectTrack: (SoundCloudTrack) -> Void
    let onSelectArtist: (SoundCloudUser) -> Void
    let onPlayTrack: (SoundCloudTrack) async -> Void
    var body: some View {
        let _ = TitleAnimationProbe.rowUpdates[track.urn, default: 0] += 1
        Button { onRemoveFromQueue(track) } label: { Text(track.title) }
            .buttonStyle(.plain)
            .transaction { transaction in
                if transaction.animation != nil {
                    TitleAnimationProbe.animatedURNs.insert(track.urn)
                }
            }
            .modifier(TrackPlaybackTitleInset(inset: 0))
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 56)
            .background(track.urn == "track:1" ? Color.red : Color.blue)
    }
}

@main
struct QueueDragTests {
    @MainActor
    static func main() {
        precondition(CGPreflightPostEventAccess(), "Mouse event access is required")
        let originalPointer = CGEvent(source: nil)?.location
        let previousApp = NSWorkspace.shared.frontmostApplication
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = AppModel()
        let window = NSWindow(contentRect: NSRect(x: 150, y: 150, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        var dismissCalls = 0
        window.contentView = NSHostingView(rootView: TrackQueueView(model: model, onSelectTrack: { _ in }, onSelectArtist: { _ in }, onDismiss: { dismissCalls += 1 }))
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
            let originalQueue = model.queue
            let rowUpdates = TitleAnimationProbe.rowUpdates
            model.removeFromQueue(model.queue.tracks[2])
            await pause()
            await pause() // Let the removal animation finish.
            precondition(model.queue.tracks.map(\.urn) == [1,2,4,5].map { "track:\($0)" })
            for urn in ["track:1", "track:2", "track:4", "track:5"] {
                precondition(TitleAnimationProbe.rowUpdates[urn] == rowUpdates[urn],
                             "Removing a track must not re-render surviving row \(urn)")
            }
            model.queue = originalQueue
            await pause()
            // Header buttons sit in the top-right corner of the panel.
            let content = window.contentView!
            let headerY = window.convertPoint(toScreen: content.convert(
                NSPoint(x: 0, y: content.isFlipped ? 30 : content.bounds.height - 30), to: nil)).y
            @MainActor func headerPoint(fromRight offset: CGFloat) -> CGPoint {
                let x = window.convertPoint(toScreen: content.convert(NSPoint(x: content.bounds.width - offset, y: 0), to: nil)).x
                return CGPoint(x: x, y: NSScreen.screens[0].frame.height - headerY)
            }
            TitleAnimationProbe.animatedURNs = []
            let start = point("Track 1")
            let target = point("Track 3")
            post(.mouseMoved, start)
            await pause()
            post(.leftMouseDown, start)
            await pause()
            post(.leftMouseDragged, CGPoint(x: start.x + 40, y: start.y + 8))
            await pause()
            let moved = point("Track 1")
            precondition(abs(moved.y - start.y - 8) < 1, "The actual row must follow the mouse before a reorder: start \(start), moved \(moved)")
            precondition(abs(moved.x - start.x) < 1, "Dragging must never move the row horizontally")
            // Overlap the next row without crossing its center. Check rendered
            // pixels, not just handle positions, to catch incorrect stacking.
            post(.leftMouseDragged, CGPoint(x: start.x, y: start.y + 24))
            await pause()
            let contentView = window.contentView!
            let sampleScreen = NSPoint(x: start.x + 100,
                                       y: NSScreen.screens[0].frame.height - (start.y + 40))
            let sample = contentView.convert(window.convertPoint(fromScreen: sampleScreen), from: nil)
            let bitmap = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds)!
            contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
            let pixelX = Int(sample.x / contentView.bounds.width * CGFloat(bitmap.pixelsWide))
            let sampleY = contentView.isFlipped ? sample.y : contentView.bounds.height - sample.y
            let pixelY = Int(sampleY / contentView.bounds.height * CGFloat(bitmap.pixelsHigh))
            let color = bitmap.colorAt(x: pixelX, y: pixelY)!.usingColorSpace(.deviceRGB)!
            precondition(color.redComponent > color.blueComponent + 0.4,
                         "The dragged row must draw above lower rows: \(color)")
            post(.leftMouseDragged, CGPoint(x: target.x, y: target.y + 10))
            await pause()
            precondition(order() == [2,3,1,4,5].map { "Reorder Track \($0)" }, "Rows must move before mouse release: \(order()), active: \(app.isActive)")
            precondition(model.moves == 0, "Hover must not commit")
            precondition(
                ["track:2", "track:3"].allSatisfy(TitleAnimationProbe.animatedURNs.contains),
                "Neighboring track titles must retain the row animation"
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
            let clearPoint = headerPoint(fromRight: 80)
            post(.mouseMoved, clearPoint)
            await pause()
            post(.leftMouseDown, clearPoint)
            post(.leftMouseUp, clearPoint)
            await pause()
            precondition(model.clearCalls == 1, "Clear must remain clickable")
            let closePoint = headerPoint(fromRight: 30)
            post(.mouseMoved, closePoint)
            await pause()
            post(.leftMouseDown, closePoint)
            post(.leftMouseUp, closePoint)
            await pause()
            precondition(dismissCalls == 1, "Close must remain clickable")
            TitleAnimationProbe.rowUpdates = [:]
            model.queue = TrackQueue(source: .single, tracks: (1...1_000).map {
                SoundCloudTrack(urn: "track:\($0)", title: "Track \($0)")
            })
            await pause()
            await pause()
            precondition(TitleAnimationProbe.rowUpdates.count < 100,
                         "Opening a large queue must only create nearby rows")
            let largeQueueStart = point("Track 1")
            post(.mouseMoved, largeQueueStart)
            post(.leftMouseDown, largeQueueStart)
            await pause()
            post(.leftMouseDragged, CGPoint(x: largeQueueStart.x, y: largeQueueStart.y + 24))
            await pause()
            precondition(TitleAnimationProbe.rowUpdates.count < 100,
                         "Lifting a row must preserve lazy loading")
            precondition(handles(window.contentView!).count < 100,
                         "The queue must not instantiate a handle for every track")
            post(.leftMouseUp, CGPoint(x: largeQueueStart.x, y: largeQueueStart.y + 24))
            await pause()
            if let originalPointer { post(.mouseMoved, originalPointer) }
            previousApp?.activate()
            print("Queue drag UI tests passed")
            app.terminate(nil)
        }
        app.run()
    }
}

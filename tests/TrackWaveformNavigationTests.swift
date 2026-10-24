import AppKit
import Observation
import SwiftUI

// Run the production waveform and navigation overlay with deterministic services.
struct SoundCloudTrack {
    let urn: String
    var waveformURL: URL? = URL(string: "https://example.com/waveform")
    var displayArtworkURL: URL? { nil }
    var durationMilliseconds: Int { 120_000 }
}
struct SoundCloudWaveform: Equatable {
    let height = 100
    var samples: [Int] {
        Measurements.sampleReads += 1
        return [20, 60, 100, 40]
    }
}
@Observable final class PlaybackController {
    subscript(isCurrentTrack urn: String) -> Bool { currentTrack?.urn == urn }
    enum Direction { case forward, backward }
    var currentTrack: SoundCloudTrack? = SoundCloudTrack(urn: "same")
    var isPlaybackActive = true
    var isLoading = false
    var isBuffering = false
    var currentTime = 20.0
    var duration = 120.0
    var trackChangeDirection = Direction.forward
    func seek(by seconds: Double) {}
    func seek(toFraction fraction: Double) {}
}
struct ArtworkAccent {
    let red = 0.5, green = 0.5, blue = 0.5
    static let fallback = ArtworkAccent()
    func contrasted(isDark: Bool, increasedContrast: Bool) -> Self { self }
}
final class ArtworkLoader {
    func accentColor(for url: URL) async throws -> ArtworkAccent { .fallback }
}
final class AppModel {
    let playback = PlaybackController()
    let artworkLoader = ArtworkLoader()
    func cachedWaveform(for track: SoundCloudTrack) -> SoundCloudWaveform? {
        track.waveformURL == nil ? nil : SoundCloudWaveform()
    }
    func waveform(for track: SoundCloudTrack) async throws -> SoundCloudWaveform {
        try await Task.sleep(for: .milliseconds(50))
        return SoundCloudWaveform()
    }
    func play(_ track: SoundCloudTrack) async {}
}
extension EnvironmentValues {
    @Entry var contentAnimationsPaused = false
}
private enum Measurements {
    static var sampleReads = 0
    static var visibility: [Bool] = []
    static var creations = 0
}
private final class CommentLifetime: ObservableObject {
    init() { Measurements.creations += 1 }
}
// Observe the real waveform's comment input and the lifetime of its child.
struct WaveformCommentsView: View {
    let track: SoundCloudTrack
    let model: AppModel
    let duration: Double
    let showsComments: Bool
    let onSeek: (Double) -> Void
    @StateObject private var lifetime = CommentLifetime()
    var body: some View {
        let _ = lifetime
        Color.clear.onChange(of: showsComments, initial: true) { _, value in
            Measurements.visibility.append(value)
        }
    }
}
@main struct TrackWaveformNavigationTests {
    @MainActor static func main() async {
        _ = NSApplication.shared
        let model = AppModel()
        func page(station: Bool) -> some View {
            NavigationStack {
                CurrentNavigationPage(route: station ? 1 : 0, retainsRoot: true) {
                    Color.clear
                } destination: { route in
                    GeometryReader { _ in
                        ScrollView {
                            DetailWaveformSlot(
                                track: SoundCloudTrack(
                                    urn: "same", waveformURL: route == 1
                                        ? URL(string: "https://example.com/waveform") : nil
                                ),
                                isCollection: route == 1
                            )
                        }
                    }
                }
                .modifier(DetailWaveformOverlay(model: model, routeID: AnyHashable(station ? 1 : 0)))
            }
        }
        let host = NSHostingView(rootView: page(station: true))
        host.frame.size = CGSize(width: 800, height: 600)
        func settle(_ milliseconds: Int = 100) async {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(milliseconds))
            host.layoutSubtreeIfNeeded()
        }
        await settle(2000)
        precondition(Measurements.visibility.last == true, "Comments never became visible")
        Measurements.visibility = []
        for station in [false, true, false] {
            host.rootView = page(station: station)
            await settle(200)
        }
        precondition(Measurements.creations == 1, "Navigation recreated the comments")
        precondition(!Measurements.visibility.contains(false), "Navigation hid the comments")
        // Scrolling a paused waveform must only move its existing content.
        model.playback.isPlaybackActive = false
        let scrollingHost = NSHostingView(rootView:
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 200)
                    DetailWaveformSlot(track: SoundCloudTrack(urn: "same"))
                    Color.clear.frame(height: 1200)
                }
            }
            .modifier(DetailWaveformOverlay(model: model, routeID: 0))
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = scrollingHost
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        scrollingHost.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .seconds(2))
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let forwarder = descendants(scrollingHost).compactMap { $0 as? DetailWaveformScrollView }.first!
        let scrollView = forwarder.target!.anchor!.enclosingScrollView!
        let readsBeforeScroll = Measurements.sampleReads
        precondition(readsBeforeScroll > 0, "Waveform was never drawn")
        for y in [20, 40, 60] {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            scrollingHost.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(100))
        }
        precondition(Measurements.sampleReads == readsBeforeScroll,
                     "Scrolling rebuilt the paused waveform drawing content")
        scrollingHost.frame.size.width = 900
        scrollingHost.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))
        precondition(Measurements.sampleReads > readsBeforeScroll,
                     "Resizing must update waveform bar sampling")
        let readsAfterResize = Measurements.sampleReads
        model.playback.currentTime = 40
        try? await Task.sleep(for: .milliseconds(100))
        precondition(Measurements.sampleReads > readsAfterResize,
                     "Seeking must update waveform progress")
        print("Track waveform navigation and paused scrolling tests passed")
    }
}

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
    let samples = [20, 60, 100, 40]
}
@Observable final class PlaybackController {
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
                                isStation: route == 1
                            )
                        }
                    }
                }
                .modifier(DetailWaveformOverlay(model: model))
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
        print("Track waveform navigation tests passed")
    }
}

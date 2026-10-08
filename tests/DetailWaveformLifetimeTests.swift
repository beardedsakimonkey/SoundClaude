import AppKit
import SwiftUI

// Stand-ins isolate the production slot and overlay from networking and playback.
struct SoundCloudTrack { let urn: String }
final class AppModel {}

private final class WaveformTestApplication: NSApplication {
    var testEvent: NSEvent?
    override var currentEvent: NSEvent? { testEvent ?? super.currentEvent }
}

private final class WaveformLifetime: ObservableObject {
    static var creations = 0
    init() { Self.creations += 1 }
}

private enum Measurements {
    static var frame = CGRect.zero
    static var trackURN: String?
    static var isStation = false
    static var play: ((SoundCloudTrack) async -> Void)?
}

struct TrackWaveformView: View {
    enum Layout {
        case detail
        var height: CGFloat { 100 }
        var reflectionHeight: CGFloat { 32 }
    }
    let track: SoundCloudTrack?
    let model: AppModel
    let invertsBarsOnTrackChange: Bool
    let keepsBarsVisible: Bool
    let onPlayTrack: ((SoundCloudTrack) async -> Void)?
    @StateObject private var lifetime = WaveformLifetime()

    var body: some View {
        let _ = lifetime
        let _ = captureInputs()
        Color.orange
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("viewport")) } action: {
                Measurements.frame = $0
            }
    }

    private func captureInputs() {
        Measurements.trackURN = track?.urn
        Measurements.isStation = invertsBarsOnTrackChange && keepsBarsVisible
        Measurements.play = onPlayTrack
    }
}

@main struct DetailWaveformLifetimeTests {
    @MainActor static func main() async {
        let app = WaveformTestApplication.shared as! WaveformTestApplication
        let model = AppModel()
        var playedURN: String?
        func page(station: Bool, track: String = "same", y: CGFloat = 30, showsSlot: Bool = true) -> some View {
            CurrentNavigationPage(route: station ? 1 : 0) {
                Color.clear
            } destination: { route in
                VStack(spacing: 0) {
                    if showsSlot {
                        DetailWaveformSlot(
                            track: SoundCloudTrack(urn: track), isStation: route == 1,
                            onPlayTrack: route == 1 ? { playedURN = $0.urn } : nil
                        )
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24)
                .offset(y: y)
            }
            .modifier(DetailWaveformOverlay(model: model))
            .coordinateSpace(name: "viewport")
        }
        let host = NSHostingView(rootView: page(station: false))
        host.frame.size = CGSize(width: 800, height: 600)
        func layout() async {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(30))
            host.layoutSubtreeIfNeeded()
        }
        await layout()
        precondition(WaveformLifetime.creations == 1)
        for station in [true, false, true, false, true] {
            host.rootView = page(station: station)
            await layout()
            precondition(WaveformLifetime.creations == 1, "Navigation recreated the waveform")
            precondition(Measurements.trackURN == "same")
            precondition(Measurements.isStation == station, "Playback behavior did not follow the page")
            precondition((Measurements.play != nil) == station)
        }
        await Measurements.play?(SoundCloudTrack(urn: "selected"))
        precondition(playedURN == "selected", "Station playback callback was lost")
        host.rootView = page(station: true, track: "next", y: -20)
        await layout()
        precondition(WaveformLifetime.creations == 1, "Changing tracks recreated the waveform host")
        precondition(Measurements.trackURN == "next")
        precondition(abs(Measurements.frame.minY + 20) < 0.5, "Waveform did not follow the header")
        precondition(abs(Measurements.frame.width - 752) < 0.5, "Waveform width differs from its slot")
        host.rootView = page(station: false, showsSlot: false)
        await layout()
        host.rootView = page(station: false)
        await layout()
        precondition(WaveformLifetime.creations == 2, "Leaving detail pages must release the waveform")

        // Different metadata heights must not move the waveform between headers.
        func header(metadataHeight: CGFloat, station: Bool) -> some View {
            VStack {
                Color.clear.frame(height: metadataHeight)
                    .modifier(DetailWaveformHeader(
                        track: SoundCloudTrack(urn: "same"), isStation: station
                    ))
                Spacer(minLength: 0)
            }
            .modifier(DetailWaveformOverlay(model: model))
            .coordinateSpace(name: "viewport")
        }
        let headers = NSHostingView(rootView: header(metadataHeight: 140, station: false))
        var baselineY: CGFloat?
        for width: CGFloat in [320, 700] {
            for metadataHeight: CGFloat in [140, 157, 165, 140] {
                headers.frame.size = CGSize(width: width, height: 600)
                headers.rootView = header(metadataHeight: metadataHeight, station: metadataHeight == 157)
                headers.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(30))
                headers.layoutSubtreeIfNeeded()
                if let baselineY {
                    precondition(abs(Measurements.frame.minY - baselineY) < 0.5,
                                 "Metadata height moved the waveform: \(Measurements.frame.minY) vs \(baselineY)")
                } else {
                    baselineY = Measurements.frame.minY
                }
            }
        }
        // The overlay must route wheel events to the slot's actual scroll view.
        let scrollingHost = NSHostingView(rootView:
            ScrollView {
                VStack(spacing: 0) {
                    DetailWaveformSlot(track: SoundCloudTrack(urn: "scroll"))
                    Color.clear.frame(height: 1200)
                }
            }
            .modifier(DetailWaveformOverlay(model: model))
        )
        let scrollWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        scrollWindow.contentView = scrollingHost
        scrollWindow.orderFront(nil)
        defer { scrollWindow.orderOut(nil) }
        scrollingHost.frame.size = CGSize(width: 800, height: 600)
        scrollingHost.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(30))
        scrollingHost.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let forwarder = descendants(scrollingHost).compactMap { $0 as? DetailWaveformScrollView }.first!
        let scrollView = forwarder.target!.anchor!.enclosingScrollView!
        let point = forwarder.convert(
            NSPoint(x: forwarder.bounds.midX, y: forwarder.bounds.midY), to: forwarder.superview
        )
        let wheel = NSEvent(cgEvent: CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
            wheel1: -60, wheel2: 0, wheel3: 0
        )!)!
        app.testEvent = wheel
        precondition(forwarder.hitTest(point) === forwarder, "Wheel events must reach the forwarder")
        let hostPoint = forwarder.convert(
            NSPoint(x: forwarder.bounds.midX, y: forwarder.bounds.midY), to: scrollingHost.superview
        )
        precondition(scrollingHost.hitTest(hostPoint) === forwarder,
                     "The waveform overlay must route wheel events through the forwarder")
        let initialY = scrollView.contentView.bounds.minY
        forwarder.scrollWheel(with: wheel)
        try? await Task.sleep(for: .milliseconds(250))
        precondition(scrollView.contentView.bounds.minY > initialY, "Wheel event did not scroll the page")
        app.testEvent = NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )
        precondition(forwarder.hitTest(point) == nil, "Clicks must pass through to waveform seeking")
        app.testEvent = nil
        print("Detail waveform lifetime, positioning, playback callback, and scroll tests passed")
    }
}

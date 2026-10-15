import AppKit
import SwiftUI

// Anchor both headers to the artwork, independent of title and control heights.
struct DetailWaveformHeader: ViewModifier {
    let track: SoundCloudTrack?
    var showsWaveform = true
    var isStation = false
    var onPlayTrack: ((SoundCloudTrack) async -> Void)? = nil

    func body(content: Content) -> some View {
        content
            .padding(.bottom, showsWaveform ? TrackWaveformView.Layout.detail.height + 16 : 0)
            .frame(
                maxWidth: .infinity,
                minHeight: showsWaveform ? 250 + TrackWaveformView.Layout.detail.reflectionHeight : nil,
                alignment: .topLeading
            )
            .overlay(alignment: .bottom) {
                if showsWaveform {
                    DetailWaveformSlot(track: track, isStation: isStation, onPlayTrack: onPlayTrack)
                        .offset(y: -2)
                }
            }
    }
}

// Headers supply layout and playback behavior; the navigation host owns the view.
struct DetailWaveformSlot: View {
    let track: SoundCloudTrack?
    var isStation = false
    var onPlayTrack: ((SoundCloudTrack) async -> Void)? = nil
    @State private var scrollTarget = DetailWaveformScrollTarget()

    var body: some View {
        Color.clear
            .frame(height: TrackWaveformView.Layout.detail.height)
            .background(DetailWaveformScrollAnchor(target: scrollTarget))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .anchorPreference(key: DetailWaveformPreferenceKey.self, value: .bounds) {
                DetailWaveformSource(
                    bounds: $0, track: track, isStation: isStation,
                    onPlayTrack: onPlayTrack, scrollTarget: scrollTarget
                )
            }
    }
}

struct DetailWaveformSource {
    let bounds: Anchor<CGRect>
    let track: SoundCloudTrack?
    let isStation: Bool
    let onPlayTrack: ((SoundCloudTrack) async -> Void)?
    let scrollTarget: DetailWaveformScrollTarget
}

final class DetailWaveformScrollTarget {
    weak var anchor: NSView?
}

private struct DetailWaveformScrollAnchor: NSViewRepresentable {
    let target: DetailWaveformScrollTarget

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        target.anchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        target.anchor = view
    }
}

// The shared waveform is outside the page's scroll view. Return wheel events
// to the scroll view that contains its slot, leaving clicks and drags to SwiftUI.
private struct DetailWaveformScrollForwarder: NSViewRepresentable {
    let target: DetailWaveformScrollTarget

    func makeNSView(context: Context) -> DetailWaveformScrollView {
        DetailWaveformScrollView()
    }

    func updateNSView(_ view: DetailWaveformScrollView, context: Context) {
        view.target = target
    }
}

final class DetailWaveformScrollView: NSView {
    var target: DetailWaveformScrollTarget?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard NSApp.currentEvent?.type == .scrollWheel,
              target?.anchor?.enclosingScrollView != nil else { return nil }
        return super.hitTest(point)
    }

    override func scrollWheel(with event: NSEvent) {
        if let scrollView = target?.anchor?.enclosingScrollView {
            scrollView.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

struct DetailWaveformPreferenceKey: PreferenceKey {
    static let defaultValue: DetailWaveformSource? = nil

    static func reduce(value: inout DetailWaveformSource?, nextValue: () -> DetailWaveformSource?) {
        value = nextValue() ?? value
    }
}

struct DetailWaveformOverlay: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(DetailWaveformPreferenceKey.self) { source in
                if let source {
                    // Build the waveform outside the geometry reader so scrolling
                    // updates its placement without rebuilding its drawing content.
                    DetailWaveformContent(
                        track: source.track, model: model,
                        isStation: source.isStation,
                        onPlayTrack: source.onPlayTrack
                    )
                    .overlay(DetailWaveformScrollForwarder(target: source.scrollTarget))
                    .modifier(DetailWaveformPlacement(bounds: source.bounds))
                }
            }
    }
}

private struct DetailWaveformPlacement: ViewModifier {
    let bounds: Anchor<CGRect>

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            let rect = geometry[bounds]
            content
                // Resolve slot geometry before inner bar animations can apply it.
                .geometryGroup()
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .transaction { $0.animation = nil }
        }
        .clipped()
    }
}

// Keep anchor preference updates out of the stateful waveform's inputs.
private struct DetailWaveformContent: View {
    let track: SoundCloudTrack?
    let model: AppModel
    let isStation: Bool
    let onPlayTrack: ((SoundCloudTrack) async -> Void)?

    var body: some View {
        TrackWaveformView(
            track: track, model: model,
            invertsBarsOnTrackChange: isStation,
            keepsBarsVisible: isStation,
            onPlayTrack: onPlayTrack
        )
    }
}

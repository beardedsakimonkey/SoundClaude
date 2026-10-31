import AppKit
import SwiftUI

private struct DetailWaveformScrollTargetKey: EnvironmentKey {
    static let defaultValue: DetailWaveformScrollTarget? = nil
}

extension EnvironmentValues {
    var detailWaveformScrollTarget: DetailWaveformScrollTarget? {
        get { self[DetailWaveformScrollTargetKey.self] }
        set { self[DetailWaveformScrollTargetKey.self] = newValue }
    }
}

final class DetailWaveformScrollTarget {
    weak var anchor: NSView?
}

struct DetailWaveformScrollAnchor: NSViewRepresentable {
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
struct DetailWaveformScrollForwarder: NSViewRepresentable {
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

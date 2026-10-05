import AppKit
import SwiftUI

// Standalone layout regression; no playback, network, or account required.
final class SpectrumAnalyzer {
    func playbackIndicatorLevels() -> [Float]? { nil }
}
extension EnvironmentValues {
    @Entry var contentAnimationsPaused = false
}

private final class Measurements {
    var widths: Set<CGFloat> = []
}

private struct TitleProbe: Layout {
    let measurements: Measurements
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        if let width = proposal.width, width.isFinite { measurements.widths.insert(width) }
        return subviews[0].sizeThatFits(proposal)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: proposal)
    }
}

private final class Selection: ObservableObject {
    @Published var selected = false
}
private struct TitleRow: View {
    @ObservedObject var selection: Selection
    let measurements: Measurements
    var body: some View {
        TitleProbe(measurements: measurements) {
            Text("A long title that must truncate when the playback indicator appears")
                .lineLimit(1)
        }
        .modifier(TrackPlaybackTitleInset(inset: selection.selected ? 16 : 0))
        .frame(width: 300, alignment: .leading)
        .animation(.linear(duration: 0.3), value: selection.selected)
    }
}

@main
struct PlaybackTitleLayoutTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let selection = Selection()
        let measurements = Measurements()
        let host = NSHostingView(rootView: TitleRow(selection: selection, measurements: measurements))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        func settle() {
            let end = Date().addingTimeInterval(0.5)
            while Date() < end {
                RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120))
                host.layoutSubtreeIfNeeded()
            }
        }
        settle()
        for selected in [true, false] {
            measurements.widths.removeAll()
            selection.selected = selected
            settle()
            print("Title widths measured during transition: \(measurements.widths.count)")
            precondition(measurements.widths.count <= 4,
                         "Title reflowed at \(measurements.widths.count) intermediate widths")
            precondition(measurements.widths.contains(selected ? 284 : 300),
                         "The title must use the correct final width")
        }
        print("Playback title layout tests passed")
    }
}

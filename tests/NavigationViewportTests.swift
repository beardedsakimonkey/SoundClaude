import AppKit
import SwiftUI

final class Measurements {
    var proposals: [ProposedViewSize] = []
}

// Deliberately larger than the window, like tall artwork and long track lists.
private struct Probe: Layout {
    let measurements: Measurements
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        measurements.proposals.append(proposal)
        return CGSize(width: 2000, height: 3000)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {}
}

// A retained StateObject detects hidden page trees, not just visible pixels.
private final class PageLifetime: ObservableObject {
    static var livePages: Set<Int> = []
    let id: Int
    init(id: Int) {
        self.id = id
        precondition(Self.livePages.insert(id).inserted)
    }
    deinit { Self.livePages.remove(id) }
}

private struct LifetimePage: View {
    @StateObject private var lifetime: PageLifetime
    init(id: Int) { _lifetime = StateObject(wrappedValue: PageLifetime(id: id)) }
    var body: some View { Text("Page \(lifetime.id)") }
}

@main struct NavigationViewportTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let measurements = Measurements()
        let host = NSHostingView(rootView: Probe(measurements: measurements) { Color.clear }.modifier(NavigationPageViewport()))
        for size in [CGSize(width: 800, height: 600), CGSize(width: 1100, height: 750)] {
            host.frame.size = size
            host.layoutSubtreeIfNeeded()
            precondition(measurements.proposals.contains {
                $0.width == size.width && $0.height == size.height
            }, "Page did not receive the resized viewport")
            measurements.proposals.removeAll()
            let ideal = host.fittingSize
            precondition(ideal.width < 2000 && ideal.height < 3000, "Page content leaked into ideal size")
            precondition(measurements.proposals.isEmpty, "Sizing the viewport measured its content")
        }
        func page(_ route: Int?) -> some View {
            NavigationStack {
                CurrentNavigationPage(route: route) {
                    LifetimePage(id: -1)
                } destination: { id in
                    LifetimePage(id: id)
                }
                .modifier(NavigationPageViewport())
            }
        }
        let pages = NSHostingView(rootView: page(nil))
        pages.frame.size = CGSize(width: 800, height: 600)
        var history: [Int] = []
        var forward: [Int] = []
        func render() {
            pages.rootView = page(history.last)
            pages.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            precondition(PageLifetime.livePages == [history.last ?? -1],
                         "Retained old page trees: \(PageLifetime.livePages)")
        }
        render()
        for id in 0..<100 { history.append(id); render() }
        while let id = history.popLast() { forward.append(id); render() }
        while let id = forward.popLast() { history.append(id); render() }
        print("Viewport and 100-page navigation lifetime tests passed")
    }
}

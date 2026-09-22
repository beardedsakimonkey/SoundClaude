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
    static var rootCreations = 0
    static var creations: [Int: Int] = [:]
    let id: Int
    init(id: Int) {
        self.id = id
        Self.creations[id, default: 0] += 1
        if id == -1 { Self.rootCreations += 1 }
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
        func page(_ route: Int?, retainsRoot: Bool = false) -> some View {
            NavigationStack {
                CurrentNavigationPage(route: route, retainsRoot: retainsRoot) {
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
        // Search keeps exactly one root alive across push, back, and forward.
        pages.rootView = page(nil, retainsRoot: true)
        pages.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        let retainedRootCount = PageLifetime.rootCreations
        for route in [0, 1, nil, 1, 2, nil] as [Int?] {
            pages.rootView = page(route, retainsRoot: true)
            pages.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            let expected: Set<Int> = route.map { [-1, $0] } ?? [-1]
            precondition(PageLifetime.livePages == expected, "Only the search root and current result should stay mounted")
            precondition(PageLifetime.rootCreations == retainedRootCount, "Search state must survive back and forward navigation")
        }
        func library(_ selection: Int, route: Int? = nil) -> some View {
            NavigationStack {
                CurrentNavigationPage(route: route, retainsRoot: true) {
                    RetainedRootPages(selections: [-10, -11, -12, -13], selection: selection, isActive: route == nil) { id, _ in
                        LifetimePage(id: id)
                    }
                } destination: { id in
                    LifetimePage(id: id)
                }
                .modifier(NavigationPageViewport())
            }
        }
        let libraryHost = NSHostingView(rootView: library(-10))
        libraryHost.frame.size = CGSize(width: 800, height: 600)
        var visited: Set<Int> = []
        func renderLibrary(_ selection: Int, route: Int? = nil) {
            visited.insert(selection)
            libraryHost.rootView = library(selection, route: route)
            libraryHost.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            let libraryPages = PageLifetime.livePages.subtracting([-1])
            precondition(libraryPages == visited.union(route.map { [$0] } ?? []),
                         "Keep visited roots and only the current detail: \(libraryPages)")
            for id in visited {
                precondition(PageLifetime.creations[id] == 1, "Recreated top-level page \(id)")
            }
        }
        renderLibrary(-10)
        renderLibrary(-10, route: 1000)
        renderLibrary(-11)
        renderLibrary(-12)
        renderLibrary(-13, route: 1001)
        for _ in 0..<3 {
            for selection in [-10, -11, -12, -13] {
                renderLibrary(selection)
                renderLibrary(selection, route: 1002)
                renderLibrary(selection, route: 1003)
                renderLibrary(selection)
            }
        }
        print("Viewport, navigation lifetime, and retained top-level page tests passed")
    }
}

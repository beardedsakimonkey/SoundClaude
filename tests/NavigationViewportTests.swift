import AppKit
import SwiftUI

final class Measurements {
    var proposals: [ProposedViewSize] = []
    var pageFrame: CGRect = .zero
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

@Observable
private final class PageSource {
    var value = 0
}

// A fresh closure on every parent update, like the real pages, defeats SwiftUI's
// structural comparison, so the page re-renders unless its wrapper skips it.
private struct CountedPage: View {
    static var evaluations: [Int: Int] = [:]
    static var lastValue: [Int: Int] = [:]
    static var lastActive: [Int: Bool] = [:]
    let id: Int
    let value: Int
    let isActive: Bool
    let onSelect: () -> Void

    var body: some View {
        let _ = Self.evaluations[id, default: 0] += 1
        let _ = Self.lastValue[id] = value
        let _ = Self.lastActive[id] = isActive
        Text("Page \(id)")
    }
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
        // A short viewport must not center oversized content above its top edge.
        let tallPage = NSHostingView(rootView:
            Color.clear
                .frame(height: 600)
                .onGeometryChange(for: CGRect.self) { geometry in
                    geometry.frame(in: .named("viewport"))
                } action: { measurements.pageFrame = $0 }
                .modifier(NavigationPageViewport())
                .coordinateSpace(name: "viewport")
        )
        for height: CGFloat in [750, 300, 450, 800, 200] {
            tallPage.frame.size = CGSize(width: 800, height: height)
            tallPage.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            precondition(abs(measurements.pageFrame.minY) < 0.5,
                         "Page moved above the viewport when resized: \(measurements.pageFrame)")
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

        let source = PageSource()
        let countedIDs = [-20, -21, -22, -23]
        func countedLibrary(_ selection: Int, route: Int? = nil) -> some View {
            NavigationStack {
                CurrentNavigationPage(route: route, retainsRoot: true) {
                    RetainedRootPages(selections: countedIDs, selection: selection, isActive: route == nil) { id, active in
                        // Capture a new object: a closure with no captures compares equal.
                        let capture = NSObject()
                        CountedPage(id: id, value: source.value, isActive: active, onSelect: { _ = capture })
                    }
                } destination: { id in
                    Text("Route \(id)")
                }
            }
        }
        let countedHost = NSHostingView(rootView: countedLibrary(-20))
        countedHost.frame.size = CGSize(width: 800, height: 600)
        func settleCounted() {
            countedHost.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        func renderCounted(_ selection: Int, route: Int? = nil) {
            countedHost.rootView = countedLibrary(selection, route: route)
            settleCounted()
        }
        settleCounted()
        for id in countedIDs { renderCounted(id) }
        renderCounted(-20)

        // Navigating must not re-render pages that stay hidden.
        func assertHiddenPagesSkipped(_ selection: Int, route: Int? = nil, hidden: [Int]) {
            let before = CountedPage.evaluations
            renderCounted(selection, route: route)
            for id in hidden {
                precondition(CountedPage.evaluations[id] == before[id],
                             "Hidden page \(id) re-rendered during navigation")
            }
        }
        assertHiddenPagesSkipped(-20, hidden: [-21, -22, -23])
        assertHiddenPagesSkipped(-20, route: 2000, hidden: [-21, -22, -23])
        precondition(CountedPage.lastActive[-20] == false, "Pushing a route must deactivate the root")
        assertHiddenPagesSkipped(-20, route: 2001, hidden: [-20, -21, -22, -23])
        assertHiddenPagesSkipped(-20, hidden: [-21, -22, -23])
        precondition(CountedPage.lastActive[-20] == true, "Popping to a root must reactivate it")
        assertHiddenPagesSkipped(-21, hidden: [-22, -23])
        precondition(CountedPage.lastActive[-20] == false && CountedPage.lastActive[-21] == true,
                     "Switching roots must update both pages")

        // Skipping parent updates must not hide model changes from a hidden page.
        renderCounted(-21, route: 2002)
        source.value = 1
        settleCounted()
        for id in countedIDs {
            precondition(CountedPage.lastValue[id] == 1, "Hidden page \(id) missed an observed model change")
        }
        print("Viewport, navigation lifetime, and retained top-level page tests passed")
    }
}

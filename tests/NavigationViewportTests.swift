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

        func page(_ route: Int?, root: Int = -1) -> some View {
            NavigationStack {
                CurrentNavigationPage(route: route) {
                    LifetimePage(id: root).id(root)
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

        // Top-level pages unmount when switching between them or pushing a route.
        for (root, route) in [(-10, nil), (-11, nil), (-11, 1000), (-11, nil), (-12, 1001), (-10, nil)] as [(Int, Int?)] {
            pages.rootView = page(route, root: root)
            pages.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            precondition(PageLifetime.livePages == [route ?? root],
                         "Only the current page should stay mounted: \(PageLifetime.livePages)")
        }

        // A remounted page returns to its offset, including in lazy rows of varying height.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let positions = [RememberedScrollPosition(), RememberedScrollPosition()]
        func scrollPage(_ selection: Int?) -> AnyView {
            guard let selection else { return AnyView(Text("Route")) }
            return AnyView(
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(0..<3000, id: \.self) { row in
                            Text("Row \(row)").frame(height: CGFloat(20 + row % 7 * 15))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .remembersScrollPosition()
                }
                .environment(\.rememberedScrollPosition, positions[selection])
                .id(selection)
            )
        }
        func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            return view.subviews.lazy.compactMap { descendant(type, in: $0) }.first
        }
        func settle(_ seconds: TimeInterval = 0.5) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }
        let scrollHost = NSHostingView(rootView: scrollPage(0))
        window.contentView = scrollHost
        window.orderFront(nil)
        func show(_ selection: Int?) {
            scrollHost.rootView = scrollPage(selection)
            settle()
        }
        func scrollOffset() -> CGFloat {
            descendant(NSScrollView.self, in: scrollHost)!.contentView.bounds.origin.y
        }
        func scroll(to offset: CGFloat) {
            let scrollView = descendant(NSScrollView.self, in: scrollHost)!
            scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: offset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            settle()
        }
        settle()
        precondition(abs(scrollOffset()) < 1, "A first visit must start at the top")
        scroll(to: 20000)
        let savedOffset = scrollOffset()
        precondition(abs(savedOffset - 20000) < 1, "Fixture did not scroll: \(savedOffset)")
        precondition(positions[0].offset == savedOffset, "Scrolling did not save the offset")

        show(nil)
        precondition(positions[0].offset == savedOffset, "Unmounting changed the saved offset")
        show(0)
        precondition(abs(scrollOffset() - savedOffset) < 1, "Back did not restore the offset: \(scrollOffset())")

        show(1)
        precondition(abs(scrollOffset()) < 1, "Pages must not share an offset")
        scroll(to: 500)
        show(0)
        precondition(abs(scrollOffset() - savedOffset) < 1, "Switching pages lost the offset: \(scrollOffset())")
        show(1)
        precondition(abs(scrollOffset() - 500) < 1, "Switching back lost the offset: \(scrollOffset())")

        // With very uneven rows, the same row must return to the same place.
        final class RowFrames { static var frames: [Int: CGRect] = [:] }
        let rowPosition = RememberedScrollPosition()
        func rowHeight(_ row: Int) -> CGFloat { row < 150 ? 420 : (row % 5 == 0 ? 300 : 90) }
        func rowPage(_ visible: Bool) -> AnyView {
            guard visible else { return AnyView(Text("Route")) }
            return AnyView(
                ScrollView {
                    LazyVStack(spacing: 24) {
                        Text("Header").frame(height: 60)
                        ForEach(0..<600, id: \.self) { row in
                            Color.gray.frame(height: rowHeight(row))
                                .remembersScrollRow(id: row, spacing: 24)
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: {
                                    RowFrames.frames[row] = $0
                                }
                                .onDisappear { RowFrames.frames[row] = nil }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .remembersScrollPosition()
                }
                .restoresScrollRow()
                .environment(\.rememberedScrollPosition, rowPosition)
            )
        }
        func topRow() -> (row: Int, distance: CGFloat)? {
            RowFrames.frames.filter { $0.value.minY <= 0 && $0.value.maxY + 24 > 0 }.first
                .map { (row: $0.key, distance: -$0.value.minY) }
        }
        func showRows(_ visible: Bool) {
            RowFrames.frames = [:]
            scrollHost.rootView = rowPage(visible)
            settle()
        }
        showRows(true)
        // Scroll in steps like a user, so the rows above were measured.
        for y in stride(from: 0, through: 60000, by: 400) {
            let scrollView = descendant(NSScrollView.self, in: scrollHost)!
            scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: CGFloat(y)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        settle()
        let expectedRow = topRow()!
        precondition(rowPosition.rowAnchor?.id == AnyHashable(expectedRow.row), "Scrolling did not save the top row")
        for _ in 0..<3 {
            showRows(false)
            showRows(true)
            let restored = topRow()
            precondition(restored?.row == expectedRow.row && abs(restored!.distance - expectedRow.distance) < 1,
                         "Restored \(String(describing: restored)), expected \(expectedRow)")
        }
        // Jumping above the first row unmounts the anchor row, so only the offset applies.
        scroll(to: 10)
        showRows(false)
        showRows(true)
        precondition(abs(scrollOffset() - 10) < 1, "Header offset was not restored: \(scrollOffset())")
        print("Viewport, navigation lifetime, and scroll position tests passed")
    }
}

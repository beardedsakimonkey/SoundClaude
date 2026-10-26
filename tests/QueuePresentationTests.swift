import AppKit
import SwiftUI

private final class Evaluations {
    var navigation = 0
    var page = 0
    var footer = 0
    var isQueueVisible = false
    var toggle: (() -> Void)?
}

private struct FooterProbe: View {
    @Binding var isVisible: Bool
    let evaluations: Evaluations

    var body: some View {
        evaluations.footer += 1
        evaluations.isQueueVisible = isVisible
        evaluations.toggle = { isVisible.toggle() }
        return Text(isVisible ? "Close queue" : "Open queue")
    }
}

private struct PageProbe: View {
    let evaluations: Evaluations

    var body: some View {
        evaluations.page += 1
        return Text("Tracks")
    }
}

private struct NavigationProbe: View {
    let presentation: QueuePresentation
    let evaluations: Evaluations

    var body: some View {
        evaluations.navigation += 1
        return PageProbe(evaluations: evaluations)
            .overlay(alignment: .bottom) {
                QueuePresentationReader(presentation: presentation) { binding in
                    FooterProbe(isVisible: binding, evaluations: evaluations)
                }
            }
    }
}

@main
struct QueuePresentationTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let presentation = QueuePresentation()
        let evaluations = Evaluations()
        let host = NSHostingView(rootView: NavigationProbe(
            presentation: presentation, evaluations: evaluations))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        func settle() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            host.layoutSubtreeIfNeeded()
        }
        settle()
        let initialNavigationCount = evaluations.navigation
        let initialPageCount = evaluations.page
        precondition(initialPageCount > 0 && evaluations.footer > 0)
        for expected in [true, false, true, false] {
            let footerCount = evaluations.footer
            evaluations.toggle!()
            settle()
            precondition(presentation.isVisible == expected)
            precondition(evaluations.isQueueVisible == expected)
            precondition(evaluations.footer > footerCount, "Footer must update on queue toggles")
            precondition(evaluations.navigation == initialNavigationCount,
                         "Queue toggles must not reevaluate navigation")
            precondition(evaluations.page == initialPageCount,
                         "Queue toggles must not reevaluate the page")
        }
        print("Queue presentation tests passed")
    }
}

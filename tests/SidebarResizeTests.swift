import AppKit
import SwiftUI

@main
struct SidebarResizeTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 900, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        func content(_ title: String) -> some View {
            NavigationSplitView {
                Text("Sidebar")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .toolbar(removing: .sidebarToggle)
                    .background(NonCollapsingSidebar())
                    .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 480)
            } detail: {
                Text(title).navigationTitle(title)
            }
        }
        let host = NSHostingView(rootView: content("Detail"))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        func settle() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        settle()
        func findSplitView(_ view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView { return split }
            return view.subviews.lazy.compactMap { findSplitView($0) }.first
        }
        guard let split = findSplitView(window.contentView!) else {
            fatalError("Missing sidebar split view")
        }
        func checkWidth() {
            let controller = split.delegate as! NSSplitViewController
            let width = controller.splitViewItems[0].viewController.view.frame.width
            precondition(width >= 179.5 && width <= 480.5, "Invalid sidebar width: \(width)")
            precondition(!split.isSubviewCollapsed(split.arrangedSubviews[0]), "Sidebar collapsed")
        }
        // Send mouse events through the window so this exercises divider tracking.
        func dragDivider(to x: CGFloat) {
            let start = split.convert(NSPoint(x: split.arrangedSubviews[0].frame.maxX + split.dividerThickness / 2,
                                             y: split.bounds.midY), to: nil)
            let end = split.convert(NSPoint(x: x, y: split.bounds.midY), to: nil)
            func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil,
                                   eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            app.postEvent(event(.leftMouseDragged, end), atStart: false)
            app.postEvent(event(.leftMouseUp, end), atStart: false)
            window.sendEvent(event(.leftMouseDown, start))
            settle()
            checkWidth()
        }
        dragDivider(to: 320)
        precondition(split.arrangedSubviews[0].frame.width > 300, "Divider drag did not resize sidebar")
        dragDivider(to: 0)
        dragDivider(to: -100)
        dragDivider(to: 800)
        for width: CGFloat in [500, 300, 900] {
            window.setContentSize(NSSize(width: width, height: 600))
            settle()
            checkWidth()
        }
        let item = (split.delegate as! NSSplitViewController).splitViewItems[0]
        // Reapplying framework defaults must not re-enable collapse.
        item.canCollapse = true
        item.canCollapseFromWindowResize = true
        precondition(!item.canCollapse && !item.canCollapseFromWindowResize)
        item.isCollapsed = true
        settle()
        checkWidth()
        for title in ["Search", "Likes", "Playlist"] {
            host.rootView = content(title)
            settle()
            dragDivider(to: 320)
            dragDivider(to: 0)
        }
        window.orderOut(nil)
        print("Sidebar resize tests passed")
    }
}

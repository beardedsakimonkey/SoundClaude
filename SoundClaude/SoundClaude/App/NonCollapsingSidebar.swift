import SwiftUI

// SwiftUI's column minimum does not prevent the native sidebar from collapsing.
struct NonCollapsingSidebar: NSViewRepresentable {
    func makeNSView(context: Context) -> SidebarConstraintView {
        SidebarConstraintView()
    }

    func updateNSView(_ nsView: SidebarConstraintView, context: Context) {
        nsView.scheduleConfiguration()
    }

    final class SidebarConstraintView: NSView {
        private weak var sidebarItem: NSSplitViewItem?
        private var observations: [NSKeyValueObservation] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleConfiguration()
        }

        func scheduleConfiguration() {
            DispatchQueue.main.async { [weak self] in
                self?.configureSplitItem()
            }
        }

        private func configureSplitItem() {
            var ancestor = superview
            while let view = ancestor {
                if let splitView = view as? NSSplitView,
                   let controller = splitView.delegate as? NSSplitViewController,
                   let item = controller.splitViewItems.first(where: {
                       isDescendant(of: $0.viewController.view)
                   }) {
                    if sidebarItem !== item {
                        sidebarItem = item
                        // SwiftUI can reapply its sidebar defaults after an update.
                        observations = [
                            item.observe(\.canCollapse) { item, _ in
                                if item.canCollapse { item.canCollapse = false }
                            },
                            item.observe(\.canCollapseFromWindowResize) { item, _ in
                                if item.canCollapseFromWindowResize { item.canCollapseFromWindowResize = false }
                            },
                            item.observe(\.isCollapsed) { item, _ in
                                if item.isCollapsed { item.isCollapsed = false }
                            }
                        ]
                    }
                    if item.canCollapse { item.canCollapse = false }
                    if item.canCollapseFromWindowResize { item.canCollapseFromWindowResize = false }
                    if item.minimumThickness != 180 { item.minimumThickness = 180 }
                    if item.isCollapsed { item.isCollapsed = false }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}


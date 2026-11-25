import AppKit
import SwiftUI

/// Ends the detail's toolbar section at the queue's divider, so toolbar items sit beside
/// the queue rather than over it. SwiftUI's inspector adds no tracking separator itself.
/// Place it behind the content the queue inspects.
struct QueueToolbarSeparator: NSViewRepresentable {
    func makeNSView(context: Context) -> SeparatorInstallerView {
        SeparatorInstallerView()
    }

    func updateNSView(_ nsView: SeparatorInstallerView, context: Context) {
        nsView.scheduleInstall()
    }

    final class SeparatorInstallerView: NSView {
        private var delegateProxy: SeparatorToolbarDelegate?
        private var toolbarObservation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            toolbarObservation = window?.observe(\.toolbar) { [weak self] _, _ in
                self?.scheduleInstall()
            }
            scheduleInstall()
        }

        func scheduleInstall() {
            DispatchQueue.main.async { [weak self] in
                self?.install()
            }
        }

        private func install() {
            guard let toolbar = window?.toolbar, let splitView = inspectorSplitView() else { return }
            if let delegateProxy, toolbar.delegate === delegateProxy {
                delegateProxy.splitView = splitView
            } else if let base = toolbar.delegate {
                let proxy = SeparatorToolbarDelegate(base: base, splitView: splitView)
                delegateProxy = proxy
                toolbar.delegate = proxy
            } else {
                return
            }
            delegateProxy?.restoreSeparator(in: toolbar)
        }

        /// The nearest split view that puts this content before a trailing column.
        private func inspectorSplitView() -> NSSplitView? {
            var ancestor = superview
            while let view = ancestor {
                if let splitView = view as? NSSplitView,
                   splitView.arrangedSubviews.count >= 2,
                   let first = splitView.arrangedSubviews.first,
                   isDescendant(of: first) {
                    return splitView
                }
                ancestor = view.superview
            }
            return nil
        }
    }
}

/// Supplies the separator and forwards everything else to SwiftUI's toolbar delegate.
/// SwiftUI drops items it did not create whenever it updates the toolbar, so the separator
/// is put back at the end after each change.
private final class SeparatorToolbarDelegate: NSObject, NSToolbarDelegate {
    static let identifier = NSToolbarItem.Identifier("QueueTrackingSeparator")

    // NSToolbar holds its delegate weakly, so keep SwiftUI's alive here.
    let base: NSToolbarDelegate
    weak var splitView: NSSplitView?
    private var isRestorePending = false

    init(base: NSToolbarDelegate, splitView: NSSplitView) {
        self.base = base
        self.splitView = splitView
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || base.responds(to: selector)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        base
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if identifier == Self.identifier {
            guard let splitView else { return nil }
            return NSTrackingSeparatorToolbarItem(
                identifier: identifier,
                splitView: splitView,
                dividerIndex: splitView.arrangedSubviews.count - 2
            )
        }
        return base.toolbar?(toolbar, itemForItemIdentifier: identifier, willBeInsertedIntoToolbar: flag)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        (base.toolbarDefaultItemIdentifiers?(toolbar) ?? []) + [Self.identifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        (base.toolbarAllowedItemIdentifiers?(toolbar) ?? []) + [Self.identifier]
    }

    func toolbarWillAddItem(_ notification: Notification) {
        base.toolbarWillAddItem?(notification)
        let item = notification.userInfo?["item"] as? NSToolbarItem
        if item?.itemIdentifier != Self.identifier, let toolbar = notification.object as? NSToolbar {
            restoreSeparator(in: toolbar)
        }
    }

    func toolbarDidRemoveItem(_ notification: Notification) {
        base.toolbarDidRemoveItem?(notification)
        if let toolbar = notification.object as? NSToolbar {
            restoreSeparator(in: toolbar)
        }
    }

    /// Moves the separator to the end once SwiftUI finishes its current toolbar update.
    func restoreSeparator(in toolbar: NSToolbar) {
        guard !isRestorePending else { return }
        isRestorePending = true
        RunLoop.main.perform { [weak self, weak toolbar] in
            guard let self, let toolbar else { return }
            isRestorePending = false
            guard toolbar.items.last?.itemIdentifier != Self.identifier else { return }
            if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == Self.identifier }) {
                toolbar.removeItem(at: index)
            }
            toolbar.insertItem(withItemIdentifier: Self.identifier, at: toolbar.items.count)
        }
    }
}

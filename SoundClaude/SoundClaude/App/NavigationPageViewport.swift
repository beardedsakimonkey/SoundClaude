import SwiftUI

/// History belongs to the caller. Only the current page stays mounted.
struct CurrentNavigationPage<Route: Hashable, Root: View, Destination: View>: View {
    let route: Route?
    @ViewBuilder let root: () -> Root
    @ViewBuilder let destination: (Route) -> Destination

    var body: some View {
        // Without a container, the page's identity change also resets the
        // overlays applied to this view, remounting the shared detail waveform.
        ZStack {
            if let route {
                destination(route).id(route)
            } else {
                root()
            }
        }
    }
}

/// Pages fill the detail column; their contents must not set the stack's ideal size.
/// A flexible frame still measures its child. GeometryReader answers the stack's
/// sizing queries without traversing the page's artwork, text, and lists.
struct NavigationPageViewport: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content
                // Keep oversized pages below the toolbar when the window is short.
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
    }
}

/// A page's scroll offset, kept outside the page so it survives unmounting.
final class RememberedScrollPosition {
    /// The row at the top of the viewport and how far the viewport has scrolled into it.
    struct RowAnchor {
        let id: AnyHashable
        let distance: CGFloat
        /// The saved offset at the time. A jump can unmount the row before it reports
        /// leaving the top, which leaves the anchor far from the offset.
        let offset: CGFloat
    }

    var offset: CGFloat?
    /// Lazy stacks estimate the height of unbuilt rows, so with uneven rows the same
    /// offset can land elsewhere after a remount. Prefer this when a row has set it.
    var rowAnchor: RowAnchor?
    /// Moves the scroll view by a distance. Set only while restoring to `rowAnchor`.
    var scrollBy: ((CGFloat) -> Void)?
    /// Rows report their first frames at the top of a new page. Ignore them until
    /// restoring ends, or they would replace the row being restored.
    var isSavingRows = false
    /// Whether the page's description is showing in full. Kept here so it returns
    /// with the scroll offset, which depends on the description's height.
    var isDescriptionExpanded = false
}

extension EnvironmentValues {
    @Entry var rememberedScrollPosition: RememberedScrollPosition?
}

extension View {
    /// Saves and restores the enclosing scroll view's offset using the position in the
    /// environment. Apply this inside the scroll view's content.
    func remembersScrollPosition() -> some View {
        background(ScrollPositionTracker())
    }

    /// Scrolls back to the remembered row on mount. Apply this to a scroll view whose
    /// rows use `remembersScrollRow`.
    func restoresScrollRow() -> some View {
        modifier(ScrollRowRestorer())
    }

    /// Lets this row anchor the remembered position. `spacing` is the gap below the row,
    /// which counts as part of it so the anchor stays accurate between rows.
    func remembersScrollRow(id: some Hashable, spacing: CGFloat = 0) -> some View {
        modifier(ScrollRowTracker(id: AnyHashable(id), spacing: spacing))
    }
}

private struct ScrollRowRestorer: ViewModifier {
    @Environment(\.rememberedScrollPosition) private var position

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content.task {
                // Scrolling is ignored until the scroll view's first layout.
                await Task.yield()
                // Unbuilt rows are found by ForEach ID, which must match by its concrete type.
                if let id = position?.rowAnchor?.id.base as? any Hashable {
                    proxy.scrollTo(id, anchor: .top)
                }
            }
        }
    }
}

private struct ScrollRowTracker: ViewModifier {
    let id: AnyHashable
    let spacing: CGFloat
    @Environment(\.rememberedScrollPosition) private var position

    func body(content: Content) -> some View {
        content
            .id(id)
            .onGeometryChange(for: CGRect.self) { geometry in
                geometry.frame(in: .scrollView)
            } action: { frame in
                guard let position else { return }
                if let scrollBy = position.scrollBy {
                    guard let anchor = position.rowAnchor, anchor.id == id else { return }
                    let delta = frame.minY + anchor.distance
                    if abs(delta) > 0.5 { scrollBy(delta) }
                } else if !position.isSavingRows {
                    return
                } else if frame.minY <= 0, frame.maxY + spacing > 0 {
                    position.rowAnchor = .init(id: id, distance: -frame.minY, offset: position.offset ?? 0)
                } else if frame.minY > 0, position.rowAnchor?.id == id {
                    // The viewport moved above this row. An earlier row may replace it;
                    // otherwise it's above the first row, where the offset is accurate.
                    position.rowAnchor = nil
                }
            }
    }
}

private struct ScrollPositionTracker: NSViewRepresentable {
    @Environment(\.rememberedScrollPosition) private var position

    func makeNSView(context: Context) -> TrackerView {
        let view = TrackerView()
        view.position = position
        return view
    }

    func updateNSView(_ nsView: TrackerView, context: Context) {}

    final class TrackerView: NSView {
        var position: RememberedScrollPosition?
        private var observers: [NSObjectProtocol] = []
        private var inputMonitor: Any?
        private var restoreTarget: CGFloat?
        private var isRestoring = false
        // SwiftUI can reset the offset and resize lazy content during its first layouts.
        private static let restoreDuration: TimeInterval = 0.3
        // Pages refetch their contents when they remount. Scrolling to the end of what has
        // loaded requests the next page, so an offset can take several requests to reach.
        private static let restoreTimeout: TimeInterval = 10

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopTracking()
            guard window != nil, let position, let scrollView = enclosingScrollView,
                  let documentView = scrollView.documentView else { return }

            let clipView = scrollView.contentView
            clipView.postsBoundsChangedNotifications = true
            documentView.postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            observers = [
                center.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scrollViewDidChange(scrollView) }
                },
                center.addObserver(
                    forName: NSView.frameDidChangeNotification, object: documentView, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scrollViewDidChange(scrollView) }
                },
                center.addObserver(
                    forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.finishRestoring() }
                },
            ]

            if let anchor = position.rowAnchor,
               abs((position.offset ?? 0) - anchor.offset) > clipView.bounds.height {
                position.rowAnchor = nil
            }

            if position.rowAnchor != nil {
                position.scrollBy = { [weak scrollView] delta in
                    guard let scrollView else { return }
                    let clipView = scrollView.contentView
                    clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: clipView.bounds.origin.y + delta))
                    scrollView.reflectScrolledClipView(clipView)
                }
            } else if let offset = position.offset {
                restoreTarget = offset
                startMonitoringInput()
                restore(in: scrollView)
            } else {
                finishRestoring()
                return
            }
            scheduleRestoreCheck(in: scrollView, deadline: Date().addingTimeInterval(Self.restoreTimeout))
        }

        private func scheduleRestoreCheck(in scrollView: NSScrollView, deadline: Date) {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreDuration) { [weak self, weak scrollView] in
                // A page that already unmounted must not end the next page's restore.
                guard let self, let scrollView, !self.observers.isEmpty else { return }
                if let restoreTarget = self.restoreTarget, Date() < deadline,
                   abs(scrollView.contentView.bounds.origin.y - restoreTarget) >= 1 {
                    self.scheduleRestoreCheck(in: scrollView, deadline: deadline)
                } else {
                    self.finishRestoring()
                }
            }
        }

        // Restoring can outlast the page's arrival, so it must not fight the user. Live-scroll
        // notifications miss mouse wheels and the keyboard, and a click can change the page's
        // height. Momentum can carry over from scrolling the previous page.
        private func startMonitoringInput() {
            inputMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .keyDown, .scrollWheel]
            ) { [weak self] event in
                if event.type != .scrollWheel || event.momentumPhase.isEmpty {
                    self?.finishRestoring()
                }
                return event
            }
        }

        private func stopMonitoringInput() {
            if let inputMonitor {
                NSEvent.removeMonitor(inputMonitor)
                self.inputMonitor = nil
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            // Teardown must not overwrite the saved offset.
            if newWindow == nil { stopTracking() }
            super.viewWillMove(toWindow: newWindow)
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
            stopMonitoringInput()
        }

        private func stopTracking() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            stopMonitoringInput()
            restoreTarget = nil
            position?.scrollBy = nil
            position?.isSavingRows = false
        }

        private func finishRestoring() {
            stopMonitoringInput()
            restoreTarget = nil
            position?.scrollBy = nil
            position?.isSavingRows = true
        }

        private func scrollViewDidChange(_ scrollView: NSScrollView) {
            if restoreTarget != nil {
                restore(in: scrollView)
            } else if position?.scrollBy == nil {
                position?.offset = scrollView.contentView.bounds.origin.y
            }
        }

        private func restore(in scrollView: NSScrollView) {
            // Moving the clip view posts bounds and frame changes synchronously. When AppKit or
            // SwiftUI adjusts the origin in response, re-entering would recurse until the stack overflows.
            guard let restoreTarget, !isRestoring else { return }
            let clipView = scrollView.contentView
            var proposed = clipView.bounds
            proposed.origin.y = restoreTarget
            let destination = clipView.constrainBoundsRect(proposed).origin
            guard destination != clipView.bounds.origin else { return }
            isRestoring = true
            defer { isRestoring = false }
            clipView.setBoundsOrigin(destination)
            scrollView.reflectScrolledClipView(clipView)
        }
    }
}

import SwiftUI

struct DetailNavigationAnimation: ViewModifier {
    let trackURN: String?
    let isCollection: Bool
    let isVisible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var wasVisible = true

    init(trackURN: String?, isCollection: Bool, bounds: CGRect, in geometry: GeometryProxy) {
        self.trackURN = trackURN
        self.isCollection = isCollection
        // Include the toolbar and footer insets, which content scrolls behind.
        let insets = geometry.safeAreaInsets
        let viewport = CGRect(
            x: 0, y: -insets.top,
            width: geometry.size.width, height: geometry.size.height + insets.top + insets.bottom
        )
        isVisible = bounds.intersects(viewport)
    }

    func body(content: Content) -> some View {
        content
            // Track changes, scrolling, and resizing stay immediate.
            .animation(nil, value: trackURN)
            // Only the move between track and collection layouts uses the spring.
            // Skip it when either slot is scrolled out of view, so controls don't fly in from the edge.
            .animation(
                reduceMotion || !(wasVisible && isVisible) ? nil : .spring(response: 0.42, dampingFraction: 0.9),
                value: isCollection
            )
            // Runs after the update that compares layouts, so that update still sees the old slot.
            .onChange(of: isVisible, initial: true) { wasVisible = isVisible }
    }
}

// Reset the entrance only when navigation also changes the displayed track.
// Playback changes within a collection keep the controls mounted.
struct DetailControlLifetime: ViewModifier {
    let routeID: AnyHashable
    let trackURN: String?
    @State private var generation = 0

    private struct Destination: Equatable {
        let routeID: AnyHashable
        let trackURN: String?
    }

    func body(content: Content) -> some View {
        content
            .id(generation)
            .transition(.identity)
            .onChange(of: Destination(routeID: routeID, trackURN: trackURN)) { old, new in
                if old.routeID != new.routeID && old.trackURN != new.trackURN {
                    generation += 1
                }
            }
    }
}

// Buttons that only the track or only the collection layout has. The page reserves their
// layout while the navigation host draws them, so the old page's buttons outlive it to scale away.
struct DetailSwapButtonSource: Identifiable {
    let id: String
    let bounds: Anchor<CGRect>
    let trackURN: String?
    let isCollection: Bool
    let button: AnyView
    let scrollTarget: DetailScrollTarget
}

struct DetailSwapButtonPreferenceKey: PreferenceKey {
    static let defaultValue: [DetailSwapButtonSource] = []

    static func reduce(value: inout [DetailSwapButtonSource], nextValue: () -> [DetailSwapButtonSource]) {
        value += nextValue()
    }
}

extension View {
    // The host does not inherit the page's environment, so the button must carry its own styling.
    func detailSwapSlot(id: String, trackURN: String?, isCollection: Bool = false) -> some View {
        DetailScrollSlot { scrollTarget in
            hidden()
                .accessibilityHidden(true)
                .anchorPreference(key: DetailSwapButtonPreferenceKey.self, value: .bounds) {
                    [DetailSwapButtonSource(
                        id: id, bounds: $0, trackURN: trackURN, isCollection: isCollection,
                        button: AnyView(self), scrollTarget: scrollTarget
                    )]
                }
        }
    }
}

struct DetailSwapButtonOverlay: ViewModifier {
    let routeID: AnyHashable

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(DetailSwapButtonPreferenceKey.self) { sources in
            GeometryReader { geometry in
                if let first = sources.first {
                    ZStack {
                        ForEach(sources) { source in
                            let bounds = geometry[source.bounds]
                            source.button
                                .overlay(DetailScrollForwarder(target: source.scrollTarget))
                                .modifier(FadeInOnAppear())
                                .geometryGroup()
                                .frame(width: bounds.width, height: bounds.height)
                                .position(x: bounds.midX, y: bounds.midY)
                                // Positioning fills the host, so name the button's center as the anchor.
                                .transition(.scale(scale: 0, anchor: UnitPoint(
                                    x: bounds.midX / max(geometry.size.width, 1),
                                    y: bounds.midY / max(geometry.size.height, 1)
                                )).combined(with: .opacity))
                        }
                    }
                    .modifier(DetailNavigationAnimation(
                        trackURN: first.trackURN, isCollection: first.isCollection,
                        bounds: sources.reduce(geometry[first.bounds]) { $0.union(geometry[$1.bounds]) },
                        in: geometry
                    ))
                    .modifier(DetailControlLifetime(routeID: routeID, trackURN: first.trackURN))
                }
            }
            .mask {
                // Match the scroll view: content can pass behind the toolbar.
                Rectangle().ignoresSafeArea(edges: .top)
            }
        }
    }
}

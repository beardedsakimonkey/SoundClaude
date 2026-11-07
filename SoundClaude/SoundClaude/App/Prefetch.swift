import AppKit
import SwiftUI

/// When a view warms its destination. Navigation happens on mouse up, so a press
/// still gains the click's duration; a hover that rests gains more.
struct PrefetchTriggers: Equatable {
    /// How long the pointer must rest on the view, or nil to ignore hover.
    var hoverDelay: Duration? = .milliseconds(150)
    var onPress = true

    static let standard = Self()
    /// For large areas the pointer sweeps across, such as whole cards.
    static let pressOnly = Self(hoverDelay: nil)
    /// For views that already act on mouse down.
    static let hoverOnly = Self(onPress: false)
}

/// Routes prefetches to the model. A reference type, so that injecting it does
/// not invalidate the many views that read it whenever the root view updates.
@MainActor
final class Prefetcher {
    private let model: AppModel
    /// The tab that an artist page would open on, if not Tracks.
    var rememberedArtistTab: (SoundCloudUser) -> ArtistContentTab? = { _ in nil }

    init(model: AppModel) {
        self.model = model
    }

    func prefetch(_ target: PrefetchTarget) {
        model.prefetch(target)
        if case let .artist(artist) = target,
           let tab = rememberedArtistTab(artist), tab != .tracks {
            model.prefetch(.artistTab(artist, tab))
        }
    }
}

extension EnvironmentValues {
    @Entry var prefetcher: Prefetcher?
}

extension View {
    /// Warms `target` when the pointer rests on this view or presses it. Pass
    /// `onHover` instead of adding `onContentHover`, to share its tracking.
    /// `path` limits hover to a shape, as with `onContentHover(in:)`.
    func prefetch(
        _ target: PrefetchTarget?,
        _ triggers: PrefetchTriggers = .standard,
        in path: Path? = nil,
        onHover: ((Bool) -> Void)? = nil
    ) -> some View {
        modifier(TargetPrefetchModifier(target: target, triggers: triggers, path: path, onHover: onHover))
    }

    /// Runs `action` when the pointer rests on this view or presses it.
    func prefetch(
        _ triggers: PrefetchTriggers = .standard,
        in path: Path? = nil,
        onHover: ((Bool) -> Void)? = nil,
        perform action: @escaping () -> Void
    ) -> some View {
        modifier(PrefetchModifier(triggers: triggers, path: path, onHover: onHover, action: action))
    }
}

private struct TargetPrefetchModifier: ViewModifier {
    let target: PrefetchTarget?
    let triggers: PrefetchTriggers
    let path: Path?
    let onHover: ((Bool) -> Void)?
    @Environment(\.prefetcher) private var prefetcher

    func body(content: Content) -> some View {
        content.modifier(PrefetchModifier(triggers: triggers, path: path, onHover: onHover) {
            if let target { prefetcher?.prefetch(target) }
        })
    }
}

private struct PrefetchModifier: ViewModifier {
    let triggers: PrefetchTriggers
    let path: Path?
    let onHover: ((Bool) -> Void)?
    let action: () -> Void
    // Not observed: hover and presses must not update the view.
    @State private var region = PrefetchRegion()

    func body(content: Content) -> some View {
        let region = region
        region.triggers = triggers
        region.action = action
        // Hover respects overlays that suppress it, so covered views do not prefetch.
        return content.onContentHover(in: path) { isHovering in
            region.setHovering(isHovering)
            onHover?(isHovering)
        }
    }
}

@MainActor
private final class PrefetchRegion {
    var triggers = PrefetchTriggers.standard
    var action: () -> Void = {}
    private var hoverTask: Task<Void, Never>?
    private var hasFired = false

    func setHovering(_ isHovering: Bool) {
        hoverTask?.cancel()
        hoverTask = nil
        guard isHovering else {
            PressMonitor.shared.remove(self)
            return
        }
        // Each visit fires once; the shared requests make a repeat redundant.
        hasFired = false
        if triggers.onPress { PressMonitor.shared.add(self) }
        if let delay = triggers.hoverDelay {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.fire()
            }
        }
    }

    func fire() {
        hoverTask?.cancel()
        hoverTask = nil
        guard !hasFired else { return }
        hasFired = true
        action()
    }
}

// Observes mouse down without consuming it, so prefetching works with any button
// style, gesture, drag source, or context menu on the hovered view.
@MainActor
private final class PressMonitor {
    static let shared = PressMonitor()

    private struct WeakRegion {
        weak var region: PrefetchRegion?
    }

    private var regions: [ObjectIdentifier: WeakRegion] = [:]
    private var monitor: Any?

    func add(_ region: PrefetchRegion) {
        regions[ObjectIdentifier(region)] = WeakRegion(region: region)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            // Control-click opens a context menu rather than navigating.
            if !event.modifierFlags.contains(.control) {
                MainActor.assumeIsolated { PressMonitor.shared.press() }
            }
            return event
        }
    }

    func remove(_ region: PrefetchRegion) {
        regions[ObjectIdentifier(region)] = nil
    }

    private func press() {
        // Nested regions are all hovered; each fires its own target.
        regions = regions.filter { $0.value.region != nil }
        for entry in Array(regions.values) { entry.region?.fire() }
    }
}

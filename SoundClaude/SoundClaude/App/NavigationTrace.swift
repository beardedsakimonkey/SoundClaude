import AppKit
import QuartzCore
import SwiftUI
import os

/// Records what the main thread does after a route change and prints one report per navigation.
/// Run with SOUNDCLAUDE_NAV_TIMINGS=1 (`make nav-trace`). Works in Release, where perf should be
/// judged; otherwise every call returns immediately. Also emits Points of Interest signposts,
/// so a Time Profiler recording can be narrowed to one navigation.
/// Labels are fixed strings: never pass track titles, URLs, or other account data.
enum NavigationTrace {
    static let isEnabled = ProcessInfo.processInfo.environment["SOUNDCLAUDE_NAV_TIMINGS"] == "1"

    // Long enough to include the viewed-track prefetch and the waveform's springs.
    private static let window: CFTimeInterval = 2.5
    // Shorter slices are ordinary frames; they still count toward the totals.
    private static let reportedSlice: CFTimeInterval = 0.008
    // A busy slice can span many frames, because the run loop need not sleep between them.
    // Only a gap in these callbacks shows that frames were actually missed.
    private static let reportedFrameGap: CFTimeInterval = 0.025

    private static let log = OSLog(subsystem: "SoundClaude", category: .pointsOfInterest)
    private static var active: Trace?
    private static var generation = 0
    private static var sliceStart: CFTimeInterval = 0
    private static var observersStart: CFTimeInterval = 0
    private static var displayCycle: CFTimeInterval = 0
    private static var observers: [CFRunLoopObserver] = []
    @MainActor private static let frames = FrameTicker()

    private struct Aggregate {
        var count = 0
        var total: CFTimeInterval = 0
        var longest: CFTimeInterval = 0
        var first: CFTimeInterval = 0
        var last: CFTimeInterval = 0

        mutating func add(_ duration: CFTimeInterval, at time: CFTimeInterval) {
            if count == 0 { first = time }
            count += 1
            total += duration
            longest = max(longest, duration)
            last = time
        }
    }

    private struct Trace {
        let label: String
        let origin: CFTimeInterval
        let signpost: OSSignpostID
        var timeline: [(time: CFTimeInterval, text: String)] = []
        var aggregates: [String: Aggregate] = [:]
        var busyTotal: CFTimeInterval = 0
        var busySlices = 0
        var longestBusy: CFTimeInterval = 0
        var pageAppeared = false
        var pageCommitted = false
        var awaitingFirstFrame = false
        var frameCount = 0
        var lastFrame: CFTimeInterval?
        var longestFrameGap: CFTimeInterval = 0

        mutating func recordSlice(start sliceStart: CFTimeInterval, displayCycle: CFTimeInterval, end: CFTimeInterval) {
            let start = max(sliceStart, origin)
            let busy = end - start
            guard busy > 0 else { return }
            busyTotal += busy
            busySlices += 1
            longestBusy = max(longestBusy, busy)
            if busy >= reportedSlice {
                let display = min(displayCycle, busy)
                timeline.append((end, String(
                    format: "== main thread busy %.1f ms (in observers %.1f, in sources and queue %.1f)",
                    busy * 1_000, display * 1_000, (busy - display) * 1_000
                )))
            }
        }

        // Commit ends the display cycle, and the next busy work can follow without sleeping.
        mutating func recordDisplayCycleEnd(at end: CFTimeInterval) {
            guard pageAppeared, !pageCommitted else { return }
            timeline.append((end, "page committed"))
            pageCommitted = true
            awaitingFirstFrame = true
        }

        mutating func recordFrame(at now: CFTimeInterval) {
            if let lastFrame {
                let gap = now - lastFrame
                longestFrameGap = max(longestFrameGap, gap)
                if gap >= reportedFrameGap {
                    timeline.append((now, String(format: "-- frame gap %.1f ms", gap * 1_000)))
                }
            }
            lastFrame = now
            frameCount += 1
            if awaitingFirstFrame {
                timeline.append((now, "first vsync callback after commit"))
                awaitingFirstFrame = false
            }
        }
    }

    // MARK: Recording

    @MainActor static func begin(from: String, to: String) {
        guard isEnabled else { return }
        finish()
        installObservers()

        let now = CACurrentMediaTime()
        // Measure from the click when this change is handling one. Task-driven routes run later.
        let event = NSApp.currentEvent
        let eventAge = event.map { now - $0.timestamp }
        let isFromEvent = eventAge.map { $0 >= 0 && $0 < 1 } ?? false
        let origin = isFromEvent ? now - eventAge! : now

        let label = "\(from) -> \(to)"
        var trace = Trace(label: label, origin: origin, signpost: OSSignpostID(log: log))
        if isFromEvent, let event {
            trace.timeline.append((origin, "input event (\(eventName(event.type)))"))
        }
        trace.timeline.append((now, "route changed"))
        // A stall right after the click comes before the first callback.
        trace.lastFrame = now
        os_signpost(.begin, log: log, name: "Navigation", signpostID: trace.signpost, "%{public}s", label)
        active = trace

        frames.start()
        generation += 1
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + window) {
            if current == generation { finish() }
        }
    }

    /// A point on the timeline. Safe to call from a body.
    static func mark(_ name: StaticString) {
        guard isEnabled, Thread.isMainThread, active != nil else { return }
        os_signpost(.event, log: log, name: name)
        active?.timeline.append((CACurrentMediaTime(), name.description))
    }

    /// Timed work, reported as a count and total rather than on the timeline.
    static func measure<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        guard isEnabled else { return try work() }
        return try timed(signpost: name, label: name.description, work)
    }

    /// How often something ran and when it stopped, such as an animated body.
    static func count(_ name: @autoclosure () -> String) {
        guard isEnabled, Thread.isMainThread, active != nil else { return }
        active?.aggregates[name(), default: Aggregate()].add(0, at: CACurrentMediaTime())
    }

    fileprivate static func timed<T>(
        signpost: StaticString, label: @autoclosure () -> String, _ work: () throws -> T
    ) rethrows -> T {
        guard Thread.isMainThread, active != nil else { return try work() }
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: signpost, signpostID: id)
        let start = CACurrentMediaTime()
        defer {
            let end = CACurrentMediaTime()
            os_signpost(.end, log: log, name: signpost, signpostID: id)
            active?.aggregates[label(), default: Aggregate()].add(end - start, at: end)
        }
        return try work()
    }

    fileprivate static func pageAppeared() {
        mark("page appeared")
        active?.pageAppeared = true
    }

    // MARK: Main thread

    // Each wake-to-sleep run of the main thread is split by where the work ran. Run loop observers
    // host AppKit's display cycle: SwiftUI's update, layout, drawing, and the Core Animation commit.
    // Sources also run commits on macOS 26, driven by UC::DriverCore, so time outside observers
    // can be frame work as well as events, timers, and the main queue.
    private static func installObservers() {
        guard observers.isEmpty else { return }
        let add = { (activity: CFRunLoopActivity, order: CFIndex, handler: @escaping () -> Void) in
            guard let observer = CFRunLoopObserverCreateWithHandler(
                kCFAllocatorDefault, activity.rawValue, true, order, { _, _ in handler() }
            ) else { return }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer)
        }
        add(.afterWaiting, .min) {
            sliceStart = CACurrentMediaTime()
            displayCycle = 0
        }
        for activity in [CFRunLoopActivity.entry, .exit, .beforeWaiting] {
            add(activity, .min) { observersStart = CACurrentMediaTime() }
            add(activity, .max) {
                let now = CACurrentMediaTime()
                displayCycle += now - observersStart
                active?.recordDisplayCycleEnd(at: now)
                if activity == .beforeWaiting { endSlice(at: now) }
            }
        }
    }

    private static func endSlice(at end: CFTimeInterval) {
        active?.recordSlice(start: sliceStart, displayCycle: displayCycle, end: end)
    }

    fileprivate static func frameTick() {
        active?.recordFrame(at: CACurrentMediaTime())
    }

    // MARK: Report

    @MainActor private static func finish() {
        guard let trace = active else { return }
        active = nil
        frames.stop()
        os_signpost(.end, log: log, name: "Navigation", signpostID: trace.signpost)

        // Printed afterward so that formatting and I/O do not appear in the timings.
        var lines = ["", "[nav] \(trace.label)", "    +ms  (from the click when there was one)"]
        for entry in trace.timeline.enumerated().sorted(by: {
            ($0.element.time, $0.offset) < ($1.element.time, $1.offset)
        }) {
            lines.append(String(format: "%7.1f  ", (entry.element.time - trace.origin) * 1_000) + entry.element.text)
        }
        lines.append(String(
            format: "  main thread: %.1f ms busy over %d slices, longest %.1f ms",
            trace.busyTotal * 1_000, trace.busySlices, trace.longestBusy * 1_000
        ))
        lines.append(String(
            format: "  frames: %d vsync callbacks, longest gap %.1f ms",
            trace.frameCount, trace.longestFrameGap * 1_000
        ))
        if !trace.aggregates.isEmpty {
            lines.append("  timed work (layout entries nest and include child bodies built during layout):")
            for (name, value) in trace.aggregates.sorted(by: { $0.value.total > $1.value.total }) {
                lines.append(String(
                    format: "%9.1f ms total  %7.1f max  x%-4d +%-7.1f to +%-7.1f ",
                    value.total * 1_000, value.longest * 1_000, value.count,
                    (value.first - trace.origin) * 1_000, (value.last - trace.origin) * 1_000
                ) + name)
            }
        }
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private static func eventName(_ type: NSEvent.EventType) -> String {
        switch type {
        case .leftMouseDown: "mouse down"
        case .leftMouseUp: "mouse up"
        case .keyDown: "key down"
        default: "other"
        }
    }
}

// Runs only during a trace. Callback gaps show frames the main thread could not service.
@MainActor private final class FrameTicker: NSObject {
    private var link: CADisplayLink?

    func start() {
        guard link == nil, let view = (NSApp.keyWindow ?? NSApp.mainWindow)?.contentView else { return }
        let link = view.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        NavigationTrace.frameTick()
    }
}

/// Times layout of one view. It forwards the proposal unchanged, but hides the child's
/// layout priority and text baselines, so do not place it where a parent reads those.
private struct NavigationLayoutProbe: Layout {
    let name: String

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        return NavigationTrace.timed(signpost: "Layout measure", label: "layout measure: \(name)") {
            child.sizeThatFits(proposal)
        }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        // SwiftUI applies placement later, so timing this call would always read zero.
        NavigationTrace.count("layout pass: \(name)")
        child.place(at: bounds.origin, proposal: proposal)
    }
}

private struct NavigationLayoutTraceModifier: ViewModifier {
    let name: String

    func body(content: Content) -> some View {
        if NavigationTrace.isEnabled {
            NavigationLayoutProbe(name: name) { content }
        } else {
            content
        }
    }
}

// AppKit draws after the update and layout, so this separates them from drawing and commit.
private struct NavigationDrawProbe: NSViewRepresentable {
    final class ProbeView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NavigationTrace.mark("draw phase reached page")
        }
    }

    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ nsView: ProbeView, context: Context) {}
}

private struct NavigationPageTraceModifier: ViewModifier {
    func body(content: Content) -> some View {
        if NavigationTrace.isEnabled {
            content
                .background(alignment: .topLeading) {
                    NavigationDrawProbe().frame(width: 1, height: 1)
                }
                .onAppear { NavigationTrace.pageAppeared() }
                .onDisappear { NavigationTrace.mark("page disappeared") }
        } else {
            content
        }
    }
}

extension View {
    func navigationTraceLayout(_ name: String) -> some View {
        modifier(NavigationLayoutTraceModifier(name: name))
    }

    func navigationTracePage() -> some View {
        modifier(NavigationPageTraceModifier())
    }
}

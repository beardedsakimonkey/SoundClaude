import Foundation
import os

/// Wall-clock intervals, including suspension and I/O waits. Available in Release builds.
/// Names are fixed labels: never pass account data, URLs, or credentials.
/// Synchronous intervals also run on cache actors; only UI milestones need the main actor.
enum LaunchMetrics {
    private static let log = OSLog(subsystem: "SoundClaude", category: "Launch")
    private static let origin = ProcessInfo.processInfo.systemUptime
    private static let printsTimings = ProcessInfo.processInfo.environment["SOUNDCLAUDE_LAUNCH_TIMINGS"] == "1"
    @MainActor private static var milestones: Set<String> = []

    struct Interval {
        fileprivate let name: StaticString
        fileprivate let id: OSSignpostID
        fileprivate let start: TimeInterval
    }

    static func begin(_ name: StaticString) -> Interval {
        _ = origin
        let interval = Interval(name: name, id: OSSignpostID(log: log),
                                start: ProcessInfo.processInfo.systemUptime)
        os_signpost(.begin, log: log, name: name, signpostID: interval.id)
        return interval
    }

    static func end(_ interval: Interval) {
        os_signpost(.end, log: log, name: interval.name, signpostID: interval.id)
        if printsTimings {
            let now = ProcessInfo.processInfo.systemUptime
            write(String(format: "[launch +%.1f ms] %@: %.1f ms\n",
                         (now - origin) * 1_000, String(describing: interval.name),
                         (now - interval.start) * 1_000))
        }
    }

    static func measure<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let interval = begin(name)
        defer { end(interval) }
        return try work()
    }

    @MainActor
    static func measureAsync<T>(_ name: StaticString, _ work: () async throws -> T) async rethrows -> T {
        let interval = begin(name)
        defer { end(interval) }
        return try await work()
    }

    @MainActor static func markOnce(_ name: StaticString) {
        guard milestones.insert(String(describing: name)).inserted else { return }
        os_signpost(.event, log: log, name: name)
        if printsTimings {
            write(String(format: "[launch +%.1f ms] %@\n",
                         (ProcessInfo.processInfo.systemUptime - origin) * 1_000,
                         String(describing: name)))
        }
    }

    private static func write(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}

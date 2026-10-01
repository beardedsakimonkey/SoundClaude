import Combine
import Foundation

// Native capture is replaced with a serial-queue probe. No audio permission,
// output device, or signed app is needed to test the controller lifecycle.
struct ProcessTapFormat: Sendable, Equatable {
    let sampleRate: Double
}

enum ProcessTapError: Error { case processNotReady }

final class ProcessTap: @unchecked Sendable {
    private static let lock = NSLock()
    private static var starts = 0
    private static var stops = 0
    static var counts: (starts: Int, stops: Int) {
        lock.withLock { (starts, stops) }
    }

    init(ringBuffer: OpaquePointer) {}
    func start(processIdentifier: pid_t) throws -> ProcessTapFormat {
        Self.lock.withLock { Self.starts += 1 }
        // Leave time for a second track or sign-out while native setup runs.
        Thread.sleep(forTimeInterval: 0.03)
        return ProcessTapFormat(sampleRate: 48_000)
    }
    func stop() { Self.lock.withLock { Self.stops += 1 } }
}

final class SpectrumAnalyzer: @unchecked Sendable {
    let ringBuffer = OpaquePointer(bitPattern: 1)!
    func start(sampleRate: Double) {}
    func stop() {}
    func stopAndReset() async {}
}

@main
struct AudioTapLifecycleTests {
    @MainActor
    static func main() async throws {
        let capture = AudioTapController(analyzer: SpectrumAnalyzer())
        let starting = Task { await capture.startForCurrentProcess() }
        try await until { capture.state == .starting }
        await capture.startForCurrentProcess()
        await starting.value
        precondition(capture.state == .running(ProcessTapFormat(sampleRate: 48_000)))
        let initial = ProcessTap.counts
        precondition(initial.starts == 1, "Track changes during setup must share the tap")

        for _ in 0..<10 { await capture.startForCurrentProcess() }
        precondition(ProcessTap.counts.starts == initial.starts)
        precondition(ProcessTap.counts.stops == initial.stops,
                     "Track changes must not tear down the running capture")

        capture.stop()
        precondition(capture.state == .idle)
        await capture.startForCurrentProcess()
        precondition(ProcessTap.counts.starts == initial.starts + 1,
                     "An explicit stop must allow a new capture session")

        capture.stop()
        let obsolete = Task { await capture.startForCurrentProcess() }
        let before = ProcessTap.counts.starts
        try await until { ProcessTap.counts.starts > before }
        capture.stop()
        await capture.startForCurrentProcess()
        await obsolete.value
        precondition(capture.state == .running(ProcessTapFormat(sampleRate: 48_000)),
                     "A stale setup must not stop or overwrite a newer session")
        capture.stop()
        print("Audio tap reuse, concurrent startup, and stop/restart tests passed")
    }

    @MainActor
    private static func until(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        fatalError("Timed out waiting for capture lifecycle")
    }
}

import Foundation

@MainActor
final class AudioTapController: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case running(ProcessTapFormat)
        case failed(String)

        var label: String {
            switch self {
            case .idle:
                return "Visualizer idle"
            case .starting:
                return "Starting audio capture"
            case let .running(format):
                return "Visualizer: \(Int(format.sampleRate)) Hz, \(format.channelCount) channels"
            case let .failed(message):
                return message
            }
        }
    }

    @Published private(set) var state: State = .idle

    let analyzer: SpectrumAnalyzer
    private let lifecycleQueue = DispatchQueue(
        label: "com.tim.soundclaude.native.process-tap",
        qos: .userInitiated
    )
    private let processTap: ProcessTap
    private var generation: UInt64 = 0

    init(analyzer: SpectrumAnalyzer) {
        self.analyzer = analyzer
        processTap = ProcessTap(ringBuffer: analyzer.ringBuffer)
    }

    func startForCurrentProcess() async {
        generation &+= 1
        let expectedGeneration = generation
        state = .starting
        await stopNativeTap()

        for attempt in 0..<30 {
            guard generation == expectedGeneration else { return }
            do {
                let format = try await startNativeTap(processIdentifier: getpid())
                guard generation == expectedGeneration else {
                    await stopNativeTap()
                    return
                }
                analyzer.start(sampleRate: format.sampleRate)
                state = .running(format)
                return
            } catch ProcessTapError.processNotReady where attempt < 29 {
                try? await Task.sleep(for: .milliseconds(100))
            } catch {
                state = .failed(
                    "The visualizer could not capture this app's audio. \(error.localizedDescription)"
                )
                return
            }
        }
    }

    func stop() {
        generation &+= 1
        state = .idle
        lifecycleQueue.async { [processTap, analyzer] in
            processTap.stop()
            analyzer.stop()
        }
    }

    private func startNativeTap(
        processIdentifier: pid_t
    ) async throws -> ProcessTapFormat {
        try await withCheckedThrowingContinuation { continuation in
            lifecycleQueue.async { [processTap] in
                do {
                    continuation.resume(
                        returning: try processTap.start(
                            processIdentifier: processIdentifier
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func stopNativeTap() async {
        await withCheckedContinuation { continuation in
            lifecycleQueue.async { [processTap] in
                processTap.stop()
                continuation.resume()
            }
        }
        await analyzer.stopAndReset()
    }
}

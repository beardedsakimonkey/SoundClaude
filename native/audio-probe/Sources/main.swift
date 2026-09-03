import Accelerate
import AppKit
import AVFoundation
import CoreAudio
import Foundation

private let fftSize = 2_048
private let binCount = 64

private struct ProbeInput: Decodable {
    let url: String
}

private enum ProbeError: LocalizedError {
    case invalidInput
    case invalidURL
    case coreAudio(String, OSStatus)
    case processNotReady
    case fftSetup

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "Expected one JSON line with a url field."
        case .invalidURL:
            return "The input did not contain a valid HTTPS or loopback URL."
        case let .coreAudio(operation, status):
            return "\(operation) failed with Core Audio status \(status)."
        case .processNotReady:
            return "The player audio process is not available yet."
        case .fftSetup:
            return "Accelerate could not create the FFT setup."
        }
    }
}

private func propertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
}

private func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else {
        throw ProbeError.coreAudio(operation, status)
    }
}

private func emit(_ value: [String: Any]) {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value),
          var line = String(data: data, encoding: .utf8)
    else { return }

    line.append("\n")
    FileHandle.standardOutput.write(Data(line.utf8))
}

private func emitError(_ error: Error) {
    emit([
        "type": "error",
        "message": error.localizedDescription,
    ])
}

/// A bounded PCM store shared by the Core Audio callback and FFT timer.
///
/// This lock is acceptable for the short proof. A production version should
/// replace it with a lock-free single-producer/single-consumer ring buffer.
private final class SampleRing: @unchecked Sendable {
    private let lock = NSLock()
    private var samples = [Float](repeating: 0, count: fftSize * 4)
    private var writeIndex = 0
    private var sampleCount = 0

    func append(_ inputData: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        guard !buffers.isEmpty else { return }

        let frameCount = buffers.reduce(Int.max) { current, buffer in
            guard buffer.mNumberChannels > 0 else { return current }
            let frames = Int(buffer.mDataByteSize)
                / (MemoryLayout<Float>.size * Int(buffer.mNumberChannels))
            return min(current, frames)
        }
        guard frameCount > 0, frameCount != Int.max else { return }

        lock.lock()
        defer { lock.unlock() }

        for frame in 0..<frameCount {
            var sum: Float = 0
            var channels = 0

            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                    continue
                }
                let channelCount = Int(buffer.mNumberChannels)
                for channel in 0..<channelCount {
                    sum += data[(frame * channelCount) + channel]
                }
                channels += channelCount
            }

            guard channels > 0 else { continue }
            samples[writeIndex] = sum / Float(channels)
            writeIndex = (writeIndex + 1) % samples.count
            sampleCount = min(sampleCount + 1, samples.count)
        }
    }

    func latestFrame() -> [Float]? {
        lock.lock()
        defer { lock.unlock() }

        guard sampleCount >= fftSize else { return nil }
        var frame = [Float](repeating: 0, count: fftSize)
        let start = (writeIndex - fftSize + samples.count) % samples.count
        for index in 0..<fftSize {
            frame[index] = samples[(start + index) % samples.count]
        }
        return frame
    }
}

private final class SpectrumAnalyzer: @unchecked Sendable {
    private let ring: SampleRing
    private let sampleRate: Double
    private let fftSetup: FFTSetup
    private let log2Size = vDSP_Length(log2(Float(fftSize)))
    private let window: [Float]
    private var smoothed = [Float](repeating: 0, count: binCount)

    init(ring: SampleRing, sampleRate: Double) throws {
        self.ring = ring
        self.sampleRate = sampleRate
        guard let setup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2)) else {
            throw ProbeError.fftSetup
        }
        fftSetup = setup

        var hann = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hann, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        window = hann
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    func frame() -> [String: Any]? {
        guard var pcm = ring.latestFrame() else { return nil }

        var rms: Float = 0
        vDSP_rmsqv(pcm, 1, &rms, vDSP_Length(pcm.count))
        vDSP_vmul(pcm, 1, window, 1, &pcm, 1, vDSP_Length(pcm.count))

        var real = [Float](repeating: 0, count: fftSize / 2)
        var imaginary = [Float](repeating: 0, count: fftSize / 2)

        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(
                    realp: realPointer.baseAddress!,
                    imagp: imaginaryPointer.baseAddress!
                )
                pcm.withUnsafeBytes { rawBuffer in
                    let complex = rawBuffer.bindMemory(to: DSPComplex.self)
                    vDSP_ctoz(complex.baseAddress!, 2, &split, 1, vDSP_Length(fftSize / 2))
                }
                vDSP_fft_zrip(
                    fftSetup,
                    &split,
                    1,
                    log2Size,
                    FFTDirection(kFFTDirection_Forward)
                )
            }
        }

        var power = [Float](repeating: 0, count: fftSize / 2)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(
                    realp: realPointer.baseAddress!,
                    imagp: imaginaryPointer.baseAddress!
                )
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(power.count))
            }
        }

        let minimumFrequency = 30.0
        let maximumFrequency = min(18_000.0, sampleRate / 2.0)
        let ratio = maximumFrequency / minimumFrequency
        var bins = [Float](repeating: 0, count: binCount)

        for band in 0..<binCount {
            let lowerFrequency = minimumFrequency * pow(ratio, Double(band) / Double(binCount))
            let upperFrequency = minimumFrequency * pow(ratio, Double(band + 1) / Double(binCount))
            let lowerIndex = max(1, Int(lowerFrequency * Double(fftSize) / sampleRate))
            let upperIndex = min(power.count - 1, max(lowerIndex, Int(upperFrequency * Double(fftSize) / sampleRate)))
            let peak = power[lowerIndex...upperIndex].max() ?? 0
            let decibels = 10 * log10(max(peak, 1e-12))
            let normalized = min(1, max(0, (decibels + 80) / 70))
            smoothed[band] = max(normalized, smoothed[band] * 0.78)
            bins[band] = smoothed[band]
        }

        return [
            "type": "spectrum",
            "time": ProcessInfo.processInfo.systemUptime,
            "rms": rms,
            "bins": bins,
        ]
    }
}

private final class AudioTapCapture: @unchecked Sendable {
    private let ring = SampleRing()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var timer: DispatchSourceTimer?
    private var analyzer: SpectrumAnalyzer?

    func start(processID: AudioObjectID) throws {
        let description = CATapDescription()
        description.name = "SoundClaude audio probe"
        description.processes = [processID]
        description.isPrivate = true
        description.isMixdown = true
        description.isMono = false
        description.isExclusive = false
        description.muteBehavior = .unmuted

        try check(
            AudioHardwareCreateProcessTap(description, &tapID),
            "AudioHardwareCreateProcessTap"
        )

        let tapUID = try readTapUID()
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SoundClaude audio probe",
            kAudioAggregateDeviceUIDKey: "com.tim.soundclaude.audio-probe.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        try check(
            AudioHardwareCreateAggregateDevice(
                aggregateDescription as CFDictionary,
                &aggregateDeviceID
            ),
            "AudioHardwareCreateAggregateDevice"
        )

        try attach(tapUID: tapUID)
        try waitForAggregateInput()
        let format = try readTapFormat()
        analyzer = try SpectrumAnalyzer(ring: ring, sampleRate: format.mSampleRate)

        let callbackQueue = DispatchQueue(
            label: "com.tim.soundclaude.audio-probe.capture",
            qos: .userInteractive
        )
        try check(
            AudioDeviceCreateIOProcIDWithBlock(
                &ioProcID,
                aggregateDeviceID,
                callbackQueue
            ) { [ring] _, inputData, _, _, _ in
                ring.append(inputData)
            },
            "AudioDeviceCreateIOProcIDWithBlock"
        )

        guard let ioProcID else {
            throw ProbeError.coreAudio("AudioDeviceCreateIOProcIDWithBlock", -1)
        }
        try check(
            AudioDeviceStart(aggregateDeviceID, ioProcID),
            "AudioDeviceStart"
        )

        emit([
            "type": "format",
            "sampleRate": format.mSampleRate,
            "channels": format.mChannelsPerFrame,
            "formatID": format.mFormatID,
            "formatFlags": format.mFormatFlags,
            "bytesPerFrame": format.mBytesPerFrame,
            "bitsPerChannel": format.mBitsPerChannel,
            "fftSize": fftSize,
            "binCount": binCount,
        ])
        startTimer()
    }

    func stop() {
        timer?.cancel()
        timer = nil

        if aggregateDeviceID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    private func readTapUID() throws -> CFString {
        var address = propertyAddress(kAudioTapPropertyUID)
        var size = UInt32(MemoryLayout<CFString>.stride)
        var uid: CFString = "" as CFString
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, pointer)
        }
        try check(status, "Read tap UID")
        return uid
    }

    private func readTapFormat() throws -> AudioStreamBasicDescription {
        var address = propertyAddress(kAudioTapPropertyFormat)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.stride)
        var format = AudioStreamBasicDescription()
        try check(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format),
            "Read tap format"
        )
        return format
    }

    private func attach(tapUID: CFString) throws {
        var address = propertyAddress(kAudioAggregateDevicePropertyTapList)
        var list: CFArray = [tapUID] as CFArray
        let size = UInt32(MemoryLayout<CFArray>.stride)
        let status = withUnsafeMutablePointer(to: &list) { pointer in
            AudioObjectSetPropertyData(
                aggregateDeviceID,
                &address,
                0,
                nil,
                size,
                pointer
            )
        }
        try check(status, "Attach tap to aggregate device")
    }

    private func waitForAggregateInput() throws {
        var address = propertyAddress(
            kAudioDevicePropertyStreams,
            scope: kAudioDevicePropertyScopeInput
        )

        for _ in 0..<40 {
            var size: UInt32 = 0
            let status = AudioObjectGetPropertyDataSize(
                aggregateDeviceID,
                &address,
                0,
                nil,
                &size
            )
            if status == noErr, size >= UInt32(MemoryLayout<AudioObjectID>.stride) {
                return
            }
            usleep(50_000)
        }

        throw ProbeError.coreAudio("Wait for aggregate input stream", kAudioHardwareNotReadyError)
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(
            flags: .strict,
            queue: DispatchQueue(label: "com.tim.soundclaude.audio-probe.fft", qos: .userInteractive)
        )
        timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let frame = self?.analyzer?.frame() else { return }
            emit(frame)
        }
        timer.resume()
        self.timer = timer
    }
}

private final class Probe: NSObject {
    private let player: AVPlayer
    private let capture = AudioTapCapture()
    private var playerStatusObservation: NSKeyValueObservation?
    private var captureStarted = false
    private var captureAttempts = 0

    init(url: URL) {
        player = AVPlayer(url: url)
        super.init()
    }

    func start() {
        emit(["type": "status", "state": "loading"])
        playerStatusObservation = player.currentItem?.observe(\.status, options: [.initial, .new]) {
            [weak self] item, _ in
            guard let self else { return }
            switch item.status {
            case .readyToPlay:
                emit(["type": "status", "state": "playing"])
                self.beginCaptureWhenReady()
            case .failed:
                emitError(item.error ?? ProbeError.invalidURL)
            case .unknown:
                break
            @unknown default:
                break
            }
        }
        player.play()
    }

    func stop() {
        player.pause()
        capture.stop()
    }

    private func beginCaptureWhenReady() {
        guard !captureStarted else { return }
        captureAttempts += 1

        do {
            let processID = try currentAudioProcessID()
            emit([
                "type": "process",
                "pid": getpid(),
                "audioObjectID": processID,
                "runningOutput": processIsRunningOutput(processID),
            ])
            try capture.start(processID: processID)
            captureStarted = true
            emit(["type": "status", "state": "capturing"])
        } catch ProbeError.processNotReady where captureAttempts < 30 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.beginCaptureWhenReady()
            }
        } catch {
            emitError(error)
            stop()
        }
    }

    private func currentAudioProcessID() throws -> AudioObjectID {
        var address = propertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var processID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.stride)

        let status = withUnsafePointer(to: &pid) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.stride),
                qualifier,
                &size,
                &processID
            )
        }
        if status != noErr || processID == kAudioObjectUnknown {
            throw ProbeError.processNotReady
        }
        return processID
    }

    private func processIsRunningOutput(_ processID: AudioObjectID) -> Bool {
        var address = propertyAddress(kAudioProcessPropertyIsRunningOutput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.stride)
        let status = AudioObjectGetPropertyData(
            processID,
            &address,
            0,
            nil,
            &size,
            &value
        )
        return status == noErr && value != 0
    }
}

@main
private enum AudioProbeMain {
    static func main() {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()

        guard let line = readLine(),
              let data = line.data(using: .utf8),
              let input = try? JSONDecoder().decode(ProbeInput.self, from: data)
        else {
            emitError(ProbeError.invalidInput)
            exit(EXIT_FAILURE)
        }
        guard let url = URL(string: input.url),
              url.scheme == "https"
                || (url.scheme == "http" && (url.host == "127.0.0.1" || url.host == "::1"))
        else {
            emitError(ProbeError.invalidURL)
            exit(EXIT_FAILURE)
        }

        let probe = Probe(url: url)
        let arguments = CommandLine.arguments
        let stopFile = arguments.firstIndex(of: "--stop-file").flatMap { index in
            arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        }
        let stopTimer = stopFile.map { path -> DispatchSourceTimer in
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
            timer.setEventHandler {
                if !FileManager.default.fileExists(atPath: path) {
                    probe.stop()
                    NSApplication.shared.terminate(nil)
                }
            }
            timer.resume()
            return timer
        }
        let signals = [SIGINT, SIGTERM].map { signalNumber -> DispatchSourceSignal in
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                probe.stop()
                NSApplication.shared.terminate(nil)
            }
            source.resume()
            return source
        }
        withExtendedLifetime((signals, stopTimer)) {
            probe.start()
            NSApplication.shared.run()
            probe.stop()
        }
    }
}

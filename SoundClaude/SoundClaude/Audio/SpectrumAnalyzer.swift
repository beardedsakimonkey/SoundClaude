import Accelerate
import Foundation

final class SpectrumAnalyzer: @unchecked Sendable {
    static let ringCapacity = 8_192
    static let fftSize = 2_048
    static let hopSize = 512
    static let bandCount = Int(SCSpectrumBandCount)

    let ringBuffer: OpaquePointer
    let spectrumBuffer: OpaquePointer

    private let queue = DispatchQueue(
        label: "com.tim.soundclaude.native.spectrum",
        qos: .userInteractive
    )
    private var timer: DispatchSourceTimer?
    private var fftSetup: FFTSetup?
    private let log2FFTSize = vDSP_Length(log2(Float(fftSize)))
    private var sampleRate = 48_000.0

    private var pcm = [Float](repeating: 0, count: fftSize)
    private var hop = [Float](repeating: 0, count: hopSize)
    private var window = [Float](repeating: 0, count: fftSize)
    private var work = [Float](repeating: 0, count: fftSize)
    private var real = [Float](repeating: 0, count: fftSize / 2)
    private var imaginary = [Float](repeating: 0, count: fftSize / 2)
    private var power = [Float](repeating: 0, count: fftSize / 2)
    private var bands = [Float](repeating: 0, count: bandCount)
    private var smoothed = [Float](repeating: 0, count: bandCount)
    private let impulseWindow: [Float] = (0..<fftSize).map { index in
        let phase = 2 * Double.pi * Double(index) / Double(fftSize)
        return Float(0.42 - 0.5 * cos(phase) + 0.08 * cos(2 * phase))
    }
    private var impulseMagnitudes = [Float](repeating: 0, count: fftSize / 2)
    private var fftPowerScale: Float = 1

    init?() {
        guard let ringBuffer = SCPMRingBufferCreate(
            UInt32(Self.ringCapacity)
        ), let spectrumBuffer = SCSpectrumBufferCreate() else {
            return nil
        }
        self.ringBuffer = ringBuffer
        self.spectrumBuffer = spectrumBuffer
        vDSP_hann_window(
            &window,
            vDSP_Length(window.count),
            Int32(vDSP_HANN_NORM)
        )
        let windowGain = window.reduce(0, +)
        fftPowerScale = 1 / (windowGain * windowGain)
        fftSetup = vDSP_create_fftsetup(
            log2FFTSize,
            FFTRadix(kFFTRadix2)
        )
        if fftSetup == nil {
            SCPMRingBufferDestroy(ringBuffer)
            SCSpectrumBufferDestroy(spectrumBuffer)
            return nil
        }
    }

    deinit {
        timer?.cancel()
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
        SCPMRingBufferDestroy(ringBuffer)
        SCSpectrumBufferDestroy(spectrumBuffer)
    }

    /// Average the smoothed spectrum into low, middle, and high frequency levels.
    func playbackIndicatorLevels() -> [Float]? {
        var snapshot = [Float](repeating: 0, count: Self.bandCount)
        let didRead = snapshot.withUnsafeMutableBufferPointer { pointer in
            SCSpectrumBufferRead(spectrumBuffer, pointer.baseAddress, nil, nil, nil)
        }
        guard didRead else { return nil }

        return (0..<3).map { index in
            let lower = index * Self.bandCount / 3
            let upper = (index + 1) * Self.bandCount / 3
            let average = snapshot[lower..<upper].reduce(0, +) / Float(upper - lower)
            return min(1, max(0, average))
        }
    }

    func start(sampleRate: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopOnQueue()
            self.sampleRate = sampleRate
            _ = self.pcm.withUnsafeMutableBytes {
                $0.initializeMemory(as: UInt8.self, repeating: 0)
            }
            _ = self.smoothed.withUnsafeMutableBytes {
                $0.initializeMemory(as: UInt8.self, repeating: 0)
            }
            self.impulseMagnitudes = [Float](repeating: 0, count: Self.fftSize / 2)
            SCSpectrumBufferClear(self.spectrumBuffer)

            let timer = DispatchSource.makeTimerSource(
                flags: .strict,
                queue: self.queue
            )
            let interval = Double(Self.hopSize) / sampleRate
            timer.schedule(
                deadline: .now() + interval,
                repeating: interval,
                leeway: .milliseconds(1)
            )
            timer.setEventHandler { [weak self] in
                self?.consumeAvailableHops()
            }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopOnQueue()
            SCPMRingBufferReset(self.ringBuffer)
            SCSpectrumBufferClear(self.spectrumBuffer)
        }
    }

    func stopAndReset() async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                if let self {
                    self.stopOnQueue()
                    SCPMRingBufferReset(self.ringBuffer)
                    SCSpectrumBufferClear(self.spectrumBuffer)
                }
                continuation.resume()
            }
        }
    }

    private func stopOnQueue() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }

    private func consumeAvailableHops() {
        var consumed = 0
        while SCPMRingBufferAvailable(ringBuffer) >= UInt32(Self.hopSize),
              consumed < 4 {
            let count = hop.withUnsafeMutableBufferPointer { pointer in
                SCPMRingBufferRead(
                    ringBuffer,
                    pointer.baseAddress,
                    UInt32(pointer.count)
                )
            }
            guard count == Self.hopSize else { return }
            rollInHop()
            analyze(samples: pcm, sampleRate: sampleRate)
            consumed += 1
        }
    }

    private func rollInHop() {
        pcm.withUnsafeMutableBufferPointer { pcmPointer in
            guard let pcmBase = pcmPointer.baseAddress else { return }
            memmove(
                pcmBase,
                pcmBase.advanced(by: Self.hopSize),
                (Self.fftSize - Self.hopSize) * MemoryLayout<Float>.stride
            )
            hop.withUnsafeBufferPointer { hopPointer in
                guard let hopBase = hopPointer.baseAddress else { return }
                memcpy(
                    pcmBase.advanced(by: Self.fftSize - Self.hopSize),
                    hopBase,
                    Self.hopSize * MemoryLayout<Float>.stride
                )
            }
        }
    }

    /// Analyze one complete PCM window. Call only on the worker queue while running.
    func analyze(samples: [Float], sampleRate: Double) {
        precondition(samples.count == Self.fftSize && sampleRate > 0)
        guard let fftSetup else { return }

        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(Self.fftSize))
        computePower(samples: samples, window: window, setup: fftSetup)

        let minimumFrequency = 30.0
        let maximumFrequency = min(18_000.0, sampleRate / 2.0)
        let frequencyRatio = maximumFrequency / minimumFrequency
        for band in 0..<Self.bandCount {
            let lowerFrequency = minimumFrequency * pow(
                frequencyRatio,
                Double(band) / Double(Self.bandCount)
            )
            let upperFrequency = minimumFrequency * pow(
                frequencyRatio,
                Double(band + 1) / Double(Self.bandCount)
            )
            let lowerIndex = max(
                1,
                Int(lowerFrequency * Double(Self.fftSize) / sampleRate)
            )
            let upperIndex = min(
                power.count - 1,
                max(
                    lowerIndex,
                    Int(upperFrequency * Double(Self.fftSize) / sampleRate)
                )
            )
            var peak: Float = 0
            if lowerIndex <= upperIndex {
                for index in lowerIndex...upperIndex {
                    peak = max(peak, power[index])
                }
            }
            let normalizedPower = peak * fftPowerScale
            let decibels = 10 * log10(max(normalizedPower, 1e-12))
            let normalized = min(1, max(0, (decibels + 72) / 60))
            let smoothing: Float = normalized > smoothed[band] ? 0.65 : 0.12
            smoothed[band] += (normalized - smoothed[band]) * smoothing
            bands[band] = smoothed[band]
        }
        computePower(samples: samples, window: impulseWindow, setup: fftSetup)
        let bassLevel = readImpulseLevel(sampleRate: sampleRate, lowHz: 25, highHz: 140)
        let trebleLevel = readImpulseLevel(sampleRate: sampleRate, lowHz: 2400, highHz: 12000)
        bands.withUnsafeBufferPointer { pointer in
            SCSpectrumBufferPublish(spectrumBuffer, pointer.baseAddress, rms, bassLevel, trebleLevel)
        }
    }

    /// Web Audio's Blackman FFT uses 1/N normalization. vDSP's real FFT
    /// returns twice the DFT, so divide magnitudes by 2N.
    /// https://www.w3.org/TR/webaudio/#fft-windowing-and-smoothing-over-time
    private func readImpulseLevel(sampleRate: Double, lowHz: Double, highHz: Double) -> Float {
        let binHz = sampleRate / Double(Self.fftSize)
        let lower = max(0, Int(floor(lowHz / binHz)))
        let upper = min(power.count - 1, Int(ceil(highHz / binHz)))
        guard lower <= upper else { return 0 }
        var sum: Float = 0
        for index in lower...upper {
            // Bin zero packs DC and Nyquist; only DC belongs in this band.
            let magnitude = (index == 0 ? abs(real[0]) : sqrt(power[index]))
                / Float(2 * Self.fftSize)
            impulseMagnitudes[index] = 0.5 * impulseMagnitudes[index] + 0.5 * magnitude
            let decibels = 20 * log10(max(impulseMagnitudes[index], 1e-20))
            // Match getByteFrequencyData (-90...-6 dB), then readBand's
            // conversion back to linear amplitude before its square root.
            let byte = floor(min(255, max(0, (decibels + 90) / 84 * 255)))
            sum += pow(10, (-90 + byte / 255 * 84) / 20)
        }
        return sqrt(sum / Float(upper - lower + 1))
    }

    private func computePower(samples: [Float], window: [Float], setup fftSetup: FFTSetup) {
        vDSP_vmul(
            samples,
            1,
            window,
            1,
            &work,
            1,
            vDSP_Length(Self.fftSize)
        )

        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                guard let realBase = realPointer.baseAddress,
                      let imaginaryBase = imaginaryPointer.baseAddress else {
                    return
                }
                var split = DSPSplitComplex(
                    realp: realBase,
                    imagp: imaginaryBase
                )
                work.withUnsafeBytes { rawBuffer in
                    let complex = rawBuffer.bindMemory(to: DSPComplex.self)
                    guard let complexBase = complex.baseAddress else { return }
                    vDSP_ctoz(
                        complexBase,
                        2,
                        &split,
                        1,
                        vDSP_Length(Self.fftSize / 2)
                    )
                }
                vDSP_fft_zrip(
                    fftSetup,
                    &split,
                    1,
                    log2FFTSize,
                    FFTDirection(kFFTDirection_Forward)
                )
                power.withUnsafeMutableBufferPointer { powerPointer in
                    guard let powerBase = powerPointer.baseAddress else { return }
                    vDSP_zvmags(
                        &split,
                        1,
                        powerBase,
                        1,
                        vDSP_Length(powerPointer.count)
                    )
                }
            }
        }

    }
}

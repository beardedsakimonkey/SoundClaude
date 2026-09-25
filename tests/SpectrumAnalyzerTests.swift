import Foundation

@main
struct SpectrumAnalyzerTests {
    static func main() {
        for sampleRate in [44_100.0, 48_000.0, 96_000.0] {
            let analyzer = SpectrumAnalyzer()!
            var bands = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
            var rms: Float = 0
            var bass: Float = 0
            var trebleLevel: Float = 0
            func read() {
                precondition(SCSpectrumBufferRead(analyzer.spectrumBuffer, &bands, &rms, &bass, &trebleLevel))
            }
            func tone(bin: Int) -> [Float] {
                (0..<SpectrumAnalyzer.fftSize).map {
                    Float(sin(2 * Double.pi * Double(bin * $0) / Double(SpectrumAnalyzer.fftSize)))
                }
            }
            let silence = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize)
            analyzer.analyze(samples: silence, sampleRate: sampleRate)
            read()
            precondition(bass * bass < 0.00004)

            // A bin-centered sine has known Blackman magnitudes: the center
            // and two neighbors on either side sum to 0.5 at amplitude one.
            let bin = sampleRate == 96_000 ? 2 : 3
            let samples = tone(bin: bin)
            analyzer.analyze(samples: samples, sampleRate: sampleRate)
            read()
            let firstEnergy = bass * bass
            for _ in 0..<20 { analyzer.analyze(samples: samples, sampleRate: sampleRate) }
            read()
            let count = ceil(140 * 2048 / sampleRate) - floor(25 * 2048 / sampleRate) + 1
            // At 96 kHz the outer lobes fall at DC (zero for sine)
            // and above the selected high bin, leaving a sum of 0.46.
            let expectedEnergy = Float((sampleRate == 96_000 ? 0.46 : 0.5) / count)
            precondition(abs(bass * bass / expectedEnergy - 1) < 0.05,
                         "Bass must use linear FFT amplitudes, not display levels")
            precondition(abs(firstEnergy / (bass * bass) - 0.5) < 0.03)
            precondition(abs(rms - sqrt(0.5)) < 0.001)
            precondition(bands.contains { $0 > 0 })

            let treble = tone(bin: Int(6000 * 2048 / sampleRate))
            for _ in 0..<30 { analyzer.analyze(samples: treble, sampleRate: sampleRate) }
            read()
            precondition(bass * bass < 0.00004, "Treble must not drive bass hits")
            precondition(trebleLevel * trebleLevel > 0.0005, "Treble must use the 2400–12000 Hz band")
            let mixed = zip(samples, treble).map { ($0 + $1) * 0.5 }
            for _ in 0..<30 { analyzer.analyze(samples: mixed, sampleRate: sampleRate) }
            read()
            precondition(abs(bass * bass / (expectedEnergy * 0.5) - 1) < 0.05,
                         "Adding treble must not suppress the bass signal")
            precondition(bass * bass > 0.02 && trebleLevel * trebleLevel > 0.0005,
                         "Mixed audio must retain both impulse bands")
            SCSpectrumBufferClear(analyzer.spectrumBuffer)
            read()
            precondition(bass == 0 && trebleLevel == 0 && rms == 0 && bands.allSatisfy { $0 == 0 })
        }
        print("Spectrum analyzer tests passed")
    }
}
